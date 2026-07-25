#!/usr/bin/env bash
set -euo pipefail

namespace="reefops-data"
target_cluster="reefops-postgresql-recovery-drill"
state_dir="${REEFOPS_POSTGRESQL_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/postgresql}"
state_file="${state_dir}/recovery-drill-state.json"
evidence_file="${state_dir}/recovery-operations.jsonl"

[[ -s "${state_file}" && -s "${evidence_file}" ]] || {
  echo "Falta el estado o la evidencia verificada del simulacro." >&2
  exit 2
}
stored_state_hash="$(jq -er '.record_sha256' "${state_file}")"
calculated_state_hash="$(
  jq -c 'del(.record_sha256)' "${state_file}" |
    tr -d '\n' | shasum -a 256 | awk '{print $1}'
)"
[[ "${stored_state_hash}" == "${calculated_state_hash}" ]] || {
  echo "El estado preparado del simulacro no es íntegro." >&2
  exit 2
}

operation_id="$(jq -er '.operation_id' "${state_file}")"
last_record="$(tail -n 1 "${evidence_file}")"
last_hash="$(jq -er '.record_sha256' <<<"${last_record}")"
calculated_last_hash="$(
  jq -c 'del(.record_sha256)' <<<"${last_record}" |
    tr -d '\n' | shasum -a 256 | awk '{print $1}'
)"
[[ "${last_hash}" == "${calculated_last_hash}" ]] || {
  echo "La última evidencia PITR no es íntegra." >&2
  exit 2
}
if jq -e --arg operation_id "${operation_id}" '
  .operation_id == $operation_id and
  .operation == "postgresql-isolated-pitr-cleanup" and
  .cleanup_status == "verified" and
  .result == "success"
' <<<"${last_record}" >/dev/null; then
  echo "Cleanup PITR ya verificado."
  exit 0
fi
jq -e --arg operation_id "${operation_id}" '
  .operation_id == $operation_id and
  .operation == "postgresql-isolated-pitr" and
  .restoration == "verified" and
  .cleanup_status == "pending" and
  .result == "success"
' <<<"${last_record}" >/dev/null || {
  echo "La cadena no termina en una restauración PITR pendiente de cleanup." >&2
  exit 2
}

target_pv="$(jq -er '.target_pv' <<<"${last_record}")"
if kubectl -n flux-system get kustomization \
  reefops-postgresql-recovery-drill >/dev/null 2>&1; then
  echo "Flux aún reconcilia el simulacro PITR." >&2
  exit 3
fi
for resource in cluster pod pvc service; do
  if kubectl -n "${namespace}" get "${resource}" \
    -l "cnpg.io/cluster=${target_cluster}" -o name | grep -q .; then
    echo "Permanece un recurso ${resource} del simulacro PITR." >&2
    exit 3
  fi
done
if kubectl get pv "${target_pv}" >/dev/null 2>&1; then
  echo "El PV efímero ${target_pv} no fue eliminado." >&2
  exit 3
fi

record="$(
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg target_pv "${target_pv}" \
    --arg closed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg gitops_revision "$(
      kubectl -n flux-system get gitrepository flux-system -o json |
        jq -er '.status.artifact.revision | sub("^(main@)?sha1:"; "")'
    )" \
    --arg previous_record_sha256 "${last_hash}" \
    '{
      schema_version: "1",
      operation_id: $operation_id,
      operation: "postgresql-isolated-pitr-cleanup",
      target_pv: $target_pv,
      closed_at: $closed_at,
      gitops_revision: $gitops_revision,
      restoration: "verified",
      cleanup_status: "verified",
      result: "success",
      previous_record_sha256: $previous_record_sha256
    }'
)"
record_hash="$(printf '%s' "${record}" | shasum -a 256 | awk '{print $1}')"
jq -c --arg record_sha256 "${record_hash}" \
  '. + {record_sha256: $record_sha256}' <<<"${record}" >>"${evidence_file}"

echo "Cleanup PITR verificado y evidencia cerrada."
