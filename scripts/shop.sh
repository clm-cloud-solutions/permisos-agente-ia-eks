# shellcheck shell=bash
# shop.sh — la parte de la tienda que es igual en los dos modos. La cargan
# aws-up.sh y local-up.sh con `source`, después de dejar listos la base, el
# Secret shop-db-credentials (el administrador) y el ExternalSecret de orders-api.

# shop_apply <host de la base> <sslmode> <bundle de la CA, o vacío>
shop_apply() {
  local host=$1 sslmode=$2 ca=${3:-} job
  kc apply -f "$LAB_DIR/k8s/shop/00-namespaces.yaml" >/dev/null

  # Dónde está la base y cómo se habla con ella: lo leen las APIs y los jobs.
  kc -n "$NS" create configmap shop-db --from-literal=host="$host" --from-literal=sslmode="$sslmode" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  if [ -n "$ca" ]; then
    kc -n "$NS" create configmap db-ca --from-file=bundle.pem="$ca" --dry-run=client -o yaml | kc apply -f - >/dev/null
  else
    kc -n "$NS" create configmap db-ca --from-literal=bundle.pem= --dry-run=client -o yaml | kc apply -f - >/dev/null
  fi

  # catalog-api no entra en el incidente: su contraseña es un Secret normal.
  if ! kc -n "$NS" get secret catalog-db-credentials >/dev/null 2>&1; then
    printf 'catalog_app\n%s\n' "$(random_password)" | secret_from_stdin "$NS" catalog-db-credentials username password
  fi

  kc -n "$NS" wait --for=condition=Ready externalsecret/orders-db-credentials --timeout=3m >/dev/null \
    || die "External Secrets no sincronizó orders-db-credentials (kubectl -n $NS describe externalsecret orders-db-credentials)"
  ok "External Secrets sincronizó orders-db-credentials"

  # Esquema y datos, y después un rol por API con la contraseña de su Secret.
  for job in seed:shop-db-seed app-roles:shop-db-app-roles; do
    kc -n "$NS" delete job "${job#*:}" --ignore-not-found >/dev/null
    kc apply -f "$LAB_DIR/k8s/jobs/${job%%:*}.yaml" >/dev/null
    if ! kc -n "$NS" wait --for=condition=complete "job/${job#*:}" --timeout=6m >/dev/null; then
      kc -n "$NS" logs "job/${job#*:}" --tail=20 || true
      die "el job ${job#*:} no terminó"
    fi
    ok "job ${job#*:} completo"
  done

  kc apply -f "$LAB_DIR/k8s/shop/20-backend.yaml" -f "$LAB_DIR/k8s/shop/30-frontend.yaml" \
    -f "$LAB_DIR/k8s/shop/40-loadgen.yaml" >/dev/null
  for d in shop-backend/orders-api shop-backend/catalog-api shop-frontend/shop-web shop-frontend/loadgen; do
    kc -n "${d%/*}" rollout status "deploy/${d#*/}" --timeout=6m >/dev/null || die "${d#*/} no quedó listo (make estado)"
  done
  ok "tienda arriba: HTTP $(shop_code) desde dentro del clúster (make tienda para abrirla)"
}

# eso_install — External Secrets con su chart oficial.
eso_install() {
  hc upgrade --install external-secrets external-secrets \
    --repo https://charts.external-secrets.io --version "$ESO_CHART_VERSION" \
    -n external-secrets --create-namespace --wait --timeout 6m >/dev/null
  ok "External Secrets $ESO_CHART_VERSION"
}
