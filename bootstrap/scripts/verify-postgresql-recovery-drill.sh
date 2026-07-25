#!/usr/bin/env bash
set -euo pipefail

namespace="reefops-data"
source_cluster="reefops-postgresql"
target_cluster="reefops-postgresql-recovery-drill"
state_dir="${REEFOPS_POSTGRESQL_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/postgresql}"
state_file="${state_dir}/recovery-drill-state.json"
evidence_file="${state_dir}/recovery-operations.jsonl"

[[ -s "${state_file}" ]] || {
  echo "Falta el estado preparado del simulacro." >&2
  exit 2
}
stored_hash="$(jq -er '.record_sha256' "${state_file}")"
calculated_hash="$(
  jq -c 'del(.record_sha256)' "${state_file}" |
    tr -d '\n' | shasum -a 256 | awk '{print $1}'
)"
[[ "${stored_hash}" == "${calculated_hash}" ]] || {
  echo "El estado del simulacro no es íntegro." >&2
  exit 2
}
marker="$(jq -er '.marker' "${state_file}")"
restore_point="$(jq -er '.restore_point' "${state_file}")"
backup_id="$(jq -er '.backup_id' "${state_file}")"
target="$(
  kubectl -n "${namespace}" get cluster "${target_cluster}" -o json |
    jq -er '
      select(any(.status.conditions[];
        .type == "Ready" and .status == "True")) |
      .status.currentPrimary
    '
)"
restored_marker="$(
  kubectl -n "${namespace}" exec "${target}" -c postgres -- \
    psql --no-psqlrc -Atc \
    "SELECT marker FROM public.reefops_recovery_markers WHERE marker = '${marker}'"
)"
[[ "${restored_marker}" == "${marker}" ]] || {
  echo "El Cluster restaurado no contiene el marcador esperado." >&2
  exit 3
}
source_timeline="$(
  kubectl -n "${namespace}" exec "${source_cluster}-1" -c postgres -- \
    psql --no-psqlrc -Atc 'SELECT timeline_id FROM pg_control_checkpoint()'
)"
target_timeline="$(
  kubectl -n "${namespace}" exec "${target}" -c postgres -- \
    psql --no-psqlrc -Atc 'SELECT timeline_id FROM pg_control_checkpoint()'
)"
[[ "${target_timeline}" -gt "${source_timeline}" ]] || {
  echo "La recuperación no promovió una timeline aislada." >&2
  exit 3
}
recovery_log="$(
  kubectl -n "${namespace}" logs "${target}" -c postgres --since=30m
)"
grep -F "${restore_point}" <<<"${recovery_log}" >/dev/null || {
  echo "Los logs no acreditan el restore point solicitado." >&2
  exit 3
}
pvc_json="$(
  kubectl -n "${namespace}" get pvc \
    -l "cnpg.io/cluster=${target_cluster}" -o json |
    jq -ec '.items | select(length == 1) | .[0]'
)"
[[ "$(jq -r '.spec.storageClassName' <<<"${pvc_json}")" ==
  "reefops-hostpath-delete" ]] || {
  echo "El PVC del simulacro no es efímero." >&2
  exit 3
}
if kubectl -n "${namespace}" get svc \
  -l "cnpg.io/cluster=${target_cluster}" -o json |
  jq -e 'any(.items[]; .spec.type != "ClusterIP" or
    ((.spec.externalIPs // []) | length > 0))' >/dev/null; then
  echo "El simulacro tiene exposición norte-sur." >&2
  exit 3
fi

install -d -m 0700 "${state_dir}"
touch "${evidence_file}"
chmod 0600 "${evidence_file}"
previous_hash=""
[[ ! -s "${evidence_file}" ]] ||
  previous_hash="$(tail -n 1 "${evidence_file}" | jq -er '.record_sha256')"
record="$(
  jq -cn \
    --arg operation_id "$(jq -r '.operation_id' "${state_file}")" \
    --arg marker "${marker}" \
    --arg backup_id "${backup_id}" \
    --arg restore_point "${restore_point}" \
    --arg source_timeline "${source_timeline}" \
    --arg target_timeline "${target_timeline}" \
    --arg target_cluster_uid "$(
      kubectl -n "${namespace}" get cluster "${target_cluster}" \
        -o jsonpath='{.metadata.uid}'
    )" \
    --arg target_pvc_uid "$(jq -r '.metadata.uid' <<<"${pvc_json}")" \
    --arg target_pv "$(jq -r '.spec.volumeName' <<<"${pvc_json}")" \
    --arg platform_revision "$(
      kubectl -n flux-system get kustomization \
        reefops-postgresql-recovery-drill -o json |
        jq -er '.status.lastAppliedRevision | sub("^sha1:"; "")'
    )" \
    --arg gitops_revision "$(
      kubectl -n flux-system get gitrepository flux-system -o json |
        jq -er '.status.artifact.revision | sub("^(main@)?sha1:"; "")'
    )" \
    --arg previous_record_sha256 "${previous_hash}" \
    '{
      schema_version: "1",
      operation_id: $operation_id,
      operation: "postgresql-isolated-pitr",
      marker: $marker,
      backup_id: $backup_id,
      restore_point: $restore_point,
      source_timeline: ($source_timeline | tonumber),
      target_timeline: ($target_timeline | tonumber),
      target_cluster_uid: $target_cluster_uid,
      target_pvc_uid: $target_pvc_uid,
      target_pv: $target_pv,
      platform_revision: $platform_revision,
      gitops_revision: $gitops_revision,
      restoration: "verified",
      cleanup_status: "pending",
      result: "success",
      previous_record_sha256: $previous_record_sha256
    }'
)"
record_hash="$(printf '%s' "${record}" | shasum -a 256 | awk '{print $1}')"
jq -c --arg record_sha256 "${record_hash}" \
  '. + {record_sha256: $record_sha256}' <<<"${record}" >>"${evidence_file}"

echo "PITR aislado verificado en timeline ${target_timeline}."
