#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
export XDG_STATE_HOME="${test_root}/state"
state_dir="${XDG_STATE_HOME}/reefops/openbao-recovery-drill"
evidence_dir="${test_root}/external"
mkdir -p "${state_dir}" "${evidence_dir}"

drill_id="11111111-1111-4111-8111-111111111111"
correlation_id="22222222-2222-4222-8222-222222222222"
restore_id="33333333-3333-4333-8333-333333333333"
verification_id="44444444-4444-4444-8444-444444444444"
audit_file="${evidence_dir}/audit.age"
manifest_plain="${test_root}/manifest.json"
manifest_file="${evidence_dir}/manifest.age"
identity_file="${test_root}/identity.agekey"
age-keygen -o "${identity_file}" >/dev/null 2>&1
recipient="$(age-keygen -y "${identity_file}")"
printf 'encrypted-audit' >"${audit_file}"
audit_sha256="$(shasum -a 256 "${audit_file}" | awk '{print $1}')"

restore_record="$(
  jq -cn \
    --arg operation_id "${restore_id}" \
    --arg correlation_id "${correlation_id}" \
    '{
      operation_id: $operation_id,
      correlation_id: $correlation_id,
      target_scope: "isolated-recovery",
      result: "restore-applied-awaiting-verification",
      backup_created_at: "20260725T021643Z"
    }'
)"
verification_record="$(
  jq -cn \
    --arg operation_id "${verification_id}" \
    --arg correlation_id "${correlation_id}" \
    --arg restore_id "${restore_id}" \
    '{
      operation_id: $operation_id,
      actor: "test",
      authentication: "restored-openbao-identity",
      authorization: "openbao-recovery-verification-policy",
      result: "success",
      target_scope: "isolated-recovery",
      target_cluster_id: "cluster",
      active_cluster_id: "cluster",
      gitops_revision: "sha1:test",
      raft_leader_id: "leader",
      raft_last_index: "1151",
      restore_operation_id: $restore_id,
      started_at: "2026-07-25T07:00:40Z",
      finished_at: "2026-07-25T07:00:48Z",
      correlation_id: $correlation_id,
      causation_id: $restore_id
    }'
)"
restore_sha256="$(printf '%s' "${restore_record}" | shasum -a 256 | awk '{print $1}')"
verification_sha256="$(
  printf '%s' "${verification_record}" | shasum -a 256 | awk '{print $1}'
)"
jq -n \
  --arg drill_id "${drill_id}" \
  --arg correlation_id "${correlation_id}" \
  --arg audit_sha256 "${audit_sha256}" \
  --arg restore_sha256 "${restore_sha256}" \
  --arg verification_sha256 "${verification_sha256}" \
  --argjson restore_record "${restore_record}" \
  --argjson verification_record "${verification_record}" \
  '{
    schema_version: "1",
    drill_id: $drill_id,
    correlation_id: $correlation_id,
    drill_started_at: "2026-07-25T06:48:26Z",
    kubernetes_cluster_uid: "kubernetes-cluster",
    gitops_revision: "sha1:test",
    audit_sha256: $audit_sha256,
    restore_sha256: $restore_sha256,
    verification_sha256: $verification_sha256,
    restore_record: $restore_record,
    verification_record: $verification_record,
    pvc_inventory: [{name:"data",uid:"pvc-1"},{name:"audit",uid:"pvc-2"}],
    pv_inventory: [
      {name:"pv-1",uid:"pv-uid-1",reclaim_policy:"Delete",volume_handle:"one"},
      {name:"pv-2",uid:"pv-uid-2",reclaim_policy:"Delete",volume_handle:"two"}
    ]
  }' >"${manifest_plain}"
age --recipient "${recipient}" --output "${manifest_file}" "${manifest_plain}"
manifest_sha256="$(shasum -a 256 "${manifest_file}" | awk '{print $1}')"

jq -n \
  --arg drill_id "${drill_id}" \
  --arg correlation_id "${correlation_id}" \
  --arg restore_id "${restore_id}" \
  --arg verification_id "${verification_id}" \
  --arg audit_file "${audit_file}" \
  --arg audit_sha256 "${audit_sha256}" \
  --arg manifest_file "${manifest_file}" \
  --arg manifest_sha256 "${manifest_sha256}" \
  '{
    schema_version: "1",
    drill_id: $drill_id,
    correlation_id: $correlation_id,
    phase: "evidence-sealed",
    restore_operation_id: $restore_id,
    verification_operation_id: $verification_id,
    started_at: "2026-07-25T06:48:26Z",
    backup_created_at: "20260725T021643Z",
    verified_at: "2026-07-25T07:00:48Z",
    kubernetes_cluster_uid: "kubernetes-cluster",
    gitops_revision: "sha1:test",
    encrypted_audit_file: $audit_file,
    encrypted_audit_sha256: $audit_sha256,
    encrypted_evidence_manifest: $manifest_file,
    encrypted_evidence_manifest_sha256: $manifest_sha256,
    pvc_inventory: [{name:"data",uid:"pvc-1"},{name:"audit",uid:"pvc-2"}],
    pv_inventory: [
      {name:"pv-1",uid:"pv-uid-1",reclaim_policy:"Delete",volume_handle:"one"},
      {name:"pv-2",uid:"pv-uid-2",reclaim_policy:"Delete",volume_handle:"two"}
    ]
  }' >"${state_dir}/current.json"
chmod 0600 "${state_dir}/current.json"

REEFOPS_OPENBAO_RESTORE_IDENTITY="${identity_file}" \
  "${project_root}/bootstrap/scripts/close-openbao-recovery-drill.sh" >/dev/null

attempt_file="${state_dir}/attempts/${drill_id}.json"
test ! -e "${state_dir}/current.json"
jq -e '.phase == "closed-success-eligible-for-cleanup"' "${attempt_file}" >/dev/null
jq -e \
  --arg drill_id "${drill_id}" \
  'select(.drill_id == $drill_id and .rpo_seconds == 16303 and .rto_seconds == 742)' \
  "${state_dir}/evidence/operations.jsonl" >/dev/null

if REEFOPS_OPENBAO_RESTORE_IDENTITY="${identity_file}" \
  "${project_root}/bootstrap/scripts/close-openbao-recovery-drill.sh" >/dev/null 2>&1; then
  echo "El cierre repetido debía fallar." >&2
  exit 1
fi

echo "Cierre OpenBao probado."
