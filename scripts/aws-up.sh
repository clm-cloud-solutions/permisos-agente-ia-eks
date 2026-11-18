#!/usr/bin/env bash
# aws-up.sh — el laboratorio en tu cuenta de AWS (unos 30 minutos, casi todo
# esperando a CloudFormation y a eksctl):
#   1. un bucket para el paquete de la función de rotación (y la plantilla);
#   2. la pila de CloudFormation (aws/lab.yaml): VPC, NAT, RDS, el secreto de
#      orders-api con su rotación, y los roles de External Secrets y de KubeBolt;
#   3. el clúster EKS con eksctl (aws/cluster.yaml.tpl) y tu kubeconfig del
#      laboratorio en .lab/kubeconfig;
#   4. External Secrets con Pod Identity;
#   5. la tienda.
# Cada paso se salta lo que ya existe: si algo falla, vuelve a lanzarlo. Lo
# mismo si cambia tu IP: el endpoint de EKS solo acepta la tuya.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/shop.sh"
aws_guard
need eksctl kubectl helm python3 curl
TAGS="Project=permisos-agente-ia-eks"
echo "Cuenta $ACCOUNT_ID · región $AWS_REGION · perfil $AWS_PROFILE"

step "1. bucket de artefactos y paquete de la función de rotación"
BUCKET="$NAME-$ACCOUNT_ID-$AWS_REGION"
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  if [ "$AWS_REGION" = us-east-1 ]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=Project,Value=permisos-agente-ia-eks}]"
fi
BUILD="$STATE/lambda"
rm -rf "$BUILD" && mkdir -p "$BUILD/pkg"
# pg8000 y sus dependencias son Python puro: se instalan para arm64 sin compilar nada.
python3 -m pip install --quiet --disable-pip-version-check --no-compile --only-binary=:all: \
  --platform manylinux2014_aarch64 --python-version 3.12 --implementation cp \
  --target "$BUILD/pkg" pg8000==1.31.2 scramp==1.4.18 \
  || die "pip no pudo descargar pg8000 (necesitas python3 con pip y acceso a PyPI)"
cp "$LAB_DIR/aws/lambda/rotation.py" "$BUILD/pkg/"
curl -fsSL -o "$BUILD/pkg/rds-ca.pem" "https://truststore.pki.rds.amazonaws.com/$AWS_REGION/$AWS_REGION-bundle.pem" \
  || die "no pude descargar la CA de RDS de $AWS_REGION"
LAMBDA_KEY=$(python3 -I - "$BUILD/pkg" "$BUILD/function.zip" <<'EOF'
import hashlib, os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
files = sorted(os.path.relpath(os.path.join(d, f), src) for d, _, fs in os.walk(src) for f in fs)
h = hashlib.sha256()
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in files:
        data = open(os.path.join(src, rel), "rb").read()
        h.update(rel.encode() + b"\0" + data)
        info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        z.writestr(info, data, zipfile.ZIP_DEFLATED)
print(f"rotation-{h.hexdigest()[:16]}.zip")
EOF
)
aws s3api head-object --bucket "$BUCKET" --key "$LAMBDA_KEY" >/dev/null 2>&1 \
  || aws s3 cp --quiet "$BUILD/function.zip" "s3://$BUCKET/$LAMBDA_KEY"
ok "s3://$BUCKET/$LAMBDA_KEY"

step "2. pila $NAME (VPC, RDS, secreto y rotación, roles) — unos 12 min la primera vez"
# El External ID que presentará KubeBolt al asumir el rol de solo lectura. Con
# KubeBolt Cloud, el de tu organización (asistente del conector de AWS); si no,
# uno aleatorio que se guarda en .lab/ y que KubeBolt open source usará.
if [ -n "${KUBEBOLT_EXTERNAL_ID:-}" ]; then
  EXTERNAL_ID=$KUBEBOLT_EXTERNAL_ID
else
  [ -s "$STATE/external-id" ] || { python3 -I -c 'import secrets; print(secrets.token_hex(16))' > "$STATE/external-id"; chmod 600 "$STATE/external-id"; }
  EXTERNAL_ID=$(cat "$STATE/external-id")
fi
python3 -I - "$LAB_DIR/aws/lab.yaml" "$LAB_DIR/aws/kubebolt-policy.json" "$STATE/lab.yaml" <<'EOF'
import json, sys
t = open(sys.argv[1]).read()
p = json.dumps(json.load(open(sys.argv[2])), separators=(",", ":"))
assert t.count("KUBEBOLT_POLICY") == 1
open(sys.argv[3], "w").write(t.replace("KUBEBOLT_POLICY", p))
EOF
# Un secreto con ese nombre que quedó «programado para borrarse» bloquea la pila.
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --query DeletedDate --output text 2>/dev/null | grep -qv None; then
  aws secretsmanager restore-secret --secret-id "$SECRET_NAME" >/dev/null
  aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --force-delete-without-recovery >/dev/null
  sleep 10
fi
aws cloudformation deploy --stack-name "$NAME" --template-file "$STATE/lab.yaml" --s3-bucket "$BUCKET" \
  --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --tags "$TAGS" \
  --parameter-overrides Name="$NAME" LambdaBucket="$BUCKET" LambdaKey="$LAMBDA_KEY" \
    KubeBoltPrincipalArn="${KUBEBOLT_AWS_PRINCIPAL_ARN:-}" KubeBoltExternalId="$EXTERNAL_ID" >/dev/null \
  || { aws cloudformation describe-stack-events --stack-name "$NAME" --max-items 15 \
         --query 'StackEvents[?contains(ResourceStatus, `FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output text; \
       die "la pila $NAME no se creó (eventos arriba)"; }
ok "pila $NAME lista"

step "3. clúster EKS $NAME — unos 15 min la primera vez"
OPERATOR_CIDR="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
if aws eks describe-cluster --name "$NAME" >/dev/null 2>&1; then
  current=$(aws eks describe-cluster --name "$NAME" --query 'cluster.resourcesVpcConfig.publicAccessCidrs[0]' --output text)
  if [ "$current" != "$OPERATOR_CIDR" ]; then
    note "tu IP cambió ($current → $OPERATOR_CIDR): actualizo el endpoint"
    aws eks update-cluster-config --name "$NAME" --resources-vpc-config "publicAccessCidrs=$OPERATOR_CIDR" >/dev/null
    aws eks wait cluster-active --name "$NAME"
  fi
  ok "ya existe"
else
  export NAME AWS_REGION EKS_VERSION NODE_TYPE NODE_COUNT OPERATOR_CIDR
  export VPC_ID PUBLIC_SUBNET_A PUBLIC_SUBNET_B PRIVATE_SUBNET_A PRIVATE_SUBNET_B AZ_A AZ_B
  VPC_ID=$(stack_out VpcId) AZ_A=$(stack_out AzA) AZ_B=$(stack_out AzB)
  PUBLIC_SUBNET_A=$(stack_out PublicSubnetA) PUBLIC_SUBNET_B=$(stack_out PublicSubnetB)
  PRIVATE_SUBNET_A=$(stack_out PrivateSubnetA) PRIVATE_SUBNET_B=$(stack_out PrivateSubnetB)
  render "$LAB_DIR/aws/cluster.yaml.tpl" "$STATE/cluster.yaml" NAME AWS_REGION EKS_VERSION NODE_TYPE NODE_COUNT \
    OPERATOR_CIDR VPC_ID PUBLIC_SUBNET_A PUBLIC_SUBNET_B PRIVATE_SUBNET_A PRIVATE_SUBNET_B AZ_A AZ_B
  eksctl create cluster -f "$STATE/cluster.yaml" --write-kubeconfig=false
fi
# --profile deja AWS_PROFILE en el kubeconfig: kubectl nunca cae en tu perfil por defecto.
aws eks update-kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG_FILE" --alias "$NAME" --profile "$AWS_PROFILE" >/dev/null
chmod 600 "$KUBECONFIG_FILE"
kc get nodes --no-headers | awk '{print "  · " $1, $2}'
# EKS no marca ninguna StorageClass por defecto: gp3 para quien la necesite
# (KubeBolt open source, si lo instalas en el clúster).
kc apply -f - >/dev/null <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations: {storageclass.kubernetes.io/is-default-class: "true"}
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters: {type: gp3, encrypted: "true"}
EOF

step "4. External Secrets (Pod Identity: rol $NAME-eso, solo lee $SECRET_NAME)"
# pod_identity <namespace> <service account> <ARN del rol>. Tiene que existir antes
# que los pods: EKS inyecta las credenciales cuando admite el pod.
pod_identity() {
  local assoc
  assoc=$(aws eks list-pod-identity-associations --cluster-name "$NAME" --namespace "$1" \
    --service-account "$2" --query 'associations[0].associationId' --output text)
  if [ -z "$assoc" ] || [ "$assoc" = None ]; then
    aws eks create-pod-identity-association --cluster-name "$NAME" --namespace "$1" \
      --service-account "$2" --role-arn "$3" --tags "$TAGS" >/dev/null
  fi
}
pod_identity external-secrets external-secrets "$(stack_out EsoRoleArn)"
eso_install

step "5. la tienda"
kc apply -f "$LAB_DIR/k8s/shop/00-namespaces.yaml" >/dev/null
# El administrador de la base: su contraseña la guarda RDS en Secrets Manager.
aws secretsmanager get-secret-value --secret-id "$(stack_out DbMasterSecretArn)" --query SecretString --output text \
  | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(d["username"]); print(d["password"])' \
  | secret_from_stdin "$NS" shop-db-credentials username password
export SECRET_NAME
render "$LAB_DIR/k8s/aws/external-secrets.yaml.tpl" "$STATE/external-secrets.yaml" AWS_REGION SECRET_NAME NAME
kc apply -f "$STATE/external-secrets.yaml" >/dev/null
curl -fsSL -o "$STATE/rds-ca.pem" "https://truststore.pki.rds.amazonaws.com/$AWS_REGION/$AWS_REGION-bundle.pem"
shop_apply "$(stack_out DbEndpoint)" verify-full "$STATE/rds-ca.pem"

echo
echo "Laboratorio en AWS listo (cuesta unos 0,25 USD por hora mientras exista: make down lo borra todo)."
echo "Siguiente: conéctalo a KubeBolt con ${BOLD}make kubebolt${OFF} (docs/kubebolt.md)."
echo "Para usar kubectl tú mismo: export KUBECONFIG=$KUBECONFIG_FILE"
