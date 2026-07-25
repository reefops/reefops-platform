#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
encrypted_backup="${REEFOPS_OPENBAO_RESTORE_FILE:?Define REEFOPS_OPENBAO_RESTORE_FILE}"
expected_digest="${REEFOPS_OPENBAO_RESTORE_SHA256:?Define el digest esperado}"
age_identity="${REEFOPS_OPENBAO_RESTORE_IDENTITY:?Define REEFOPS_OPENBAO_RESTORE_IDENTITY}"
restore_mode="${REEFOPS_OPENBAO_RESTORE_MODE:?Define in-place o disaster-recovery}"
manifest_file="${REEFOPS_OPENBAO_RESTORE_MANIFEST:?Define el manifiesto del backup}"
expected_manifest_digest="${REEFOPS_OPENBAO_RESTORE_MANIFEST_SHA256:?Define el digest esperado del manifiesto}"
approval_file="${REEFOPS_OPENBAO_RESTORE_APPROVAL_FILE:?Define el artefacto de aprobación}"
confirmation="${REEFOPS_CONFIRM_OPENBAO_RESTORE:-}"
cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
audit_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-restore"
approvals_dir="${audit_dir}/approvals"
consumed_dir="${audit_dir}/consumed"
lock_dir="${audit_dir}/restore.lock"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result="failure"
snapshot_version=""
snapshot_id=""
snapshot_index=""
snapshot_term=""
snapshot_size=""
openbao_version="$(bao version)"
target_cluster_id=""
approval_id=""
approval_sha256=""
producer_version=""

if [[ "${restore_mode}" != "in-place" && "${restore_mode}" != "disaster-recovery" ]]; then
  echo "REEFOPS_OPENBAO_RESTORE_MODE debe ser in-place o disaster-recovery." >&2
  exit 1
fi
expected_confirmation="restore-${expected_digest}"
if [[ "${restore_mode}" == "disaster-recovery" ]]; then
  expected_confirmation="force-restore-${expected_digest}"
  if [[ "${REEFOPS_ORIGINAL_SEAL_MATERIAL_CONFIRMED:-}" != "true" ]]; then
    echo "Confirma la custodia del seal material original." >&2
    exit 1
  fi
fi
if [[ "${confirmation}" != "${expected_confirmation}" ]]; then
  echo "Confirma con REEFOPS_CONFIRM_OPENBAO_RESTORE=${expected_confirmation}" >&2
  exit 1
fi
if [[ ! -f "${encrypted_backup}" || ! -f "${age_identity}" ||
  ! -f "${manifest_file}" || ! -f "${approval_file}" ]]; then
  echo "Falta el backup, la identidad, el manifiesto o la aprobación." >&2
  exit 1
fi

install -d -m 0700 "${audit_dir}" "${approvals_dir}" "${consumed_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"
if [[ "$(dirname "${approval_file}")" != "${approvals_dir}" ]]; then
  echo "La aprobación debe residir en ${approvals_dir}." >&2
  exit 1
fi
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Ya existe una restauración OpenBao en curso." >&2
  exit 1
fi
temp_dir="$(mktemp -d)"
snapshot_file="${temp_dir}/openbao.snap"
manifest_plain="${temp_dir}/manifest.json"
chmod 0700 "${temp_dir}"

finish() {
  exit_code=$?
  trap - EXIT
  rmdir "${lock_dir}"
  rm -f \
    "${snapshot_file}" \
    "${manifest_plain}" \
    "${temp_dir}/meta.json" \
    "${temp_dir}/state.bin" \
    "${temp_dir}/SHA256SUMS"
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
    --arg approval_id "${approval_id}" \
    --arg approval_sha256 "${approval_sha256}" \
    --arg target_cluster_context "${cluster_context}" \
    --arg target_cluster_id "${target_cluster_id}" \
    --arg openbao_version "${openbao_version}" \
    --arg snapshot_version "${snapshot_version}" \
    --arg snapshot_id "${snapshot_id}" \
    --arg snapshot_index "${snapshot_index}" \
    --arg snapshot_term "${snapshot_term}" \
    --arg snapshot_size "${snapshot_size}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "openbao-token-and-age-identity",
      authorization: "local-bootstrap-approval-artifact",
      encrypted_backup: $source,
      expected_sha256: $expected_digest,
      restore_mode: $restore_mode,
      approval_id: $approval_id,
      approval_sha256: $approval_sha256,
      target_cluster_context: $target_cluster_context,
      target_cluster_id: $target_cluster_id,
      openbao_version: $openbao_version,
      snapshot: {
        version: $snapshot_version,
        id: $snapshot_id,
        index: $snapshot_index,
        term: $snapshot_term,
        size: $snapshot_size
      },
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

target_cluster_id="$(bao status -format=json | jq -er '.cluster_id')"
actual_manifest_digest="$(shasum -a 256 "${manifest_file}" | awk '{print $1}')"
if [[ "${actual_manifest_digest}" != "${expected_manifest_digest}" ]]; then
  echo "El digest del manifiesto cifrado no coincide con la procedencia esperada." >&2
  exit 1
fi
age --decrypt \
  --identity "${age_identity}" \
  --output "${manifest_plain}" \
  "${manifest_file}"
chmod 0600 "${manifest_plain}"
producer_version="$(jq -er '.openbao_version' "${manifest_plain}")"
if ! jq -e \
  --arg digest "${expected_digest}" \
  --arg producer_version "${producer_version}" \
  '
    .schema_version == "1" and
    .encrypted_sha256 == $digest and
    .openbao_version == $producer_version and
    (.cluster_id | type == "string" and length > 0)
  ' "${manifest_plain}" >/dev/null; then
  echo "El manifiesto no corresponde al backup." >&2
  exit 1
fi
if [[ "${producer_version}" != "${openbao_version}" ]]; then
  echo "La versión productora y la versión restauradora no coinciden." >&2
  exit 1
fi

approval_id="$(jq -er '.approval_id' "${approval_file}")"
approval_sha256="$(shasum -a 256 "${approval_file}" | awk '{print $1}')"
approval_mode="$(stat -f '%Lp' "${approval_file}")"
approval_owner="$(stat -f '%Su' "${approval_file}")"
if [[ "${approval_owner}" != "$(id -un)" ||
  ("${approval_mode}" != "400" && "${approval_mode}" != "600") ]]; then
  echo "La aprobación debe pertenecer al actor y tener modo 0400 o 0600." >&2
  exit 1
fi
if ! jq -e \
  --arg digest "${expected_digest}" \
  --arg restore_mode "${restore_mode}" \
  --arg cluster_id "${target_cluster_id}" \
  --arg actor "$(id -un)" \
  --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '
    .schema_version == "1" and
    (.approval_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    .encrypted_sha256 == $digest and
    .restore_mode == $restore_mode and
    .target_cluster_id == $cluster_id and
    .actor == $actor and
    (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    .expires_at > $now
  ' "${approval_file}" >/dev/null; then
  echo "La aprobación no autoriza esta operación o está caducada." >&2
  exit 1
fi
consumed_approval="${consumed_dir}/${approval_id}.json"
if [[ -e "${consumed_approval}" ]]; then
  echo "La aprobación ya fue consumida." >&2
  exit 1
fi
mv "${approval_file}" "${consumed_approval}"

REEFOPS_CORRELATION_ID="${correlation_id}" \
REEFOPS_CAUSATION_ID="${operation_id}" \
  "${project_root}/bootstrap/scripts/backup-openbao.sh"

age --decrypt \
  --identity "${age_identity}" \
  --output "${snapshot_file}" \
  "${encrypted_backup}"
chmod 0600 "${snapshot_file}"
for required_member in meta.json state.bin SHA256SUMS; do
  if ! tar -tf "${snapshot_file}" | grep -Fxq "${required_member}"; then
    echo "El snapshot no contiene ${required_member}." >&2
    exit 1
  fi
done
tar -xf "${snapshot_file}" -C "${temp_dir}" meta.json state.bin SHA256SUMS
(
  cd "${temp_dir}"
  shasum -a 256 --check SHA256SUMS >/dev/null
)
snapshot_version="$(jq -er '.Version' "${temp_dir}/meta.json")"
snapshot_id="$(jq -er '.ID' "${temp_dir}/meta.json")"
snapshot_index="$(jq -er '.Index' "${temp_dir}/meta.json")"
snapshot_term="$(jq -er '.Term' "${temp_dir}/meta.json")"
snapshot_size="$(jq -er '.Size' "${temp_dir}/meta.json")"
if [[ "${restore_mode}" == "disaster-recovery" ]]; then
  bao operator raft snapshot restore -force "${snapshot_file}"
else
  bao operator raft snapshot restore "${snapshot_file}"
fi
result="restore-applied-awaiting-verification"

echo "Snapshot aplicado desde ${encrypted_backup}."
echo "Realiza unseal con el material original, autentica y ejecuta task openbao-verify-recovery."
echo "Conserva REEFOPS_CORRELATION_ID=${correlation_id} y REEFOPS_CAUSATION_ID=${operation_id}."
