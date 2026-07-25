#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-openbao-recovery"

if kubectl --context "${cluster_context}" get namespace "${namespace}" >/dev/null 2>&1; then
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get helmrelease,statefulset,pod,persistentvolumeclaim 2>/dev/null || true
  echo "La limpieza del ensayo no está completa: ${namespace} todavía existe." >&2
  exit 1
fi

echo "Limpieza del ensayo OpenBao verificada."
