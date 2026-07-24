#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
backup_dir="${REEFOPS_OPENBAO_CA_BACKUP_DIR:?Define un directorio externo}"
age_recipient="${REEFOPS_OPENBAO_BACKUP_RECIPIENT:?Define el recipient age}"
audit_dir="${REEFOPS_OPENBAO_CA_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-ca}"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
backup_file="${backup_dir}/openbao-ca-${timestamp}.json.age"
backup_digest=""
result="failure"

install -d -m 0700 "${backup_dir}" "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

finish() {
  exit_code=$?
  trap - EXIT
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg backup_file "${backup_file}" \
    --arg digest "${backup_digest}" \
    --arg result "${result}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authorization: "kubernetes-read-openbao-ca",
      backup_file: $backup_file,
      encrypted_sha256: (if $digest == "" then null else $digest end),
      result: $result,
      error: (if $result == "success" then null else "ca-backup-failed" end)
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

kubectl --context "${cluster_context}" \
  -n reefops-secrets get secret openbao-ca -o json |
  jq '{
    apiVersion,
    kind,
    metadata: {
      name: .metadata.name,
      namespace: .metadata.namespace
    },
    type,
    data
  }' |
  age --recipient "${age_recipient}" --output "${backup_file}"
chmod 0600 "${backup_file}"
backup_digest="$(shasum -a 256 "${backup_file}" | awk '{print $1}')"
result="success"

echo "CA OpenBao cifrada: ${backup_file}"
echo "SHA-256 cifrado: ${backup_digest}"
