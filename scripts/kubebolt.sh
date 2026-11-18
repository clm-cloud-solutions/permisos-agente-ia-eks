#!/usr/bin/env bash
# kubebolt.sh cloud|oss|quitar — conecta el clúster del laboratorio a KubeBolt.
#
#   cloud   el agente informa a KubeBolt Cloud (app.kubebolt.io). Necesita el token
#           de ingesta del asistente «Connect cluster»: si ya ejecutaste el bloque
#           del asistente, el token está en el Secret y no lo pido.
#   oss     KubeBolt open source dentro del propio clúster, y el agente apuntando
#           a él. Kobi necesita tu clave de un proveedor de LLM (la pido una vez y
#           queda en .lab/llm-api-key). En AWS, el backend recibe por Pod Identity
#           un rol cuyo único permiso es asumir el de solo lectura.
#   quitar  desinstala el agente y, si está, KubeBolt open source.
#
# El agente va en modo rbac «operator»: sin él, ni la tarjeta de reinicio de Kobi
# ni Autopilot pueden actuar. Es un permiso amplio sobre el clúster; qué lo
# limita (aprobaciones, roles de KubeBolt, redacción) es parte del ejercicio 2.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl helm python3
require_cluster
AGENT_CHART_VERSION=1.4.9
OSS_CHART_VERSION=2.6.5

ask_secret() { # ask_secret <archivo> <pregunta> — lee un valor sin mostrarlo y lo guarda (600)
  local v
  if [ ! -s "$1" ]; then
    [ -t 0 ] || die "falta $1 (créalo con el valor, chmod 600, o lanza el comando en una terminal)"
    printf '%s ' "$2" >&2
    IFS= read -rs v; echo >&2
    [ -n "$v" ] || die "vacío"
    (umask 077; printf '%s' "$v" > "$1")
  fi
}

agent_install() { # agent_install <backendUrl> <args de helm...>
  local url=$1; shift
  hc upgrade --install kubebolt-agent "$AGENT_CHART" --version "$AGENT_CHART_VERSION" \
    -n "$AGENT_NS" --create-namespace \
    --set backendUrl="$url" --set cluster.name="$NAME" --set rbac.mode=operator \
    --set hubble.enabled=false "$@" --wait --timeout 5m >/dev/null
  kc -n "$AGENT_NS" rollout status ds/kubebolt-agent --timeout=3m >/dev/null
  registered() { kc -n "$AGENT_NS" logs ds/kubebolt-agent --since=3m 2>/dev/null | grep -q 'channel registered'; }
  if wait_until 90 5 registered; then
    ok "agente registrado en $url"
  else
    kc -n "$AGENT_NS" logs ds/kubebolt-agent --since=3m --tail=15 2>/dev/null | grep -v -i token || true
    die "el agente no se registró en 90 s (log arriba)"
  fi
}

do_cloud() {
  step "KubeBolt Cloud"
  kc create namespace "$AGENT_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
  if kc -n "$AGENT_NS" get secret "$AGENT_TOKEN_SECRET" >/dev/null 2>&1; then
    ok "uso el token que ya está en $AGENT_NS/$AGENT_TOKEN_SECRET"
  else
    echo "  Crea tu cuenta gratis en https://app.kubebolt.io/signup y, en el asistente"
    echo "  «Connect cluster», copia el token de ingesta (solo se muestra una vez)."
    ask_secret "$STATE/kubebolt-token" "  Pega el token de ingesta (no se verá):"
    tr -d '\r\n' < "$STATE/kubebolt-token" | secret_from_stdin "$AGENT_NS" "$AGENT_TOKEN_SECRET" token
  fi
  agent_install agent.kubebolt.io:443 --set tls.enabled=true \
    --set auth.mode=ingest-token --set auth.ingestToken.existingSecret="$AGENT_TOKEN_SECRET"
  echo "  Abre https://app.kubebolt.io: el clúster «$NAME» aparece en Fleet en un par de minutos."
}

do_oss() {
  step "KubeBolt open source $OSS_CHART_VERSION en el clúster"
  local provider=${KUBEBOLT_AI_PROVIDER:-anthropic} args=()
  kc create namespace "$OSS_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
  echo "  Kobi usa tu propio proveedor de LLM ($provider; cámbialo con KUBEBOLT_AI_PROVIDER en lab.env)."
  ask_secret "$STATE/llm-api-key" "  Pega tu API key (no se verá):"
  tr -d '\r\n' < "$STATE/llm-api-key" | secret_from_stdin "$OSS_NS" kubebolt-llm api-key
  args=(--set copilot.enabled=true --set copilot.provider="$provider" --set copilot.existingSecret=kubebolt-llm
        --set serviceAccount.name=kubebolt-api)
  [ -n "${KUBEBOLT_AI_MODEL:-}" ] && args+=(--set copilot.model="$KUBEBOLT_AI_MODEL")
  [ -n "${KUBEBOLT_AI_BASE_URL:-}" ] && args+=(--set copilot.baseUrl="$KUBEBOLT_AI_BASE_URL")
  if [ "$LAB_MODE" = aws ]; then
    aws_guard
    local api_role
    api_role=$(stack_out KubeBoltApiRoleArn)
    # Pod Identity para la ServiceAccount del backend: su rol solo puede asumir el
    # de solo lectura, que es el que le darás al conector de AWS.
    if [ "$(aws eks list-pod-identity-associations --cluster-name "$NAME" --namespace "$OSS_NS" \
            --service-account kubebolt-api --query 'length(associations)' --output text)" = 0 ]; then
      aws eks create-pod-identity-association --cluster-name "$NAME" --namespace "$OSS_NS" \
        --service-account kubebolt-api --role-arn "$api_role" --tags Project=permisos-agente-ia-eks >/dev/null
    fi
    args+=(--set mcpConnectors.aws.principalArn="$api_role")
  fi
  hc upgrade --install kubebolt "$OSS_CHART" --version "$OSS_CHART_VERSION" -n "$OSS_NS" \
    "${args[@]}" --wait --timeout 8m >/dev/null
  ok "KubeBolt open source listo"
  # tokenreview: el agente se identifica con un token de su ServiceAccount, que el
  # backend valida con la API del clúster (el modo operator no admite agentes anónimos).
  agent_install "kubebolt-agent-ingest.$OSS_NS.svc.cluster.local:9090" \
    --set auth.mode=tokenreview
  echo "  La interfaz: ${BOLD}make ui${OFF} (http://localhost:3000, usuario admin)."
}

do_quitar() {
  hc -n "$AGENT_NS" uninstall kubebolt-agent --wait >/dev/null 2>&1 && ok "agente desinstalado" || ok "no había agente"
  if hc -n "$OSS_NS" status kubebolt >/dev/null 2>&1; then
    hc -n "$OSS_NS" uninstall kubebolt --wait >/dev/null && ok "KubeBolt open source desinstalado"
    kc -n "$OSS_NS" delete pvc --all --wait=true >/dev/null 2>&1 || true
  fi
}

case "${1:-$KUBEBOLT}" in
  cloud) do_cloud ;;
  oss) do_oss ;;
  quitar) do_quitar ;;
  *) die "uso: $0 cloud|oss|quitar" ;;
esac
