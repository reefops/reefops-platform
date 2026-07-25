#!/usr/bin/env bash
set -euo pipefail

: "${BAO_TOKEN:?Define BAO_TOKEN mediante lectura silenciosa}"

project_root="$(git rev-parse --show-toplevel)"
cluster_context="${REEFOPS_KUBE_CONTEXT:-docker-desktop}"
environment_id="${REEFOPS_ENVIRONMENT_ID:-development}"
namespace="reefops-secrets"
local_port="${REEFOPS_OPENBAO_SEAWEEDFS_PORT:-18203}"
temp_dir="$(mktemp -d)"
ca_file="${temp_dir}/openbao-ca.crt"
port_forward_log="${temp_dir}/port-forward.log"
port_forward_pid=""
lock_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/seaweedfs/credentials.lock"
lock_acquired="false"

cleanup() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  if [[ "${lock_acquired}" == "true" ]]; then
    rmdir "${lock_dir}" >/dev/null 2>&1 || true
  fi
  find "${temp_dir}" -type f -exec sh -c ': > "$1"' _ {} \;
  rmdir "${temp_dir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

install -d -m 0700 "$(dirname "${lock_dir}")"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Ya existe un bootstrap de credenciales SeaweedFS en curso." >&2
  exit 1
fi
lock_acquired="true"

if [[ "$(kubectl config current-context)" != "${cluster_context}" ]]; then
  echo "Contexto Kubernetes inesperado." >&2
  exit 1
fi
if [[ "$(
  kubectl --context "${cluster_context}" get namespace "${namespace}" \
    -o jsonpath='{.metadata.labels.reefops\.io/environment}'
)" != "${environment_id}" ]]; then
  echo "El namespace OpenBao no pertenece al entorno esperado." >&2
  exit 1
fi

kubectl --context "${cluster_context}" -n "${namespace}" \
  get secret openbao-ca -o jsonpath='{.data.ca\.crt}' |
  base64 --decode >"${ca_file}"
chmod 0600 "${ca_file}"

kubectl --context "${cluster_context}" -n "${namespace}" \
  port-forward service/openbao "${local_port}:8200" \
  >"${port_forward_log}" 2>&1 &
port_forward_pid=$!

export BAO_ADDR="https://127.0.0.1:${local_port}"
export BAO_CACERT="${ca_file}"
export BAO_TLS_SERVER_NAME="openbao.reefops-secrets.svc"

for _ in $(seq 1 30); do
  if bao status -format=json >"${temp_dir}/status.json" 2>/dev/null; then
    break
  fi
  sleep 1
done

cluster_id="$(
  jq -er 'select(.initialized == true and .sealed == false) | .cluster_id' \
    "${temp_dir}/status.json"
)"
in_pod_cluster_id="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec openbao-0 -c openbao -- \
    env BAO_TLS_SERVER_NAME=openbao.reefops-secrets.svc \
    bao status -format=json |
    jq -er 'select(.initialized == true and .sealed == false) | .cluster_id'
)"
if [[ "${cluster_id}" != "${in_pod_cluster_id}" ]]; then
  echo "El endpoint no corresponde al OpenBao activo." >&2
  exit 1
fi

export REEFOPS_KUBE_CONTEXT="${cluster_context}"
export REEFOPS_ENVIRONMENT_ID="${environment_id}"
export REEFOPS_OPENBAO_CLUSTER_ID="${cluster_id}"

"${project_root}/bootstrap/scripts/bootstrap-seaweedfs-credentials.sh"
