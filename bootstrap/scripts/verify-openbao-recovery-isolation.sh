#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-openbao-recovery"
release="openbao-recovery"
active_namespace="reefops-secrets"
active_pod="openbao-0"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
audit_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill"
result="failure"

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

finish() {
  exit_code=$?
  trap - EXIT
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg cluster_context "${cluster_context}" \
    --arg namespace "${namespace}" \
    --arg git_revision "$(git rev-parse HEAD)" \
    --arg result "${result}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "local-kubernetes-context",
      authorization: "local-recovery-drill-preflight",
      cluster_context: $cluster_context,
      namespace: $namespace,
      git_revision: $git_revision,
      result: $result,
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

if [[ "$(kubectl config current-context)" != "${cluster_context}" ]]; then
  echo "El contexto Kubernetes actual no coincide con el esperado." >&2
  exit 1
fi
kubectl --context "${cluster_context}" -n "${active_namespace}" \
  wait --for=condition=Ready "pod/${active_pod}" --timeout=30s >/dev/null
kubectl --context "${cluster_context}" -n "${namespace}" \
  get helmrelease "${release}" >/dev/null
kubectl --context "${cluster_context}" -n "${namespace}" \
  wait --for=condition=Ready certificate/openbao-recovery --timeout=60s >/dev/null
kubectl --context "${cluster_context}" -n "${namespace}" \
  get serviceaccount "${release}" \
  -o jsonpath='{.automountServiceAccountToken}' | grep -Fxq 'false'
runtime_node_id="$(
  # Expansion belongs to awk inside the container.
  # shellcheck disable=SC2016
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec "${release}-0" -c openbao -- \
    awk '/node_id/ {gsub(/[\" ]/, "", $3); print $3}' /tmp/storageconfig.hcl
)"
if [[ "${runtime_node_id}" != "reefops-local-0" ]]; then
  echo "El node ID no coincide con la membresía Raft esperada." >&2
  exit 1
fi

if kubectl --context "${cluster_context}" get clusterrolebinding \
  -o json |
  jq -e --arg namespace "${namespace}" \
    '.items[] | select(any(.subjects[]?; .namespace == $namespace))' >/dev/null; then
  echo "El namespace de recuperación tiene RBAC cluster-wide." >&2
  exit 1
fi

status_json="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec "${release}-0" -c openbao -- \
    env BAO_TLS_SERVER_NAME=openbao-recovery.reefops-openbao-recovery.svc \
    bao status -format=json 2>/dev/null ||
    true
)"
if [[ -z "${status_json}" ]]; then
  echo "No se pudo obtener el estado TLS del target de recuperación." >&2
  exit 1
fi
if [[ "$(jq -r '.initialized // false' <<<"${status_json}")" != "false" ]]; then
  echo "El target de recuperación ya está inicializado." >&2
  exit 1
fi

result="success"
echo "Entorno OpenBao de recuperación aislado y sin inicializar."
