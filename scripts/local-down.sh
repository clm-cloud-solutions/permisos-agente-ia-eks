#!/usr/bin/env bash
# local-down.sh — borra el clúster kind del laboratorio y su estado local.
# Si lo conectaste a KubeBolt Cloud, el clúster queda allí como desconectado:
# bórralo desde Fleet (o Administration → Agents & Ingest) y revoca su token.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kind
if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  kind delete cluster --name "$NAME"
  ok "clúster kind $NAME borrado"
else
  ok "no había clúster kind $NAME"
fi
rm -f "$KUBECONFIG_FILE" "$STATE/kind.yaml"
