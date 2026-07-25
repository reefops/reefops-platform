#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-openbao-recovery"
state_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill"
drill_id="${REEFOPS_OPENBAO_RECOVERY_DRILL_ID:?Define REEFOPS_OPENBAO_RECOVERY_DRILL_ID}"
attempt_file="${state_dir}/attempts/${drill_id}.json"
cleanup_dir="${state_dir}/cleanup"
cleanup_file="${cleanup_dir}/${drill_id}.json"
operations_file="${state_dir}/evidence/operations.jsonl"
cleanup_lock="${cleanup_file}.lock"

if [[ ! -f "${attempt_file}" ]] ||
  ! jq -e \
    --arg drill_id "${drill_id}" \
    '.drill_id == $drill_id and
     .phase == "closed-success-eligible-for-cleanup" and
     (.pvc_inventory | length == 2) and
     (.pv_inventory | length == 2)' "${attempt_file}" >/dev/null; then
  echo "No existe un cierre elegible con inventario persistente para este drill." >&2
  exit 1
fi
pvc_inventory_sha256="$(
  jq -cS '.pvc_inventory' "${attempt_file}" | shasum -a 256 | awk '{print $1}'
)"
pv_inventory_sha256="$(
  jq -cS '.pv_inventory' "${attempt_file}" | shasum -a 256 | awk '{print $1}'
)"
if [[ "${pvc_inventory_sha256}" != "$(jq -er '.pvc_inventory_sha256' "${attempt_file}")" ||
  "${pv_inventory_sha256}" != "$(jq -er '.pv_inventory_sha256' "${attempt_file}")" ]]; then
  echo "El inventario persistente archivado no conserva su integridad." >&2
  exit 1
fi
if [[ "$(kubectl config current-context)" != "${cluster_context}" ||
  "$(kubectl --context "${cluster_context}" get namespace kube-system -o jsonpath='{.metadata.uid}')" !=
    "$(jq -er '.kubernetes_cluster_uid' "${attempt_file}")" ]]; then
  echo "El contexto o UID Kubernetes no coincide con el drill archivado." >&2
  exit 1
fi
if [[ -e "${cleanup_file}" ]]; then
  if jq -e --arg drill_id "${drill_id}" \
    '.drill_id == $drill_id and .phase == "cleanup-verified-closed-complete"' \
    "${cleanup_file}" >/dev/null; then
    install -d -m 0700 "$(dirname "${operations_file}")"
    touch "${operations_file}"
    chmod 0600 "${operations_file}"
    cleanup_operation_id="$(jq -er '.operation_id' "${cleanup_file}")"
    if ! jq -e --arg operation_id "${cleanup_operation_id}" \
      'select(.operation_id == $operation_id)' "${operations_file}" >/dev/null; then
      jq -c . "${cleanup_file}" >>"${operations_file}"
      sync
    fi
    echo "Limpieza del ensayo OpenBao ya verificada."
    exit 0
  fi
  echo "Existe una evidencia de cleanup incompatible." >&2
  exit 1
fi
install -d -m 0700 "${cleanup_dir}" "$(dirname "${operations_file}")"
if ! mkdir "${cleanup_lock}" 2>/dev/null; then
  echo "Ya existe una verificación de cleanup en curso." >&2
  exit 1
fi
finish() {
  exit_code=$?
  trap - EXIT
  rmdir "${cleanup_lock}"
  exit "${exit_code}"
}
trap finish EXIT

if kubectl --context "${cluster_context}" get namespace "${namespace}" >/dev/null 2>&1; then
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get helmrelease,statefulset,pod,persistentvolumeclaim 2>/dev/null || true
  echo "La limpieza del ensayo no está completa: ${namespace} todavía existe." >&2
  exit 1
fi

while IFS= read -r pvc_uid; do
  if kubectl --context "${cluster_context}" get pvc -A -o json |
    jq -e --arg uid "${pvc_uid}" '.items[] | select(.metadata.uid == $uid)' >/dev/null; then
    echo "Todavía existe el PVC ${pvc_uid} del ensayo." >&2
    exit 1
  fi
done < <(jq -r '.pvc_inventory[].uid' "${attempt_file}")

while IFS=$'\t' read -r pv_name pv_uid reclaim_policy volume_handle; do
  if [[ "${reclaim_policy}" != "Delete" ]]; then
    echo "El PV ${pv_name} exige tratamiento separado por política ${reclaim_policy}." >&2
    exit 1
  fi
  if kubectl --context "${cluster_context}" get pv -o json |
    jq -e --arg uid "${pv_uid}" '.items[] | select(.metadata.uid == $uid)' >/dev/null; then
    echo "Todavía existe el PV ${pv_name} (${pv_uid}) del ensayo." >&2
    exit 1
  fi
  if kubectl --context "${cluster_context}" get volumeattachment -o json |
    jq -e --arg pv_name "${pv_name}" \
      '.items[] | select(.spec.source.persistentVolumeName == $pv_name)' >/dev/null; then
    echo "Todavía existe un VolumeAttachment para ${pv_name} (${volume_handle})." >&2
    exit 1
  fi
done < <(
  jq -r '.pv_inventory[] |
    [.name, .uid, .reclaim_policy, .volume_handle] | @tsv' "${attempt_file}"
)

operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="$(jq -er '.correlation_id' "${attempt_file}")"
closure_operation_id="$(jq -er '.closure_operation_id' "${attempt_file}")"
gitops_revision="$(
  kubectl --context "${cluster_context}" -n flux-system \
    get kustomization reefops -o jsonpath='{.status.lastAppliedRevision}'
)"
verified_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq -n \
  --arg operation_id "${operation_id}" \
  --arg actor "$(id -un)" \
  --arg drill_id "${drill_id}" \
  --arg correlation_id "${correlation_id}" \
  --arg closure_operation_id "${closure_operation_id}" \
  --arg gitops_revision "${gitops_revision}" \
  --arg verified_at "${verified_at}" \
  '{
    schema_version: "1",
    operation_id: $operation_id,
    actor: $actor,
    drill_id: $drill_id,
    phase: "cleanup-verified-closed-complete",
    outcome: "success",
    authentication: "local-kubernetes-context",
    authorization: "gitops-prune-and-local-cleanup-verification",
    gitops_revision: $gitops_revision,
    verified_at: $verified_at,
    correlation_id: $correlation_id,
    causation_id: $closure_operation_id
  }' >"${cleanup_file}.new"
chmod 0400 "${cleanup_file}.new"
mv "${cleanup_file}.new" "${cleanup_file}"
touch "${operations_file}"
chmod 0600 "${operations_file}"
jq -c . "${cleanup_file}" >>"${operations_file}"
sync

echo "Limpieza del ensayo OpenBao verificada."
