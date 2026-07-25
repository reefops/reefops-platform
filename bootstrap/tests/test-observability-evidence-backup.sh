#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
evidence_file="${temp_dir}/operations.jsonl"
backup_dir="${temp_dir}/backup"
identity_file="${temp_dir}/identity.agekey"

age-keygen -o "${identity_file}" >/dev/null 2>&1
recipient="$(age-keygen -y "${identity_file}")"
base_record="$(
  jq -cn '{
    operation_id: "00000000-0000-0000-0000-000000000001",
    previous_record_sha256: null,
    result: "success"
  }'
)"
record_hash="$(
  printf '%s' "${base_record}" | shasum -a 256 | awk '{print $1}'
)"
jq -c --arg record_hash "${record_hash}" \
  '. + {record_sha256: $record_hash}' <<<"${base_record}" \
  >"${evidence_file}"

REEFOPS_OBSERVABILITY_EVIDENCE_FILE="${evidence_file}" \
REEFOPS_OBSERVABILITY_BACKUP_DIR="${backup_dir}" \
REEFOPS_OBSERVABILITY_BACKUP_RECIPIENT="${recipient}" \
  "${project_root}/bootstrap/scripts/backup-observability-evidence.sh" \
  >/dev/null

backup_file="$(find "${backup_dir}" -type f -name '*.jsonl.age' -print)"
manifest_file="$(find "${backup_dir}" -type f -name '*.manifest.json.age' -print)"
REEFOPS_OBSERVABILITY_VERIFY_FILE="${backup_file}" \
REEFOPS_OBSERVABILITY_VERIFY_MANIFEST="${manifest_file}" \
REEFOPS_OBSERVABILITY_VERIFY_IDENTITY="${identity_file}" \
  "${project_root}/bootstrap/scripts/verify-observability-evidence-backup.sh" \
  >/dev/null

echo "Backup cifrado de evidencia de observabilidad probado."
