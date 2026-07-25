#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-openbao-recovery"
pod="openbao-recovery-0"
service="openbao-recovery"
sni="openbao-recovery.reefops-openbao-recovery.svc"
state_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill"
state_file="${state_dir}/current.json"
init_file="/dev/shm/reefops-recovery-init.json"
backup_file="${REEFOPS_OPENBAO_RESTORE_FILE:?Define REEFOPS_OPENBAO_RESTORE_FILE}"
backup_digest="${REEFOPS_OPENBAO_RESTORE_SHA256:?Define REEFOPS_OPENBAO_RESTORE_SHA256}"
manifest_file="${REEFOPS_OPENBAO_RESTORE_MANIFEST:?Define REEFOPS_OPENBAO_RESTORE_MANIFEST}"
manifest_digest="${REEFOPS_OPENBAO_RESTORE_MANIFEST_SHA256:?Define REEFOPS_OPENBAO_RESTORE_MANIFEST_SHA256}"
age_identity="${REEFOPS_OPENBAO_RESTORE_IDENTITY:?Define REEFOPS_OPENBAO_RESTORE_IDENTITY}"
backup_dir="${REEFOPS_OPENBAO_BACKUP_DIR:?Define REEFOPS_OPENBAO_BACKUP_DIR}"
backup_recipient="${REEFOPS_OPENBAO_BACKUP_RECIPIENT:?Define REEFOPS_OPENBAO_BACKUP_RECIPIENT}"

if [[ ! -f "${state_file}" ]]; then
  echo "No existe un drill inicializado." >&2
  exit 1
fi
correlation_id="$(jq -er '.correlation_id' "${state_file}")"
drill_id="$(jq -er '.drill_id' "${state_file}")"
target_cluster_id="$(jq -er '.target_cluster_id' "${state_file}")"
kubernetes_cluster_uid="$(jq -er '.kubernetes_cluster_uid' "${state_file}")"
approval_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
approval_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-restore/approvals"
approval_file="${approval_dir}/${approval_id}.json"
temp_dir="$(mktemp -d)"
ca_file="${temp_dir}/ca.crt"
port_forward_log="${temp_dir}/port-forward.log"
port_forward_pid=""

finish() {
  exit_code=$?
  trap - EXIT
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
  fi
  rm -f "${ca_file}" "${port_forward_log}"
  rmdir "${temp_dir}"
  unset BAO_TOKEN
  exit "${exit_code}"
}
trap finish EXIT

install -d -m 0700 "${approval_dir}"
kubectl --context "${cluster_context}" -n "${namespace}" \
  get secret openbao-recovery-tls -o jsonpath='{.data.ca\.crt}' |
  base64 --decode >"${ca_file}"
chmod 0600 "${ca_file}"

kubectl --context "${cluster_context}" -n "${namespace}" \
  port-forward "service/${service}" 18200:8200 >"${port_forward_log}" 2>&1 &
port_forward_pid=$!
for _ in {1..20}; do
  if BAO_ADDR=https://127.0.0.1:18200 \
    BAO_CACERT="${ca_file}" \
    BAO_TLS_SERVER_NAME="${sni}" \
    bao status >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! kill -0 "${port_forward_pid}" 2>/dev/null; then
  echo "No se pudo establecer el port-forward aislado." >&2
  exit 1
fi

BAO_TOKEN="$(
  # Expansion belongs to awk inside the container.
  # shellcheck disable=SC2016
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec "${pod}" -c openbao -- \
    awk -F'"' '/"root_token"/ {print $4}' "${init_file}"
)"
export BAO_TOKEN
expires_at="$(date -u -v+30M '+%Y-%m-%dT%H:%M:%SZ')"
jq -n \
  --arg schema_version "1" \
  --arg approval_id "${approval_id}" \
  --arg encrypted_sha256 "${backup_digest}" \
  --arg restore_mode "disaster-recovery" \
  --arg target_cluster_id "${target_cluster_id}" \
  --arg target_scope "isolated-recovery" \
  --arg cluster_context "${cluster_context}" \
  --arg kubernetes_cluster_uid "${kubernetes_cluster_uid}" \
  --arg target_namespace "${namespace}" \
  --arg target_service "${service}" \
  --arg target_endpoint "https://127.0.0.1:18200" \
  --arg target_sni "${sni}" \
  --arg actor "$(id -un)" \
  --arg expires_at "${expires_at}" \
  '{
    schema_version: $schema_version,
    approval_id: $approval_id,
    encrypted_sha256: $encrypted_sha256,
    restore_mode: $restore_mode,
    target_cluster_id: $target_cluster_id,
    target_scope: $target_scope,
    cluster_context: $cluster_context,
    kubernetes_cluster_uid: $kubernetes_cluster_uid,
    target_namespace: $target_namespace,
    target_service: $target_service,
    target_endpoint: $target_endpoint,
    target_sni: $target_sni,
    actor: $actor,
    expires_at: $expires_at
  }' >"${approval_file}"
chmod 0600 "${approval_file}"

BAO_ADDR=https://127.0.0.1:18200 \
BAO_CACERT="${ca_file}" \
BAO_TLS_SERVER_NAME="${sni}" \
REEFOPS_CLUSTER_CONTEXT="${cluster_context}" \
REEFOPS_CORRELATION_ID="${correlation_id}" \
REEFOPS_CAUSATION_ID="${drill_id}" \
REEFOPS_OPENBAO_RESTORE_FILE="${backup_file}" \
REEFOPS_OPENBAO_RESTORE_SHA256="${backup_digest}" \
REEFOPS_OPENBAO_RESTORE_MANIFEST="${manifest_file}" \
REEFOPS_OPENBAO_RESTORE_MANIFEST_SHA256="${manifest_digest}" \
REEFOPS_OPENBAO_RESTORE_IDENTITY="${age_identity}" \
REEFOPS_OPENBAO_RESTORE_MODE=disaster-recovery \
REEFOPS_OPENBAO_RESTORE_TARGET_SCOPE=isolated-recovery \
REEFOPS_OPENBAO_RESTORE_TARGET_NAMESPACE="${namespace}" \
REEFOPS_OPENBAO_RESTORE_TARGET_SERVICE="${service}" \
REEFOPS_OPENBAO_RESTORE_APPROVAL_FILE="${approval_file}" \
REEFOPS_OPENBAO_BACKUP_DIR="${backup_dir}" \
REEFOPS_OPENBAO_BACKUP_RECIPIENT="${backup_recipient}" \
REEFOPS_ORIGINAL_SEAL_MATERIAL_CONFIRMED=true \
REEFOPS_CONFIRM_OPENBAO_RESTORE="force-restore-${backup_digest}" \
  "${project_root}/bootstrap/scripts/restore-openbao.sh"

kubectl --context "${cluster_context}" -n "${namespace}" \
  exec "${pod}" -c openbao -- rm -f "${init_file}"
jq '.phase = "snapshot-applied-awaiting-original-unseal"' \
  "${state_file}" >"${state_file}.new"
chmod 0600 "${state_file}.new"
mv "${state_file}.new" "${state_file}"

echo "Snapshot aplicado al target aislado."
echo "Introduce ahora las claves Shamir originales mediante el comando interactivo."
