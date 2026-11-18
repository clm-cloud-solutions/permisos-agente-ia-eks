# shellcheck shell=bash
# lib.sh — lo que comparten todos los scripts. Se carga con `source`.
# Compatible con bash 3.2 (el de macOS): sin mapfile ni arrays asociativos.

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$LAB_DIR/.lab"                 # estado local: kubeconfig, tokens, renders (git lo ignora)
mkdir -p "$STATE" && chmod 700 "$STATE"

# lab.env es opcional: sin él, el laboratorio corre en local con KubeBolt Cloud.
if [ -f "$LAB_DIR/lab.env" ]; then
  set -a; . "$LAB_DIR/lab.env"; set +a
fi
LAB_MODE="${LAB_MODE:-local}"
KUBEBOLT="${KUBEBOLT:-cloud}"
NAME="${NAME:-permisos-ia}"
AWS_REGION="${AWS_REGION:-us-east-2}"
NODE_TYPE="${NODE_TYPE:-t4g.medium}"
NODE_COUNT="${NODE_COUNT:-2}"
EKS_VERSION="${EKS_VERSION:-1.35}"
export AWS_REGION
[ -n "${AWS_PROFILE:-}" ] && export AWS_PROFILE

KUBECONFIG_FILE="$STATE/kubeconfig"
SECRET_NAME="$NAME/orders-db"         # el secreto de orders-api en Secrets Manager (aws)
NS=shop-backend
DEPLOY=orders-api
AGENT_NS=kubebolt-system              # como el asistente de KubeBolt Cloud
AGENT_SA=kubebolt-agent
AGENT_TOKEN_SECRET=kubebolt-agent-token
OSS_NS=kubebolt                       # KubeBolt open source, si lo instalas en el clúster
ESO_CHART_VERSION=2.15.0
AGENT_CHART=oci://ghcr.io/clm-cloud-solutions/kubebolt/helm/kubebolt-agent
OSS_CHART=oci://ghcr.io/clm-cloud-solutions/kubebolt/helm/kubebolt

# render <plantilla> <salida> VAR... — sustituye ${VAR} por su valor en el entorno
# (solo las variables nombradas; el resto del texto queda igual).
render() {
  local tpl=$1 out=$2; shift 2
  python3 -I -c '
import os, sys
t = open(sys.argv[1]).read()
for v in sys.argv[3:]:
    if v not in os.environ:
        sys.exit(f"render: falta la variable {v}")
    t = t.replace("${" + v + "}", os.environ[v])
open(sys.argv[2], "w").write(t)' "$tpl" "$out" "$@"
}

# ---- salida
if [ -t 1 ]; then DIM=$'\033[2m' BOLD=$'\033[1m' OFF=$'\033[0m'; else DIM='' BOLD='' OFF=''; fi
die()  { echo "✘ $*" >&2; exit 1; }
step() { echo "${BOLD}▶ $*${OFF}"; }
ok()   { echo "  ✔ $*"; }
note() { echo "  · $*"; }
# show — imprime stdin atenuado y con sangría: el comando que corre un paso, tal
# como lo escribirías a mano. Cada heredoc va justo encima de la llamada que describe.
show() {
  local l
  while IFS= read -r l; do printf '  %s%s%s\n' "$DIM" "$l" "$OFF"; done
}

# ---- herramientas
need() { # need <comando>... — falla con un mensaje claro si falta alguno
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "falta '$c' en el PATH (mira docs/$LAB_MODE.md, «Requisitos»)"; done
}
kc() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }
hc() { helm --kubeconfig "$KUBECONFIG_FILE" "$@"; }
cluster_up() { [ -s "$KUBECONFIG_FILE" ] && kc get --raw /readyz >/dev/null 2>&1; }
require_cluster() { cluster_up || die "no hay clúster del laboratorio: make up"; }

# wait_until <timeout s> <intervalo s> <comando...> — 0 en cuanto el comando acierta.
wait_until() {
  local end=$(( $(date +%s) + $1 )) every=$2
  shift 2
  until "$@"; do
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep "$every"
  done
}

# minutes_ago <n> — fecha UTC ISO de hace n minutos (date de BSD o de GNU).
minutes_ago() {
  date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ
}

# secret_from_stdin <ns> <nombre> <clave>... — crea o actualiza un Secret con los
# valores que llegan por stdin (uno por línea, en el orden de las claves). Los
# valores nunca pasan por la línea de comandos ni por el disco.
secret_from_stdin() {
  local ns=$1 name=$2; shift 2
  python3 -I -c '
import json, sys
ns, name, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
vals = sys.stdin.read().split("\n")
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": name, "namespace": ns},
                  "stringData": dict(zip(keys, vals))}))' "$ns" "$name" "$@" | kc apply -f - >/dev/null
}
random_password() { python3 -I -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(32)))'; }

# ---- AWS
aws_guard() { # el modo aws necesita perfil, región y una cuenta que puedas nombrar
  [ "$LAB_MODE" = aws ] || die "esto es del modo aws (LAB_MODE=$LAB_MODE en lab.env)"
  [ -n "${AWS_PROFILE:-}" ] || die "pon AWS_PROFILE en lab.env (un perfil con permisos de administrador en una cuenta de pruebas)"
  need aws
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || die "el perfil $AWS_PROFILE no tiene credenciales válidas (aws sso login --profile $AWS_PROFILE)"
}
stack_out() { # stack_out <OutputKey> — una salida de la pila del laboratorio
  aws cloudformation describe-stacks --stack-name "$NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

# ---- la tienda
pods() { # los pods de orders-api que no se están yendo
  kc -n "$NS" get pods -l "app=$DEPLOY" \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
}
none_ready() { # 0 si orders-api tiene pods y ninguno está Ready
  local s
  s=$(kc -n "$NS" get pods -l "app=$DEPLOY" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{end}')
  [ -n "$s" ] && ! grep -q true <<<"$s"
}
shop_code() { # el código HTTP que da la tienda ahora mismo, visto desde dentro del clúster
  kc -n shop-frontend exec deploy/loadgen -- sh -c \
    "wget -q -O /dev/null -S http://shop-web.shop-frontend/ 2>&1 | awk '/HTTP\//{print \$2; exit}'" 2>/dev/null || echo "?"
}
