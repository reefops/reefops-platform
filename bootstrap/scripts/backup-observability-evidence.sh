#!/usr/bin/env bash
set -Eeuo pipefail

evidence_file="${REEFOPS_OBSERVABILITY_EVIDENCE_FILE:-${HOME}/.local/state/reefops/observability/operations.jsonl}"
evidence_lock="${evidence_file}.lock"
backup_dir="${REEFOPS_OBSERVABILITY_BACKUP_DIR:?Define un directorio externo}"
age_recipient="${REEFOPS_OBSERVABILITY_BACKUP_RECIPIENT:?Define el recipient age}"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
backup_file="${backup_dir}/observability-evidence-${timestamp}-${operation_id}.jsonl.age"
manifest_file="${backup_file}.manifest.json.age"
temp_dir="$(mktemp -d)"
manifest_plain="${temp_dir}/manifest.json"
evidence_lock_acquired="false"

cleanup() {
  rm -f "${manifest_plain}"
  rmdir "${temp_dir}"
  if [[ "${evidence_lock_acquired}" == "true" ]]; then
    rmdir "${evidence_lock}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ ! -s "${evidence_file}" ]]; then
  echo "No existe evidencia de observabilidad para respaldar." >&2
  exit 2
fi
if ! mkdir "${evidence_lock}" 2>/dev/null; then
  echo "La evidencia está siendo escrita o respaldada." >&2
  exit 2
fi
evidence_lock_acquired="true"

expected_previous=""
record_count=0
while IFS= read -r line; do
  previous="$(jq -er '.previous_record_sha256 // ""' <<<"${line}")"
  recorded_hash="$(jq -er '.record_sha256' <<<"${line}")"
  base_record="$(jq -c 'del(.record_sha256)' <<<"${line}")"
  computed_hash="$(
    printf '%s' "${base_record}" | shasum -a 256 | awk '{print $1}'
  )"
  if [[ "${previous}" != "${expected_previous}" ||
    "${computed_hash}" != "${recorded_hash}" ]]; then
    echo "La cadena de evidencia no es íntegra; no se respalda." >&2
    exit 3
  fi
  expected_previous="${recorded_hash}"
  record_count="$((record_count + 1))"
done <"${evidence_file}"

install -d -m 0700 "${backup_dir}"
age --recipient "${age_recipient}" \
  --output "${backup_file}" "${evidence_file}"
chmod 0600 "${backup_file}"
encrypted_sha256="$(
  shasum -a 256 "${backup_file}" | awk '{print $1}'
)"
source_sha256="$(
  shasum -a 256 "${evidence_file}" | awk '{print $1}'
)"

jq -n \
  --arg schema_version "1" \
  --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg actor "$(id -un)" \
  --arg source "$(basename "${evidence_file}")" \
  --arg source_sha256 "${source_sha256}" \
  --arg encrypted_backup "$(basename "${backup_file}")" \
  --arg encrypted_sha256 "${encrypted_sha256}" \
  --argjson record_count "${record_count}" \
  '{
    schema_version: $schema_version,
    created_at: $created_at,
    actor: $actor,
    source: $source,
    source_sha256: $source_sha256,
    encrypted_backup: $encrypted_backup,
    encrypted_sha256: $encrypted_sha256,
    record_count: $record_count,
    minimum_retention_days: 365,
    deletion_policy: "no-automatic-deletion"
  }' >"${manifest_plain}"
chmod 0600 "${manifest_plain}"
age --recipient "${age_recipient}" \
  --output "${manifest_file}" "${manifest_plain}"
chmod 0600 "${manifest_file}"

echo "Evidencia cifrada: ${backup_file}"
echo "Manifiesto: ${manifest_file}"
