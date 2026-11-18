#!/usr/bin/env bash
# aws-down.sh — borra todo lo que creó aws-up.sh (unos 20-30 minutos):
#   1. KubeBolt open source, si está: sus volúmenes EBS se borran con sus PVC,
#      antes que el clúster (si no, quedarían huérfanos y cobrando);
#   2. el clúster EKS (eksctl);
#   3. la pila de CloudFormation (la Lambda en la VPC tarda en soltar sus
#      interfaces de red: CloudFormation espera solo);
#   4. el secreto sin periodo de recuperación, el grupo de logs de la Lambda y
#      el bucket de artefactos;
#   5. lo que quede con la etiqueta Project=permisos-agente-ia-eks, para revisar.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
aws_guard
need eksctl
echo "Cuenta $ACCOUNT_ID · región $AWS_REGION · perfil $AWS_PROFILE"

step "1-2. clúster EKS $NAME"
if aws eks describe-cluster --name "$NAME" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG_FILE" --alias "$NAME" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
  if kc get namespace "$OSS_NS" >/dev/null 2>&1; then
    note "KubeBolt open source: borro sus PVC y espero a que se vayan sus volúmenes"
    hc -n "$OSS_NS" uninstall kubebolt --wait >/dev/null 2>&1 || true
    kc -n "$OSS_NS" delete pvc --all --wait=true --timeout=5m >/dev/null 2>&1 || true
    no_oss_volumes() { ! kc get pv -o jsonpath='{.items[*].spec.claimRef.namespace}' | grep -qw "$OSS_NS"; }
    wait_until 300 10 no_oss_volumes || note "quedan volúmenes de $OSS_NS: revísalos en EC2 › Volumes al terminar"
  fi
  eksctl delete cluster --name "$NAME" --wait --disable-nodegroup-eviction
  ok "clúster borrado"
else
  ok "no había clúster"
fi

step "3. pila $NAME"
if aws cloudformation describe-stacks --stack-name "$NAME" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name "$NAME"
  aws cloudformation wait stack-delete-complete --stack-name "$NAME" \
    || die "la pila no terminó de borrarse: mira sus eventos en la consola de CloudFormation y vuelve a lanzar make down"
  ok "pila borrada"
else
  ok "no había pila"
fi

step "4. restos que CloudFormation no borra"
# CloudFormation programa el borrado del secreto con 30 días de recuperación: el
# nombre quedaría ocupado y el siguiente make up fallaría.
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --force-delete-without-recovery >/dev/null && ok "secreto $SECRET_NAME borrado sin recuperación"
fi
LOG_GROUP="/aws/lambda/$NAME-orders-db-rotation"
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
  aws logs delete-log-group --log-group-name "$LOG_GROUP" && ok "grupo de logs $LOG_GROUP borrado"
fi
BUCKET="$NAME-$ACCOUNT_ID-$AWS_REGION"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws s3 rm --quiet --recursive "s3://$BUCKET"
  aws s3api delete-bucket --bucket "$BUCKET" && ok "bucket $BUCKET borrado"
fi
rm -f "$KUBECONFIG_FILE" "$STATE/cluster.yaml" "$STATE/lab.yaml" "$STATE/external-secrets.yaml"

step "5. lo que queda con Project=permisos-agente-ia-eks"
left=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=permisos-agente-ia-eks \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)
if [ -n "$left" ]; then
  echo "$left" | tr '\t' '\n' | sed 's/^/  · /'
  note "la API de etiquetas tarda unos minutos en olvidar lo borrado; si sigue ahí en un rato, bórralo a mano"
else
  ok "nada"
fi
note "si conectaste el clúster a KubeBolt Cloud, bórralo de Fleet y revoca su token"
