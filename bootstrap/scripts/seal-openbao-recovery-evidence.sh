#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-openbao-recovery"
pod="openbao-recovery-0"
state_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill"
state_file="${state_dir}/current.json"
evidence_dir="${REEFOPS_OPENBAO_RECOVERY_EVIDENCE_DIR:?Define REEFOPS_OPENBAO_RECOVERY_EVIDENCE_DIR}"
age_recipient="${REEFOPS_OPENBAO_BACKUP_RECIPIENT:?Define REEFOPS_OPENBAO_BACKUP_RECIPIENT}"
restore_evidence="${REEFOPS_OPENBAO_RESTORE_EVIDENCE:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-restore/operations.jsonl}"
lock_dir="${state_dir}/operation.lock"

if [[ ! -f "${state_file}" ]] ||
  ! jq -e '.schema_version == "1" and
    (.phase == "verified-success" or
     .phase == "evidence-seal-started-result-uncertain")' \
    "${state_file}" >/dev/null; then
  echo "El drill no tiene una verificación satisfactoria pendiente de sellado." >&2
  exit 1
fi
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Ya existe una operación del drill en curso." >&2
  exit 1
fi
temp_dir="$(mktemp -d)"
manifest_plain="${temp_dir}/manifest.json"
audit_tmp=""
manifest_tmp=""
finish() {
  exit_code=$?
  trap - EXIT
  rm -f "${manifest_plain}" "${audit_tmp}" "${manifest_tmp}"
  rmdir "${temp_dir}"
  rmdir "${lock_dir}"
  exit "${exit_code}"
}
trap finish EXIT

drill_id="$(jq -er '.drill_id' "${state_file}")"
correlation_id="$(jq -er '.correlation_id' "${state_file}")"
verification_operation_id="$(jq -er '.verification_operation_id' "${state_file}")"
drill_started_at="$(jq -er '.started_at' "${state_file}")"
kubernetes_cluster_uid="$(jq -er '.kubernetes_cluster_uid' "${state_file}")"
gitops_revision="$(jq -er '.gitops_revision' "${state_file}")"
audit_file="${evidence_dir}/openbao-recovery-${drill_id}-audit.jsonl.age"
manifest_file="${audit_file}.manifest.json.age"
install -d -m 0700 "${evidence_dir}"
audit_tmp="${audit_file}.tmp-${drill_id}"
manifest_tmp="${manifest_file}.tmp-${drill_id}"

if [[ "$(jq -r '.phase' "${state_file}")" == "verified-success" &&
  (-e "${audit_file}" || -e "${manifest_file}") ]]; then
  echo "Existen artefactos no enlazados para este drill." >&2
  exit 1
fi
if [[ "$(jq -r '.phase' "${state_file}")" == \
  "evidence-seal-started-result-uncertain" ]]; then
  if [[ -f "${audit_file}" && -f "${manifest_file}" ]]; then
    audit_sha256="$(shasum -a 256 "${audit_file}" | awk '{print $1}')"
    manifest_sha256="$(shasum -a 256 "${manifest_file}" | awk '{print $1}')"
    jq \
      --arg audit_sha256 "${audit_sha256}" \
      --arg manifest_sha256 "${manifest_sha256}" \
      '.phase = "evidence-sealed" |
       .encrypted_audit_sha256 = $audit_sha256 |
       .encrypted_evidence_manifest_sha256 = $manifest_sha256' \
      "${state_file}" >"${state_file}.new"
    chmod 0600 "${state_file}.new"
    mv "${state_file}.new" "${state_file}"
    echo "Sellado de evidencia reanudado para el drill ${drill_id}."
    exit 0
  fi
  rm -f "${audit_file}" "${manifest_file}" "${audit_tmp}" "${manifest_tmp}"
fi

pvc_inventory="$(
  kubectl --context "${cluster_context}" -n "${namespace}" get pvc -o json |
    jq -c '[.items[] | {
      name: .metadata.name,
      uid: .metadata.uid,
      volume_name: .spec.volumeName
    }] | sort_by(.name)'
)"
pv_inventory="$(
  kubectl --context "${cluster_context}" get pv -o json |
    jq -c --arg namespace "${namespace}" '[.items[] |
      select(.spec.claimRef.namespace == $namespace) | {
        name: .metadata.name,
        uid: .metadata.uid,
        claim_uid: .spec.claimRef.uid,
        reclaim_policy: .spec.persistentVolumeReclaimPolicy,
        volume_handle: (.spec.csi.volumeHandle // "")
      }] | sort_by(.name)'
)"
if [[ "$(jq 'length' <<<"${pvc_inventory}")" -ne 2 ||
  "$(jq 'length' <<<"${pv_inventory}")" -ne 2 ]]; then
  echo "El inventario persistente del target no coincide con el esperado." >&2
  exit 1
fi
if ! jq -e \
  --argjson pvcs "${pvc_inventory}" \
  --argjson pvs "${pv_inventory}" \
  '$pvcs | all(.[]; . as $pvc |
    ($pvs | any(.[]; .name == $pvc.volume_name and .claim_uid == $pvc.uid))) and
   ($pvs | all(.[]; . as $pv |
    ($pvcs | any(.[]; .volume_name == $pv.name and .uid == $pv.claim_uid))))' \
  >/dev/null <<<"null"; then
  echo "El inventario PVC/PV no es una relación uno-a-uno." >&2
  exit 1
fi

restore_operation_id="$(jq -er '.restore_operation_id' "${state_file}")"
restore_record="$(
  jq -ce \
    --arg operation_id "${restore_operation_id}" \
    --arg correlation_id "${correlation_id}" \
    'select(
      .operation_id == $operation_id and
      .correlation_id == $correlation_id and
      .target_scope == "isolated-recovery" and
      .result == "restore-applied-awaiting-verification"
    )' "${restore_evidence}" |
    tail -n 1
)"
verification_record="$(
  jq -ce \
    --arg operation_id "${verification_operation_id}" \
    --arg restore_operation_id "${restore_operation_id}" \
    --arg correlation_id "${correlation_id}" \
    'select(
      .operation_id == $operation_id and
      .restore_operation_id == $restore_operation_id and
      .causation_id == $restore_operation_id and
      .correlation_id == $correlation_id and
      .result == "success"
    )' "${restore_evidence}" |
    tail -n 1
)"
if [[ -z "${restore_record}" || -z "${verification_record}" ]]; then
  echo "No se pueden enlazar restore y verificación para el bundle." >&2
  exit 1
fi
restore_sha256="$(printf '%s' "${restore_record}" | shasum -a 256 | awk '{print $1}')"
verification_sha256="$(printf '%s' "${verification_record}" | shasum -a 256 | awk '{print $1}')"

jq \
  --arg audit_file "${audit_file}" \
  --arg manifest_file "${manifest_file}" \
  --arg recipient "${age_recipient}" \
  --argjson pvc_inventory "${pvc_inventory}" \
  --argjson pv_inventory "${pv_inventory}" \
  '.phase = "evidence-seal-started-result-uncertain" |
   .encrypted_audit_file = $audit_file |
   .encrypted_evidence_manifest = $manifest_file |
   .evidence_recipient = $recipient |
   .pvc_inventory = $pvc_inventory |
   .pv_inventory = $pv_inventory' \
  "${state_file}" >"${state_file}.new"
chmod 0600 "${state_file}.new"
mv "${state_file}.new" "${state_file}"

kubectl --context "${cluster_context}" -n "${namespace}" \
  exec "${pod}" -c openbao -- cat /openbao/audit/audit.log |
  age --recipient "${age_recipient}" --output "${audit_tmp}"
chmod 0600 "${audit_tmp}"
audit_sha256="$(shasum -a 256 "${audit_tmp}" | awk '{print $1}')"
audit_size="$(stat -f '%z' "${audit_tmp}" 2>/dev/null || stat -c '%s' "${audit_tmp}")"
sealed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

jq -n \
  --arg schema_version "1" \
  --arg drill_id "${drill_id}" \
  --arg correlation_id "${correlation_id}" \
  --arg verification_operation_id "${verification_operation_id}" \
  --arg drill_started_at "${drill_started_at}" \
  --arg kubernetes_cluster_uid "${kubernetes_cluster_uid}" \
  --arg gitops_revision "${gitops_revision}" \
  --arg audit_file "$(basename "${audit_file}")" \
  --arg audit_sha256 "${audit_sha256}" \
  --argjson audit_size "${audit_size}" \
  --arg sealed_at "${sealed_at}" \
  --arg restore_sha256 "${restore_sha256}" \
  --arg verification_sha256 "${verification_sha256}" \
  --argjson restore_record "${restore_record}" \
  --argjson verification_record "${verification_record}" \
  --argjson pvc_inventory "${pvc_inventory}" \
  --argjson pv_inventory "${pv_inventory}" \
  '{
    schema_version: $schema_version,
    drill_id: $drill_id,
    correlation_id: $correlation_id,
    verification_operation_id: $verification_operation_id,
    drill_started_at: $drill_started_at,
    kubernetes_cluster_uid: $kubernetes_cluster_uid,
    gitops_revision: $gitops_revision,
    audit_file: $audit_file,
    audit_sha256: $audit_sha256,
    audit_size: $audit_size,
    sealed_at: $sealed_at,
    restore_sha256: $restore_sha256,
    verification_sha256: $verification_sha256,
    restore_record: $restore_record,
    verification_record: $verification_record,
    pvc_inventory: $pvc_inventory,
    pv_inventory: $pv_inventory
  }' >"${manifest_plain}"
chmod 0600 "${manifest_plain}"
age --recipient "${age_recipient}" --output "${manifest_tmp}" "${manifest_plain}"
chmod 0600 "${manifest_tmp}"
manifest_sha256="$(shasum -a 256 "${manifest_tmp}" | awk '{print $1}')"
mv "${audit_tmp}" "${audit_file}"
mv "${manifest_tmp}" "${manifest_file}"

jq \
  --arg audit_file "${audit_file}" \
  --arg audit_sha256 "${audit_sha256}" \
  --arg manifest_file "${manifest_file}" \
  --arg manifest_sha256 "${manifest_sha256}" \
  --arg sealed_at "${sealed_at}" \
  --argjson pvc_inventory "${pvc_inventory}" \
  --argjson pv_inventory "${pv_inventory}" \
  '.phase = "evidence-sealed" |
   .evidence_sealed_at = $sealed_at |
   .encrypted_audit_file = $audit_file |
   .encrypted_audit_sha256 = $audit_sha256 |
   .encrypted_evidence_manifest = $manifest_file |
   .encrypted_evidence_manifest_sha256 = $manifest_sha256 |
   .pvc_inventory = $pvc_inventory |
   .pv_inventory = $pv_inventory' \
  "${state_file}" >"${state_file}.new"
chmod 0600 "${state_file}.new"
mv "${state_file}.new" "${state_file}"

echo "Evidencia cifrada y sellada para el drill ${drill_id}."
