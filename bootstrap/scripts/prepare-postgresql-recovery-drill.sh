#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
namespace="reefops-data"
cluster="reefops-postgresql"
state_dir="${REEFOPS_POSTGRESQL_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/postgresql}"
state_file="${state_dir}/recovery-drill-state.json"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
marker="reefops-${operation_id}"
restore_point="reefops_drill_${operation_id//-/_}"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

[[ "$(git -C "${project_root}" branch --show-current)" == "main" ]] &&
  [[ -z "$(git -C "${project_root}" status --porcelain)" ]] || {
  echo "La preparación PITR exige main limpio." >&2
  exit 2
}
platform_revision="$(git -C "${project_root}" rev-parse HEAD)"
deployed_revision="$(
  kubectl -n flux-system get kustomization reefops-postgresql-cluster -o json |
    jq -er '
      select(any(.status.conditions[];
        .type == "Ready" and .status == "True")) |
      .status.lastAppliedRevision | sub("^sha1:"; "")
    '
)"
[[ "${deployed_revision}" == "${platform_revision}" ]] || {
  echo "PostgreSQL no aplica la revisión local exacta." >&2
  exit 2
}
primary="$(
  kubectl -n "${namespace}" get cluster "${cluster}" -o json |
    jq -er '
      select(any(.status.conditions[];
        .type == "Ready" and .status == "True")) |
      .status.currentPrimary
    '
)"
backup_json="$(
  kubectl -n "${namespace}" get backup \
    -l "cnpg.io/cluster=${cluster}" -o json |
    jq -ec '
      [.items[] | select(.status.phase == "completed")] |
      sort_by(.status.stoppedAt) | last
    '
)"
backup_name="$(jq -r '.metadata.name' <<<"${backup_json}")"
backup_id="$(jq -r '.status.backupId' <<<"${backup_json}")"

sql_result="$(
  kubectl -n "${namespace}" exec -i "${primary}" -c postgres -- \
    psql --no-psqlrc -v ON_ERROR_STOP=1 -At <<SQL
CREATE TABLE IF NOT EXISTS public.reefops_recovery_markers (
  marker text PRIMARY KEY,
  created_at timestamptz NOT NULL
);
INSERT INTO public.reefops_recovery_markers(marker, created_at)
VALUES ('${marker}', '${created_at}');
SELECT pg_create_restore_point('${restore_point}');
SELECT pg_walfile_name(pg_switch_wal());
SQL
)"
wal_name="$(tail -n 1 <<<"${sql_result}")"
[[ "${wal_name}" =~ ^[A-F0-9]{24}$ ]] || {
  echo "No se obtuvo el WAL que contiene el restore point." >&2
  exit 3
}

archived_wal=""
for _ in $(seq 1 60); do
  archived_wal="$(
    kubectl -n "${namespace}" exec "${primary}" -c postgres -- \
      psql --no-psqlrc -Atc \
      "SELECT COALESCE(last_archived_wal, '') FROM pg_stat_archiver"
  )"
  [[ "${archived_wal}" > "${wal_name}" || "${archived_wal}" == "${wal_name}" ]] &&
    break
  sleep 5
done
[[ "${archived_wal}" > "${wal_name}" || "${archived_wal}" == "${wal_name}" ]] || {
  echo "Barman no archivó el WAL del restore point." >&2
  exit 3
}

install -d -m 0700 "${state_dir}"
base_record="$(
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg marker "${marker}" \
    --arg restore_point "${restore_point}" \
    --arg created_at "${created_at}" \
    --arg platform_revision "${platform_revision}" \
    --arg gitops_revision "$(
      kubectl -n flux-system get gitrepository flux-system -o json |
        jq -er '.status.artifact.revision | sub("^(main@)?sha1:"; "")'
    )" \
    --arg source_cluster_uid "$(
      kubectl -n "${namespace}" get cluster "${cluster}" -o jsonpath='{.metadata.uid}'
    )" \
    --arg primary_pod_uid "$(
      kubectl -n "${namespace}" get pod "${primary}" -o jsonpath='{.metadata.uid}'
    )" \
    --arg backup_name "${backup_name}" \
    --arg backup_id "${backup_id}" \
    --arg wal_name "${wal_name}" \
    --arg archived_wal "${archived_wal}" \
    '{
      schema_version: "1",
      operation_id: $operation_id,
      marker: $marker,
      restore_point: $restore_point,
      created_at: $created_at,
      platform_revision: $platform_revision,
      gitops_revision_before_promotion: $gitops_revision,
      source_cluster_uid: $source_cluster_uid,
      primary_pod_uid: $primary_pod_uid,
      backup_name: $backup_name,
      backup_id: $backup_id,
      wal_name: $wal_name,
      archived_wal: $archived_wal,
      result: "prepared"
    }'
)"
record_sha256="$(printf '%s' "${base_record}" | shasum -a 256 | awk '{print $1}')"
temp_state="${state_file}.tmp"
jq --arg record_sha256 "${record_sha256}" \
  '. + {record_sha256: $record_sha256}' <<<"${base_record}" >"${temp_state}"
chmod 0600 "${temp_state}"
mv "${temp_state}" "${state_file}"

echo "Restore point preparado y WAL archivado: ${restore_point}"
