#!/usr/bin/env bash
# incidente.sh romper|reparar|estado — el incidente del laboratorio: la
# contraseña de orders-api rota y los pods siguen con la vieja.
#
#   romper   aws:   RotateSecret en Secrets Manager; la función de rotación cambia
#                   la contraseña en RDS y cierra las sesiones viejas del rol.
#            local: lo mismo a mano: ALTER ROLE, cierre de sesiones y el Secret
#                   nuevo en la bóveda (boveda/orders-db).
#            En los dos casos External Secrets copia la contraseña nueva al
#            clúster en menos de un minuto, pero orders-api la leyó al arrancar:
#            no vuelve a entrar en la base, sus pods salen del Service y la
#            tienda da 503. La causa está fuera del pod; el arreglo, dentro.
#   reparar  fuerza la sincronización de External Secrets y reinicia orders-api.
#   estado   la tienda, orders-api y si el Secret del clúster está al día.
#
# ESPERAR_CLOUDTRAIL=0 hace que `romper` no espere a que CloudTrail devuelva el
# RotateSecret (aws; tarda 2-5 min, y es lo que Kobi necesita para encontrarlo).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl python3
require_cluster
[ "$LAB_MODE" = aws ] && aws_guard
STAMP_FILE="$STATE/ultima-rotacion"   # cuándo se rotó por última vez (UTC)

sha() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read().strip()).hexdigest())'; }
cluster_password_sha() {
  kc -n "$NS" get secret orders-db-credentials -o jsonpath='{.data.password}' | base64 -d | sha
}
source_password_sha() { # la fuente de verdad: Secrets Manager (aws) o la bóveda (local)
  if [ "$LAB_MODE" = aws ]; then
    aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text \
      | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["password"])' | sha
  else
    kc -n boveda get secret orders-db -o jsonpath='{.data.password}' | base64 -d | sha
  fi
}
synced() { [ "$(cluster_password_sha)" = "$(source_password_sha)" ]; }
rotated_at() { # la fecha de la versión vigente de la contraseña
  if [ "$LAB_MODE" = aws ]; then
    aws secretsmanager list-secret-version-ids --secret-id "$SECRET_NAME" \
      --query "Versions[?contains(VersionStages, 'AWSCURRENT')].CreatedDate | [0]" --output text
  else
    kc -n boveda get secret orders-db -o jsonpath='{.metadata.annotations.lab/rotado-en}'
  fi
}
pods_after_rotation() { # cada pod de orders-api arrancó después de la rotación
  local made
  made=$(rotated_at)
  kc -n "$NS" get pods -l "app=$DEPLOY" -o json | python3 -I -c '
import json, sys
from datetime import datetime
made = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
pods = [p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")]
starts = [datetime.fromisoformat(p["status"]["startTime"].replace("Z", "+00:00")) for p in pods if p["status"].get("startTime")]
sys.exit(0 if starts and all(s > made for s in starts) else 1)' "$made"
}
healthy() { synced && pods_after_rotation && ! none_ready; }

rotate_aws() {
  local fn old new
  fn=$(stack_out RotationFunctionName)
  old=$(aws secretsmanager list-secret-version-ids --secret-id "$SECRET_NAME" \
    --query "Versions[?contains(VersionStages, 'AWSCURRENT')].VersionId | [0]" --output text)
  show <<EOF
\$ aws secretsmanager rotate-secret --secret-id $SECRET_NAME
EOF
  aws secretsmanager rotate-secret --secret-id "$SECRET_NAME" >/dev/null
  note "RotateSecret pedido; la función $fn hace el resto"
  # Terminada cuando la función registra su finishSecret: las etiquetas solas no
  # bastan, porque AWSCURRENT se mueve antes de que se cierren las sesiones viejas.
  finished() {
    new=$(aws secretsmanager list-secret-version-ids --secret-id "$SECRET_NAME" \
      --query "Versions[?contains(VersionStages, 'AWSCURRENT')].VersionId | [0]" --output text)
    [ "$new" != "$old" ] && [ -n "$(aws logs filter-log-events --log-group-name "/aws/lambda/$fn" \
      --start-time $(( ($(date +%s) - 600) * 1000 )) --filter-pattern "\"finishSecret: $new is AWSCURRENT\"" \
      --query 'events[0].message' --output text 2>/dev/null | sed 's/^None$//')" ]
  }
  if ! wait_until 150 3 finished; then
    aws logs tail "/aws/lambda/$fn" --since 5m 2>/dev/null | tail -20 || true
    die "la rotación no terminó en 2 min 30 s (log de la función arriba)"
  fi
  ok "rotada: la versión vigente es otra y la función cerró las sesiones viejas de orders_app"
}

rotate_local() {
  local pw
  pw=$(random_password)
  show <<EOF
\$ kubectl -n shop-data exec shop-db-0 -- psql -U shopadmin -d shop \\
    -c "ALTER ROLE orders_app PASSWORD '<nueva>'" \\
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'orders_app'"
\$ kubectl -n boveda create secret generic orders-db --from-literal=username=orders_app \\
    --from-literal=password='<nueva>' --dry-run=client -o yaml | kubectl apply -f -
EOF
  # La contraseña va por stdin a psql, nunca por la línea de comandos.
  printf "ALTER ROLE orders_app PASSWORD '%s';\nSELECT count(pg_terminate_backend(pid)) AS sesiones_cerradas FROM pg_stat_activity WHERE usename = 'orders_app';\n" "$pw" \
    | kc -n shop-data exec -i shop-db-0 -- sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d shop -t' \
    | sed 's/^ */  · sesiones de orders_app cerradas: /' | grep -v '^  · sesiones de orders_app cerradas: $' || true
  printf 'orders_app\n%s\n' "$pw" | secret_from_stdin boveda orders-db username password
  kc -n boveda annotate secret orders-db lab/rotado-en="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null
  ok "rotada: la base y la bóveda tienen la contraseña nueva"
}

do_romper() {
  local t0
  healthy || die "orders-api no está sano ahora mismo (¿ya está roto?): make reparar y vuelve a probar"
  t0=$(date +%s)
  step "rotando la contraseña de orders-api ($(date +%H:%M:%S))"
  if [ "$LAB_MODE" = aws ]; then rotate_aws; else rotate_local; fi
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP_FILE"
  if wait_until 120 3 none_ready; then
    ok "orders-api sin pods Ready a los $(( $(date +%s) - t0 )) s: la tienda da $(shop_code)"
  else
    note "orders-api sigue con pods Ready a los 2 min: mira make estado"
  fi
  kc -n "$NS" logs deploy/"$DEPLOY" --tail=2 2>/dev/null | sed 's/^/  │ /' || true
  if [ "$LAB_MODE" = aws ] && [ "${ESPERAR_CLOUDTRAIL:-1}" = 1 ]; then
    note "espero a que CloudTrail devuelva el RotateSecret (suele tardar 2-5 min; ESPERAR_CLOUDTRAIL=0 para no esperar)"
    since=$(minutes_ago 10)
    in_cloudtrail() {
      [ "$(aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=RotateSecret \
            --start-time "$since" --query 'length(Events)' --output text)" != 0 ]
    }
    if wait_until 420 15 in_cloudtrail; then
      ok "RotateSecret ya está en CloudTrail a los $(( $(date +%s) - t0 )) s"
    else
      note "CloudTrail aún no lo devuelve: Kobi puede tardar en encontrarlo"
    fi
  fi
  echo
  echo "Pregúntale a Kobi: ${BOLD}«La tienda está dando errores desde hace unos minutos. ¿Qué pasa?»${OFF}"
}

do_reparar() {
  if healthy; then ok "orders-api ya corre con la contraseña vigente: nada que reparar"; return; fi
  kc -n "$NS" annotate externalsecret orders-db-credentials force-sync="$(date +%s)" --overwrite >/dev/null
  wait_until 90 3 synced || die "orders-db-credentials no se puso al día (kubectl -n $NS describe externalsecret orders-db-credentials)"
  ok "orders-db-credentials al día"
  show <<EOF
\$ kubectl -n $NS rollout restart deploy/$DEPLOY
EOF
  kc -n "$NS" rollout restart deploy/"$DEPLOY" >/dev/null
  kc -n "$NS" rollout status deploy/"$DEPLOY" --timeout=5m >/dev/null
  shop_ok() { [ "$(shop_code)" = 200 ]; }
  wait_until 60 3 shop_ok || true
  ok "orders-api reiniciado con la contraseña nueva: la tienda da $(shop_code)"
}

do_estado() {
  echo "modo $LAB_MODE · tienda HTTP $(shop_code)"
  if synced; then echo "  orders-db-credentials: al día con la fuente"; else echo "  orders-db-credentials: NO coincide con la fuente (External Secrets aún no sincronizó)"; fi
  if pods_after_rotation; then echo "  orders-api: sus pods arrancaron después de la última rotación"; else echo "  orders-api: hay pods con la contraseña de antes de la rotación"; fi
  kc -n "$NS" get pods -l "app=$DEPLOY" --no-headers -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,INICIO:.status.startTime' | sed 's/^/  /'
  kc -n "$NS" logs deploy/"$DEPLOY" --tail=1 2>/dev/null | sed 's/^/  último log: /' || true
}

case "${1:-estado}" in
  romper) do_romper ;;
  reparar) do_reparar ;;
  estado) do_estado ;;
  healthy) healthy ;;
  *) die "uso: $0 romper|reparar|estado" ;;
esac
