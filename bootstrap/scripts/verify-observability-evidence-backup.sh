#!/usr/bin/env bash
set -Eeuo pipefail

encrypted_backup="${REEFOPS_OBSERVABILITY_VERIFY_FILE:?Define el backup cifrado}"
encrypted_manifest="${REEFOPS_OBSERVABILITY_VERIFY_MANIFEST:?Define su manifiesto cifrado}"
age_identity="${REEFOPS_OBSERVABILITY_VERIFY_IDENTITY:?Define la identidad age}"
temp_dir="$(mktemp -d)"
evidence_plain="${temp_dir}/operations.jsonl"
manifest_plain="${temp_dir}/manifest.json"

cleanup() {
  rm -f "${evidence_plain}" "${manifest_plain}"
  rmdir "${temp_dir}"
}
trap cleanup EXIT

for required_file in \
  "${encrypted_backup}" \
  "${encrypted_manifest}" \
  "${age_identity}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "Falta un artefacto requerido para verificar el backup." >&2
    exit 2
  fi
done

age --decrypt --identity "${age_identity}" \
  --output "${evidence_plain}" "${encrypted_backup}"
age --decrypt --identity "${age_identity}" \
  --output "${manifest_plain}" "${encrypted_manifest}"

expected_encrypted_sha256="$(jq -er '.encrypted_sha256' "${manifest_plain}")"
actual_encrypted_sha256="$(
  shasum -a 256 "${encrypted_backup}" | awk '{print $1}'
)"
expected_source_sha256="$(jq -er '.source_sha256' "${manifest_plain}")"
actual_source_sha256="$(
  shasum -a 256 "${evidence_plain}" | awk '{print $1}'
)"
if [[ "${expected_encrypted_sha256}" != "${actual_encrypted_sha256}" ||
  "${expected_source_sha256}" != "${actual_source_sha256}" ]]; then
  echo "El backup no coincide con su manifiesto." >&2
  exit 3
fi

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
    echo "La cadena restaurada no es íntegra." >&2
    exit 4
  fi
  expected_previous="${recorded_hash}"
  record_count="$((record_count + 1))"
done <"${evidence_plain}"

if [[ "${record_count}" -ne "$(jq -er '.record_count' "${manifest_plain}")" ||
  "$(jq -er '.minimum_retention_days' "${manifest_plain}")" -lt 365 ]]; then
  echo "El manifiesto no conserva el recuento o la retención acordada." >&2
  exit 4
fi

echo "Backup cifrado de evidencia verificado: ${record_count} registros."
