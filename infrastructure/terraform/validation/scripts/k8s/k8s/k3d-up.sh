#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-honua-k3d}"
HTTP_PORT="${K3D_HTTP_PORT:-8080}"
HTTPS_PORT="${K3D_HTTPS_PORT:-8443}"
API_PORT="${K3D_API_PORT:-6550}"
SERVERS="${K3D_SERVERS:-1}"
AGENTS="${K3D_AGENTS:-0}"
NO_LB="${K3D_NO_LB:-false}"

command -v k3d >/dev/null 2>&1 || { echo "k3d is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }

if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
  echo "k3d cluster '${CLUSTER_NAME}' already exists"
else
  args=(
    cluster create "${CLUSTER_NAME}"
    --api-port "${API_PORT}"
    --servers "${SERVERS}"
    --agents "${AGENTS}"
  )

  if [[ "${NO_LB}" == "true" ]]; then
    args+=(--no-lb)
  else
    args+=(
      -p "${HTTP_PORT}:80@loadbalancer"
      -p "${HTTPS_PORT}:443@loadbalancer"
    )
  fi

  k3d "${args[@]}"
fi

if kubectl -n kube-system get deployment traefik >/dev/null 2>&1; then
  kubectl -n kube-system rollout status deployment/traefik --timeout=120s
else
  echo "traefik deployment not found; install an ingress controller before testing ingress."
fi

echo "k3d cluster '${CLUSTER_NAME}' ready"
if [[ "${NO_LB}" == "true" ]]; then
  echo "k3d load balancer disabled; use port-forward access mode for HTTP checks"
else
  echo "traefik is listening on localhost:${HTTP_PORT} (HTTP) and :${HTTPS_PORT} (HTTPS)"
fi
