#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
encrypted_backup="${REEFOPS_OPENBAO_CA_RESTORE_FILE:?Define el backup de CA}"
expected_digest="${REEFOPS_OPENBAO_CA_RESTORE_SHA256:?Define el digest esperado}"
age_identity="${REEFOPS_OPENBAO_CA_RESTORE_IDENTITY:?Define la identidad age}"
confirmation="${REEFOPS_CONFIRM_OPENBAO_CA_RESTORE:-}"
audit_dir="${REEFOPS_OPENBAO_CA_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-ca}"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
result="failure"

if [[ "${confirmation}" != "restore-${encrypted_backup}" ]]; then
  echo "Confirma con REEFOPS_CONFIRM_OPENBAO_CA_RESTORE=restore-${encrypted_backup}" >&2
  exit 1
fi
actual_digest="$(shasum -a 256 "${encrypted_backup}" | awk '{print $1}')"
if [[ "${actual_digest}" != "${expected_digest}" ]]; then
  echo "El digest cifrado de la CA no coincide." >&2
  exit 1
fi

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

finish() {
  exit_code=$?
  trap - EXIT
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg backup_file "${encrypted_backup}" \
    --arg digest "${expected_digest}" \
    --arg result "${result}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authorization: "explicit-ca-restore",
      backup_file: $backup_file,
      encrypted_sha256: $digest,
      result: $result,
      error: (if $result == "success" then null else "ca-restore-failed" end)
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

age --decrypt --identity "${age_identity}" "${encrypted_backup}" |
  jq -e '
    select(
      .apiVersion == "v1" and
      .kind == "Secret" and
      .metadata.name == "openbao-ca" and
      .metadata.namespace == "reefops-secrets" and
      .data."tls.crt" != null and
      .data."tls.key" != null
    )
  ' |
  kubectl --context "${cluster_context}" apply -f - >/dev/null

result="success"
echo "CA OpenBao restaurada; reconcilia PKI antes de OpenBao."
