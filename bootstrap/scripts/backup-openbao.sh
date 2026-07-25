#!/usr/bin/env bash
set -euo pipefail

backup_dir="${REEFOPS_OPENBAO_BACKUP_DIR:?Define un directorio externo en REEFOPS_OPENBAO_BACKUP_DIR}"
age_recipient="${REEFOPS_OPENBAO_BACKUP_RECIPIENT:?Define el recipient age de backup}"
audit_dir="${REEFOPS_OPENBAO_BACKUP_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-backup}"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
backup_file="${backup_dir}/openbao-${timestamp}.snap.age"
backup_digest=""
result="failure"
temp_dir="$(mktemp -d)"
snapshot_file="${temp_dir}/openbao.snap"
token_origin="provided"

install -d -m 0700 "${backup_dir}" "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

finish() {
  exit_code=$?
  trap - EXIT
  rm -f "${snapshot_file}"
  rmdir "${temp_dir}"
  if [[ "${token_origin}" == "kubernetes" ]]; then
    unset BAO_TOKEN
  fi
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg created_at "${timestamp}" \
    --arg backup_file "${backup_file}" \
    --arg backup_digest "${backup_digest}" \
    --arg result "${result}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "openbao-token",
      authorization: "openbao-backup-policy",
      created_at: $created_at,
      backup_file: $backup_file,
      encrypted_sha256: (if $backup_digest == "" then null else $backup_digest end),
      result: $result,
      error: (if $result == "success" then null else "backup-operation-failed" end),
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

if [[ -z "${BAO_TOKEN:-}" ]]; then
  cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
  service_account_token="$(
    kubectl --context "${cluster_context}" \
      -n reefops-system create token openbao-backup --duration=5m
  )"
  login_response="$(
    printf '%s' "${service_account_token}" |
      bao write -format=json auth/kubernetes/login \
        role=reefops-backup jwt=-
  )"
  unset service_account_token
  BAO_TOKEN="$(jq -er '.auth.client_token' <<<"${login_response}")"
  export BAO_TOKEN
  unset login_response
  token_origin="kubernetes"
fi

bao status >/dev/null
bao operator raft snapshot save "${snapshot_file}"
chmod 0600 "${snapshot_file}"
age --recipient "${age_recipient}" --output "${backup_file}" "${snapshot_file}"
chmod 0600 "${backup_file}"

backup_digest="$(shasum -a 256 "${backup_file}" | awk '{print $1}')"
result="success"

echo "Snapshot OpenBao cifrado: ${backup_file}"
echo "SHA-256 cifrado: ${backup_digest}"
