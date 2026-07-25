#!/usr/bin/env bash
set -euo pipefail

verify_path="${REEFOPS_OPENBAO_VERIFY_PATH:?Define una ruta KV sintética}"
cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
target_scope="${REEFOPS_OPENBAO_RESTORE_TARGET_SCOPE:-isolated-recovery}"
state_file="${REEFOPS_OPENBAO_RECOVERY_STATE_FILE:-}"
target_endpoint="${BAO_ADDR:?Define BAO_ADDR}"
target_sni="${BAO_TLS_SERVER_NAME:?Define BAO_TLS_SERVER_NAME}"
target_ca="${BAO_CACERT:?Define BAO_CACERT}"
audit_dir="${REEFOPS_OPENBAO_RESTORE_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-restore}"
lock_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill/operation.lock"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result="failure"
target_cluster_id=""
active_cluster_id=""
gitops_revision=""
raft_leader_id=""
raft_last_index=""
restore_operation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"

if [[ "${target_endpoint}" != "https://127.0.0.1:18200" ||
  "${target_sni}" != "openbao-recovery.reefops-openbao-recovery.svc" ||
  ! -f "${target_ca}" ]]; then
  echo "El endpoint TLS no corresponde al target aislado." >&2
  exit 1
fi
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Ya existe una operación del drill en curso." >&2
  exit 1
fi
install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

finish() {
  exit_code=$?
  trap - EXIT
  finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg verify_path "${verify_path}" \
    --arg result "${result}" \
    --arg started_at "${started_at}" \
    --arg finished_at "${finished_at}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    --arg target_scope "${target_scope}" \
    --arg target_cluster_id "${target_cluster_id}" \
    --arg active_cluster_id "${active_cluster_id}" \
    --arg gitops_revision "${gitops_revision}" \
    --arg raft_leader_id "${raft_leader_id}" \
    --arg raft_last_index "${raft_last_index}" \
    --arg restore_operation_id "${restore_operation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "restored-openbao-identity",
      authorization: "openbao-recovery-verification-policy",
      verify_path: $verify_path,
      result: $result,
      error: (if $result == "success" then null else "recovery-verification-failed" end),
      started_at: $started_at,
      finished_at: $finished_at,
      target_scope: $target_scope,
      target_cluster_id: $target_cluster_id,
      active_cluster_id: $active_cluster_id,
      gitops_revision: $gitops_revision,
      raft_leader_id: $raft_leader_id,
      raft_last_index: $raft_last_index,
      restore_operation_id: $restore_operation_id,
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"
  sync
  if [[ "${result}" == "success" && -n "${state_file}" ]]; then
    jq \
      --arg operation_id "${operation_id}" \
      --arg verified_at "${finished_at}" \
      '.phase = "verified-success" |
       .verification_operation_id = $operation_id |
       .verified_at = $verified_at' \
      "${state_file}" >"${state_file}.new"
    chmod 0600 "${state_file}.new"
    mv "${state_file}.new" "${state_file}"
  fi
  rmdir "${lock_dir}"
  exit "${exit_code}"
}
trap finish EXIT

if [[ "${target_scope}" != "isolated-recovery" ]]; then
  echo "Esta verificación automatizada solo acepta el target aislado." >&2
  exit 1
fi
if [[ -z "${state_file}" || ! -f "${state_file}" ]] ||
  ! jq -e \
    --arg correlation_id "${correlation_id}" \
    --arg restore_operation_id "${restore_operation_id}" \
    '.phase == "snapshot-applied-awaiting-original-unseal" and
     .correlation_id == $correlation_id and
     .restore_operation_id == $restore_operation_id' \
    "${state_file}" >/dev/null; then
  echo "El estado del drill no enlaza esta verificación con el restore." >&2
  exit 1
fi
if [[ "$(kubectl config current-context)" != "${cluster_context}" ||
  "$(kubectl --context "${cluster_context}" get namespace kube-system -o jsonpath='{.metadata.uid}')" !=
    "$(jq -er '.kubernetes_cluster_uid' "${state_file}")" ]]; then
  echo "El contexto o UID Kubernetes no coincide con el drill." >&2
  exit 1
fi
expected_ca_digest="$(
  kubectl --context "${cluster_context}" -n reefops-openbao-recovery \
    get secret openbao-recovery-tls -o jsonpath='{.data.ca\.crt}' |
    base64 --decode |
    shasum -a 256 |
    awk '{print $1}'
)"
if [[ "$(shasum -a 256 "${target_ca}" | awk '{print $1}')" != "${expected_ca_digest}" ]]; then
  echo "La CA no corresponde al target aislado." >&2
  exit 1
fi
target_status="$(bao status -format=json)"
target_cluster_id="$(
  jq -er 'select(.initialized == true and .sealed == false) | .cluster_id' \
    <<<"${target_status}"
)"
in_pod_target_cluster_id="$(
  kubectl --context "${cluster_context}" -n reefops-openbao-recovery \
    exec openbao-recovery-0 -c openbao -- \
    env BAO_TLS_SERVER_NAME="${target_sni}" bao status -format=json |
    jq -er 'select(.initialized == true and .sealed == false) | .cluster_id'
)"
if [[ "${in_pod_target_cluster_id}" != "${target_cluster_id}" ]]; then
  echo "BAO_ADDR no apunta al pod aislado autorizado." >&2
  exit 1
fi
bao audit list -format=json | jq -e '
  .["file/"].type == "file" and
  .["file/"].description == "ReefOps OpenBao functional audit" and
  .["file/"].options.file_path == "/openbao/audit/audit.log" and
  .["file/"].options.mode == "0600" and
  .["file/"].options.log_raw == "false"
' >/dev/null
bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null
bao secrets list -format=json | jq -e 'has("ci/")' >/dev/null
bao kv metadata get -format=json "${verify_path}" >/dev/null
autopilot="$(bao operator raft autopilot state -format=json)"
raft_leader_id="$(jq -er 'select(.healthy == true) | .leader' <<<"${autopilot}")"
raft_last_index="$(
  jq -er --arg leader "${raft_leader_id}" \
    '.servers | to_entries[] | select(.key == $leader or .value.id == $leader) |
     .value.last_index' <<<"${autopilot}"
)"
active_status="$(
  kubectl --context "${cluster_context}" -n reefops-secrets \
    exec openbao-0 -c openbao -- \
    env BAO_ADDR=https://127.0.0.1:8200 \
      BAO_CACERT=/openbao/tls/ca.crt \
      BAO_TLS_SERVER_NAME=openbao.reefops-secrets.svc \
      bao status -format=json
)"
active_cluster_id="$(
  jq -er 'select(.initialized == true and .sealed == false) | .cluster_id' \
    <<<"${active_status}"
)"
if [[ "${active_cluster_id}" != "${target_cluster_id}" ]]; then
  echo "La identidad restaurada no coincide con la autoridad activa." >&2
  exit 1
fi
if [[ "${active_cluster_id}" != "$(jq -er '.active_cluster_id_before' "${state_file}")" ]]; then
  echo "La identidad restaurada o la salud de la autoridad activa no coincide." >&2
  exit 1
fi
gitops_revision="$(
  kubectl --context "${cluster_context}" -n flux-system \
    get kustomization reefops-openbao-recovery \
    -o jsonpath='{.status.lastAppliedRevision}'
)"
if [[ "${gitops_revision}" != "$(jq -er '.gitops_revision' "${state_file}")" ]]; then
  echo "La revisión GitOps cambió durante la verificación." >&2
  exit 1
fi
result="success"

echo "Recuperación OpenBao verificada con la ruta sintética ${verify_path}."
