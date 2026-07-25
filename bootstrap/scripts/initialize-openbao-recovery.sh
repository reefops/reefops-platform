#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-openbao-recovery"
pod="openbao-recovery-0"
sni="openbao-recovery.reefops-openbao-recovery.svc"
state_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill"
state_file="${state_dir}/current.json"
init_file="/dev/shm/reefops-recovery-init.json"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

install -d -m 0700 "${state_dir}"
if [[ -e "${state_file}" ]]; then
  echo "Ya existe un drill activo en ${state_file}." >&2
  exit 1
fi

REEFOPS_CORRELATION_ID="${correlation_id}" \
REEFOPS_CAUSATION_ID="${operation_id}" \
  "${project_root}/bootstrap/scripts/verify-openbao-recovery-isolation.sh"

active_cluster_id="$(
  kubectl --context "${cluster_context}" -n reefops-secrets \
    exec openbao-0 -c openbao -- \
    env BAO_TLS_SERVER_NAME=openbao.reefops-secrets.svc bao status -format=json |
    jq -er '.cluster_id'
)"
gitops_revision="$(
  kubectl --context "${cluster_context}" -n flux-system \
    get kustomization reefops-openbao-recovery \
    -o jsonpath='{.status.lastAppliedRevision}'
)"
kubernetes_cluster_uid="$(
  kubectl --context "${cluster_context}" get namespace kube-system \
    -o jsonpath='{.metadata.uid}'
)"
jq -n \
  --arg schema_version "1" \
  --arg drill_id "${operation_id}" \
  --arg correlation_id "${correlation_id}" \
  --arg started_at "${started_at}" \
  --arg cluster_context "${cluster_context}" \
  --arg kubernetes_cluster_uid "${kubernetes_cluster_uid}" \
  --arg gitops_revision "${gitops_revision}" \
  --arg active_cluster_id_before "${active_cluster_id}" \
  '{
    schema_version: $schema_version,
    drill_id: $drill_id,
    correlation_id: $correlation_id,
    started_at: $started_at,
    cluster_context: $cluster_context,
    kubernetes_cluster_uid: $kubernetes_cluster_uid,
    gitops_revision: $gitops_revision,
    active_cluster_id_before: $active_cluster_id_before,
    phase: "initialization-started-result-uncertain"
  }' >"${state_file}"
chmod 0600 "${state_file}"

kubectl --context "${cluster_context}" -n "${namespace}" \
  exec "${pod}" -c openbao -- /bin/sh -c \
  'umask 077; env BAO_TLS_SERVER_NAME=openbao-recovery.reefops-openbao-recovery.svc bao operator init -format=json > /dev/shm/reefops-recovery-init.json'

init_json="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec "${pod}" -c openbao -- cat "${init_file}"
)"
for index in 0 1 2; do
  unseal_key="$(jq -er --argjson index "${index}" '.unseal_keys_b64[$index]' <<<"${init_json}")"
  printf '%s\n' "${unseal_key}" |
    kubectl --context "${cluster_context}" -n "${namespace}" \
      exec -i "${pod}" -c openbao -- \
      env BAO_TLS_SERVER_NAME="${sni}" bao operator unseal >/dev/null
  unset unseal_key
done
unset init_json

target_cluster_id="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec "${pod}" -c openbao -- \
    env BAO_TLS_SERVER_NAME="${sni}" bao status -format=json |
    jq -er '.cluster_id'
)"
jq \
  --arg target_cluster_id "${target_cluster_id}" \
  '.target_cluster_id = $target_cluster_id |
   .phase = "temporary-target-unsealed"' \
  "${state_file}" >"${state_file}.new"
chmod 0600 "${state_file}.new"
mv "${state_file}.new" "${state_file}"

echo "Target temporal inicializado y abierto sin exponer material sensible."
echo "Drill: ${operation_id}"
