#!/usr/bin/env bash
set -euo pipefail

state_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill"
state_file="${state_dir}/current.json"
attempts_dir="${state_dir}/attempts"
evidence_file="${state_dir}/evidence/operations.jsonl"
age_identity="${REEFOPS_OPENBAO_RESTORE_IDENTITY:?Define REEFOPS_OPENBAO_RESTORE_IDENTITY}"
lock_dir="${state_dir}/operation.lock"

if [[ ! -f "${state_file}" ]] ||
  ! jq -e '.schema_version == "1" and
    (.phase == "evidence-sealed" or .phase == "close-started-result-uncertain")' \
    "${state_file}" >/dev/null; then
  echo "El drill no tiene evidencia sellada pendiente de cierre." >&2
  exit 1
fi
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Ya existe una operación del drill en curso." >&2
  exit 1
fi
temp_dir="$(mktemp -d)"
manifest_plain="${temp_dir}/manifest.json"
finish() {
  exit_code=$?
  trap - EXIT
  rm -f "${manifest_plain}"
  rmdir "${temp_dir}" "${lock_dir}"
  exit "${exit_code}"
}
trap finish EXIT

drill_id="$(jq -er '.drill_id' "${state_file}")"
correlation_id="$(jq -er '.correlation_id' "${state_file}")"
restore_operation_id="$(jq -er '.restore_operation_id' "${state_file}")"
verification_id="$(jq -er '.verification_operation_id' "${state_file}")"
started_at="$(jq -er '.started_at' "${state_file}")"
backup_created_at="$(jq -er '.backup_created_at' "${state_file}")"
verified_at="$(jq -er '.verified_at' "${state_file}")"
encrypted_audit="$(jq -er '.encrypted_audit_file' "${state_file}")"
expected_audit_digest="$(jq -er '.encrypted_audit_sha256' "${state_file}")"
evidence_manifest="$(jq -er '.encrypted_evidence_manifest' "${state_file}")"
expected_manifest_digest="$(jq -er '.encrypted_evidence_manifest_sha256' "${state_file}")"
attempt_file="${attempts_dir}/${drill_id}.json"

for required_file in "${age_identity}" "${encrypted_audit}" "${evidence_manifest}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "Falta el artefacto requerido ${required_file}." >&2
    exit 1
  fi
done
if [[ -e "${attempt_file}" ]]; then
  current_closure_id="$(jq -r '.closure_operation_id // empty' "${state_file}")"
  archived_closure_id="$(jq -r '.closure_operation_id // empty' "${attempt_file}")"
  if [[ -n "${current_closure_id}" &&
    "${current_closure_id}" == "${archived_closure_id}" &&
    "$(jq -r '.phase' "${attempt_file}")" == "closed-success-eligible-for-cleanup" ]]; then
    rm "${state_file}"
    echo "Cierre ya archivado; se retiró el puntero mutable residual."
    exit 0
  fi
  echo "El drill ya tiene un cierre archivado incompatible." >&2
  exit 1
fi
if [[ "$(shasum -a 256 "${encrypted_audit}" | awk '{print $1}')" != "${expected_audit_digest}" ||
  "$(shasum -a 256 "${evidence_manifest}" | awk '{print $1}')" != "${expected_manifest_digest}" ]]; then
  echo "La evidencia cifrada cambió después de sellarse." >&2
  exit 1
fi

age --decrypt --identity "${age_identity}" \
  --output "${manifest_plain}" "${evidence_manifest}"
chmod 0600 "${manifest_plain}"
if ! jq -e \
  --arg drill_id "${drill_id}" \
  --arg correlation_id "${correlation_id}" \
  --arg restore_operation_id "${restore_operation_id}" \
  --arg verification_id "${verification_id}" \
  --arg verified_at "${verified_at}" \
  --arg audit_sha256 "${expected_audit_digest}" \
  --arg drill_started_at "${started_at}" \
  --arg kubernetes_cluster_uid "$(jq -er '.kubernetes_cluster_uid' "${state_file}")" \
  --arg gitops_revision "$(jq -er '.gitops_revision' "${state_file}")" \
  '
    .schema_version == "1" and
    .drill_id == $drill_id and
    .correlation_id == $correlation_id and
    .drill_started_at == $drill_started_at and
    .kubernetes_cluster_uid == $kubernetes_cluster_uid and
    .gitops_revision == $gitops_revision and
    .audit_sha256 == $audit_sha256 and
    .restore_record.operation_id == $restore_operation_id and
    .restore_record.correlation_id == $correlation_id and
    .restore_record.result == "restore-applied-awaiting-verification" and
    .verification_record.operation_id == $verification_id and
    .verification_record.correlation_id == $correlation_id and
    .verification_record.causation_id == $restore_operation_id and
    .verification_record.restore_operation_id == $restore_operation_id and
    .verification_record.finished_at == $verified_at and
    .verification_record.result == "success" and
    .verification_record.target_scope == "isolated-recovery" and
    .verification_record.target_cluster_id ==
      .verification_record.active_cluster_id and
    (.verification_record.gitops_revision | length > 0) and
    (.verification_record.raft_leader_id | length > 0) and
    (.verification_record.raft_last_index | length > 0)
  ' "${manifest_plain}" >/dev/null; then
  echo "El bundle cifrado no satisface el contrato de cierre." >&2
  exit 1
fi
verification="$(jq -c '.verification_record' "${manifest_plain}")"
restore="$(jq -c '.restore_record' "${manifest_plain}")"
pvc_inventory_canonical="$(jq -cS '.pvc_inventory' "${manifest_plain}")"
pv_inventory_canonical="$(jq -cS '.pv_inventory' "${manifest_plain}")"
if [[ "${pvc_inventory_canonical}" != "$(jq -cS '.pvc_inventory' "${state_file}")" ||
  "${pv_inventory_canonical}" != "$(jq -cS '.pv_inventory' "${state_file}")" ]]; then
  echo "El inventario persistente no coincide con el bundle cifrado." >&2
  exit 1
fi
pvc_inventory_sha256="$(
  printf '%s' "${pvc_inventory_canonical}" | shasum -a 256 | awk '{print $1}'
)"
pv_inventory_sha256="$(
  printf '%s' "${pv_inventory_canonical}" | shasum -a 256 | awk '{print $1}'
)"
verification_sha256="$(printf '%s' "${verification}" | shasum -a 256 | awk '{print $1}')"
restore_sha256="$(printf '%s' "${restore}" | shasum -a 256 | awk '{print $1}')"
if [[ "${verification_sha256}" != "$(jq -er '.verification_sha256' "${manifest_plain}")" ||
  "${restore_sha256}" != "$(jq -er '.restore_sha256' "${manifest_plain}")" ]]; then
  echo "Los hashes canónicos de restore o verificación no coinciden." >&2
  exit 1
fi
backup_created_at="$(jq -er '.restore_record.backup_created_at' "${manifest_plain}")"
if [[ "${backup_created_at}" != "$(jq -er '.backup_created_at' "${state_file}")" ]]; then
  echo "La fecha del snapshot no coincide con el restore sellado." >&2
  exit 1
fi

to_epoch() {
  value="$1"
  format='%Y-%m-%dT%H:%M:%SZ'
  if [[ "${value}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    format='%Y%m%dT%H%M%SZ'
  fi
  if date -j -u -f "${format}" "${value}" '+%s' >/dev/null 2>&1; then
    date -j -u -f "${format}" "${value}" '+%s'
  else
    date -u -d "${value}" '+%s'
  fi
}
backup_epoch="$(to_epoch "${backup_created_at}")"
started_epoch="$(to_epoch "${started_at}")"
verified_epoch="$(to_epoch "${verified_at}")"
rpo_seconds="$((started_epoch - backup_epoch))"
rto_seconds="$((verified_epoch - started_epoch))"
if ((rpo_seconds < 0 || rto_seconds < 0)); then
  echo "Los tiempos del drill no son coherentes." >&2
  exit 1
fi

closure_operation_id="$(jq -r '.closure_operation_id // empty' "${state_file}")"
if [[ -z "${closure_operation_id}" ]]; then
  closure_operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  jq --arg operation_id "${closure_operation_id}" \
    '.closure_operation_id = $operation_id |
     .phase = "close-started-result-uncertain"' \
    "${state_file}" >"${state_file}.new"
  chmod 0600 "${state_file}.new"
  mv "${state_file}.new" "${state_file}"
fi

install -d -m 0700 "${attempts_dir}" "$(dirname "${evidence_file}")"
touch "${evidence_file}"
chmod 0600 "${evidence_file}"
if ! jq -e --arg operation_id "${closure_operation_id}" \
  'select(.operation_id == $operation_id and .type == "recovery-drill-closure")' \
  "${evidence_file}" >/dev/null; then
  jq -cn \
    --arg operation_id "${closure_operation_id}" \
    --arg actor "$(id -un)" \
    --arg drill_id "${drill_id}" \
    --arg restore_operation_id "${restore_operation_id}" \
    --arg verification_operation_id "${verification_id}" \
    --arg verification_sha256 "${verification_sha256}" \
    --arg encrypted_audit "${encrypted_audit}" \
    --arg audit_sha256 "${expected_audit_digest}" \
    --arg evidence_manifest "${evidence_manifest}" \
    --arg evidence_manifest_sha256 "${expected_manifest_digest}" \
    --arg backup_created_at "${backup_created_at}" \
    --arg started_at "${started_at}" \
    --arg finished_at "${verified_at}" \
    --argjson rpo_seconds "${rpo_seconds}" \
    --argjson rto_seconds "${rto_seconds}" \
    --arg correlation_id "${correlation_id}" \
    --arg pvc_inventory_sha256 "${pvc_inventory_sha256}" \
    --arg pv_inventory_sha256 "${pv_inventory_sha256}" \
    '{
      operation_id: $operation_id,
      type: "recovery-drill-closure",
      drill_id: $drill_id,
      actor: $actor,
      outcome: "success",
      authentication: "local-session-and-age-identity",
      authorization: "local-recovery-drill-close",
      restore_operation_id: $restore_operation_id,
      verification_operation_id: $verification_operation_id,
      verification_sha256: $verification_sha256,
      encrypted_audit: $encrypted_audit,
      audit_sha256: $audit_sha256,
      encrypted_evidence_manifest: $evidence_manifest,
      evidence_manifest_sha256: $evidence_manifest_sha256,
      backup_created_at: $backup_created_at,
      started_at: $started_at,
      finished_at: $finished_at,
      rpo_semantics: "drill_started_at_minus_snapshot_created_at",
      rto_semantics: "verification_finished_at_minus_drill_started_at",
      rpo_seconds: $rpo_seconds,
      rto_seconds: $rto_seconds,
      pvc_inventory_sha256: $pvc_inventory_sha256,
      pv_inventory_sha256: $pv_inventory_sha256,
      correlation_id: $correlation_id,
      causation_id: $verification_operation_id
    }' >>"${evidence_file}"
  sync
fi

jq \
  --arg closed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg pvc_inventory_sha256 "${pvc_inventory_sha256}" \
  --arg pv_inventory_sha256 "${pv_inventory_sha256}" \
  '.phase = "closed-success-eligible-for-cleanup" |
   .closed_at = $closed_at |
   .pvc_inventory_sha256 = $pvc_inventory_sha256 |
   .pv_inventory_sha256 = $pv_inventory_sha256' \
  "${state_file}" >"${state_file}.new"
chmod 0400 "${state_file}.new"
mv "${state_file}.new" "${attempt_file}"
rm "${state_file}"

echo "Simulacro ${drill_id} cerrado: RPO=${rpo_seconds}s, RTO=${rto_seconds}s."
