#!/usr/bin/env bash
# local-up.sh — el laboratorio en tu máquina, sin cuenta de AWS (unos 5 minutos):
#   1. clúster kind «permisos-ia» con la auditoría del API server activada;
#   2. External Secrets;
#   3. PostgreSQL en shop-data y la «bóveda» (namespace boveda), que hace de
#      Secrets Manager: su Secret orders-db es la fuente de la contraseña;
#   4. la tienda.
# Cada paso se salta lo que ya existe: si algo falla, vuelve a lanzarlo.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/shop.sh"
need docker kind kubectl helm python3
docker info >/dev/null 2>&1 || die "Docker no responde: arranca Docker Desktop (o tu motor de contenedores)"

step "1. clúster kind $NAME"
if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  kind export kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null 2>&1
  ok "ya existe"
else
  export LAB_DIR
  render "$LAB_DIR/local/kind.yaml.tpl" "$STATE/kind.yaml" LAB_DIR
  kind create cluster --config "$STATE/kind.yaml" --kubeconfig "$KUBECONFIG_FILE" --wait 3m
fi
chmod 600 "$KUBECONFIG_FILE"
kc get nodes --no-headers | awk '{print "  · " $1, $2}'

step "2. External Secrets"
eso_install

step "3. PostgreSQL y la bóveda"
kc apply -f "$LAB_DIR/k8s/shop/00-namespaces.yaml" >/dev/null
if ! kc -n shop-data get secret postgres-admin >/dev/null 2>&1; then
  printf 'shopadmin\n%s\n' "$(random_password)" | secret_from_stdin shop-data postgres-admin username password
fi
kc apply -f "$LAB_DIR/k8s/local/postgres.yaml" >/dev/null
kc -n shop-data rollout status statefulset/shop-db --timeout=5m >/dev/null || die "PostgreSQL no arrancó (kubectl -n shop-data describe pod shop-db-0)"
ok "PostgreSQL 16 en shop-data"
# Los jobs de la base corren en shop-backend con las credenciales del administrador.
kc -n shop-data get secret postgres-admin -o json \
  | python3 -I -c 'import base64, json, sys; d = json.load(sys.stdin)["data"]; print(base64.b64decode(d["username"]).decode()); print(base64.b64decode(d["password"]).decode())' \
  | secret_from_stdin "$NS" shop-db-credentials username password
kc apply -f "$LAB_DIR/k8s/local/external-secrets.yaml" >/dev/null
if ! kc -n boveda get secret orders-db >/dev/null 2>&1; then
  printf 'orders_app\n%s\n' "$(random_password)" | secret_from_stdin boveda orders-db username password
  kc -n boveda annotate secret orders-db lab/rotado-en="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null
fi
ok "bóveda: boveda/orders-db (la «Secrets Manager» local)"

step "4. la tienda"
shop_apply shop-db.shop-data.svc.cluster.local disable ""

echo
echo "Laboratorio local listo. Siguiente: conéctalo a KubeBolt con ${BOLD}make kubebolt${OFF} (docs/kubebolt.md)."
echo "Para usar kubectl tú mismo: export KUBECONFIG=$KUBECONFIG_FILE"
