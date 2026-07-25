#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
encrypted_backup="${REEFOPS_OPENBAO_RESTORE_FILE:?Define REEFOPS_OPENBAO_RESTORE_FILE}"
expected_digest="${REEFOPS_OPENBAO_RESTORE_SHA256:?Define el digest esperado}"
age_identity="${REEFOPS_OPENBAO_RESTORE_IDENTITY:?Define REEFOPS_OPENBAO_RESTORE_IDENTITY}"
restore_mode="${REEFOPS_OPENBAO_RESTORE_MODE:?Define in-place o disaster-recovery}"
confirmation="${REEFOPS_CONFIRM_OPENBAO_RESTORE:-}"
audit_dir="${REEFOPS_OPENBAO_RESTORE_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-restore}"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result="failure"

if [[ "${restore_mode}" != "in-place" && "${restore_mode}" != "disaster-recovery" ]]; then
  echo "REEFOPS_OPENBAO_RESTORE_MODE debe ser in-place o disaster-recovery." >&2
  exit 1
fi
expected_confirmation="restore-${encrypted_backup}"
if [[ "${restore_mode}" == "disaster-recovery" ]]; then
  expected_confirmation="force-restore-${encrypted_backup}"
  if [[ "${REEFOPS_ORIGINAL_SEAL_MATERIAL_CONFIRMED:-}" != "true" ]]; then
    echo "Confirma la custodia del seal material original." >&2
    exit 1
  fi
fi
if [[ "${confirmation}" != "${expected_confirmation}" ]]; then
  echo "Confirma con REEFOPS_CONFIRM_OPENBAO_RESTORE=${expected_confirmation}" >&2
  exit 1
fi
if [[ ! -f "${encrypted_backup}" || ! -f "${age_identity}" ]]; then
  echo "No existe el backup cifrado o la identidad age indicada." >&2
  exit 1
fi

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"
temp_dir="$(mktemp -d)"
snapshot_file="${temp_dir}/openbao.snap"
chmod 0700 "${temp_dir}"

finish() {
  exit_code=$?
  trap - EXIT
  rm -f "${snapshot_file}"
  rmdir "${temp_dir}"
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg source "${encrypted_backup}" \
    --arg expected_digest "${expected_digest}" \
    --arg started_at "${started_at}" \
    --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg result "${result}" \
    --arg restore_mode "${restore_mode}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "openbao-token-and-age-identity",
      authorization: "explicit-restore-confirmation",
      encrypted_backup: $source,
      expected_sha256: $expected_digest,
      restore_mode: $restore_mode,
      started_at: $started_at,
      finished_at: $finished_at,
      result: $result,
      error: (if $result == "failure" then "restore-operation-failed" else null end),
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

actual_digest="$(shasum -a 256 "${encrypted_backup}" | awk '{print $1}')"
if [[ "${actual_digest}" != "${expected_digest}" ]]; then
  echo "El digest cifrado no coincide con la procedencia esperada." >&2
  exit 1
fi

bao status >/dev/null
"${project_root}/bootstrap/scripts/backup-openbao.sh"

age --decrypt \
  --identity "${age_identity}" \
  --output "${snapshot_file}" \
  "${encrypted_backup}"
chmod 0600 "${snapshot_file}"
bao operator raft snapshot inspect "${snapshot_file}" >/dev/null
if [[ "${restore_mode}" == "disaster-recovery" ]]; then
  bao operator raft snapshot restore -force "${snapshot_file}"
else
  bao operator raft snapshot restore "${snapshot_file}"
fi
result="restore-applied-awaiting-verification"

echo "Snapshot aplicado desde ${encrypted_backup}."
echo "Realiza unseal con el material original, autentica y ejecuta task openbao-verify-recovery."
