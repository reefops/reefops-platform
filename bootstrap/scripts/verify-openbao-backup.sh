#!/usr/bin/env bash
set -euo pipefail

encrypted_backup="${REEFOPS_OPENBAO_VERIFY_FILE:?Define REEFOPS_OPENBAO_VERIFY_FILE}"
expected_digest="${REEFOPS_OPENBAO_VERIFY_SHA256:?Define REEFOPS_OPENBAO_VERIFY_SHA256}"
age_identity="${REEFOPS_OPENBAO_VERIFY_IDENTITY:?Define REEFOPS_OPENBAO_VERIFY_IDENTITY}"
manifest_file="${REEFOPS_OPENBAO_VERIFY_MANIFEST:?Define REEFOPS_OPENBAO_VERIFY_MANIFEST}"
expected_manifest_digest="${REEFOPS_OPENBAO_VERIFY_MANIFEST_SHA256:?Define el digest esperado del manifiesto}"
audit_dir="${REEFOPS_OPENBAO_VERIFY_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-backup-verification}"
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

if [[ ! -f "${encrypted_backup}" || ! -f "${age_identity}" ||
  ! -f "${manifest_file}" ]]; then
  echo "No existe el backup, la identidad age o el manifiesto indicado." >&2
  exit 1
fi

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"
temp_dir="$(mktemp -d)"
snapshot_file="${temp_dir}/openbao.snap"
manifest_plain="${temp_dir}/manifest.json"
chmod 0700 "${temp_dir}"

finish() {
  exit_code=$?
  trap - EXIT
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
      authentication: "age-identity",
      authorization: "local-backup-verification",
      encrypted_backup: $source,
      expected_sha256: $expected_digest,
      started_at: $started_at,
      finished_at: $finished_at,
      result: $result,
      openbao_version: $openbao_version,
      snapshot: {
        version: $snapshot_version,
        id: $snapshot_id,
        index: $snapshot_index,
        term: $snapshot_term,
        size: $snapshot_size
      },
      error: (if $result == "success" then null else "backup-verification-failed" end),
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
if ! jq -e \
  --arg digest "${expected_digest}" \
  --arg openbao_version "${openbao_version}" \
  '
    .schema_version == "1" and
    .encrypted_sha256 == $digest and
    .openbao_version == $openbao_version and
    (.cluster_id | type == "string" and length > 0)
  ' "${manifest_plain}" >/dev/null; then
  echo "El manifiesto no corresponde al backup o a esta versión de OpenBao." >&2
  exit 1
fi

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
result="success"

echo "Snapshot cifrado verificado sin restauración: ${encrypted_backup}"
