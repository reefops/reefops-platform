#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-openbao-recovery"
service="openbao-recovery"
sni="openbao-recovery.reefops-openbao-recovery.svc"
endpoint="https://127.0.0.1:18200"
backup_digest="${REEFOPS_OPENBAO_RESTORE_SHA256:?Define REEFOPS_OPENBAO_RESTORE_SHA256}"
state_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill"
state_file="${state_dir}/current.json"
lock_dir="${state_dir}/operation.lock"
approval_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-restore/approvals"

if [[ ! -t 0 ]]; then
  echo "La aprobación exige un terminal interactivo." >&2
  exit 1
fi
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Ya existe una operación del drill en curso." >&2
  exit 1
fi
finish() {
  exit_code=$?
  trap - EXIT
  rmdir "${lock_dir}"
  exit "${exit_code}"
}
trap finish EXIT

if ! jq -e \
  --arg cluster_context "${cluster_context}" \
  '
    .schema_version == "1" and
    .phase == "temporary-target-unsealed" and
    .cluster_context == $cluster_context
  ' "${state_file}" >/dev/null; then
  echo "El estado del drill no permite aprobar el restore." >&2
  exit 1
fi

expected_gitops_revision="$(jq -er '.gitops_revision' "${state_file}")"
current_gitops_revision="$(
  kubectl --context "${cluster_context}" -n flux-system \
    get kustomization reefops-openbao-recovery \
    -o jsonpath='{.status.lastAppliedRevision}'
)"
if [[ "${current_gitops_revision}" != "${expected_gitops_revision}" ]]; then
  echo "La revisión GitOps cambió desde la inicialización." >&2
  exit 1
fi
kubernetes_cluster_uid="$(jq -er '.kubernetes_cluster_uid' "${state_file}")"
current_kubernetes_cluster_uid="$(
  kubectl --context "${cluster_context}" get namespace kube-system \
    -o jsonpath='{.metadata.uid}'
)"
if [[ "${current_kubernetes_cluster_uid}" != "${kubernetes_cluster_uid}" ]]; then
  echo "El clúster Kubernetes cambió desde la inicialización." >&2
  exit 1
fi
target_cluster_id="$(jq -er '.target_cluster_id' "${state_file}")"
runtime_target_cluster_id="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec "${service}-0" -c openbao -- \
    env BAO_TLS_SERVER_NAME="${sni}" bao status -format=json |
    jq -er '.cluster_id'
)"
if [[ "${runtime_target_cluster_id}" != "${target_cluster_id}" ]]; then
  echo "La identidad del target temporal cambió." >&2
  exit 1
fi

challenge="approve-isolated-restore-${backup_digest}"
echo "Escribe exactamente este challenge para aprobar el restore aislado:"
echo "${challenge}"
IFS= read -r response
if [[ "${response}" != "${challenge}" ]]; then
  echo "Challenge incorrecto; no se creó aprobación." >&2
  exit 1
fi
unset response

approval_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
approval_file="${approval_dir}/${approval_id}.json"
expires_at="$(date -u -v+30M '+%Y-%m-%dT%H:%M:%SZ')"
install -d -m 0700 "${approval_dir}"
jq -n \
  --arg schema_version "1" \
  --arg approval_id "${approval_id}" \
  --arg encrypted_sha256 "${backup_digest}" \
  --arg restore_mode "disaster-recovery" \
  --arg target_cluster_id "${target_cluster_id}" \
  --arg target_scope "isolated-recovery" \
  --arg cluster_context "${cluster_context}" \
  --arg kubernetes_cluster_uid "${kubernetes_cluster_uid}" \
  --arg target_namespace "${namespace}" \
  --arg target_service "${service}" \
  --arg target_endpoint "${endpoint}" \
  --arg target_sni "${sni}" \
  --arg actor "$(id -un)" \
  --arg expires_at "${expires_at}" \
  '{
    schema_version: $schema_version,
    approval_id: $approval_id,
    encrypted_sha256: $encrypted_sha256,
    restore_mode: $restore_mode,
    target_cluster_id: $target_cluster_id,
    target_scope: $target_scope,
    cluster_context: $cluster_context,
    kubernetes_cluster_uid: $kubernetes_cluster_uid,
    target_namespace: $target_namespace,
    target_service: $target_service,
    target_endpoint: $target_endpoint,
    target_sni: $target_sni,
    actor: $actor,
    expires_at: $expires_at
  }' >"${approval_file}"
chmod 0600 "${approval_file}"

jq \
  --arg approval_file "${approval_file}" \
  --arg approval_id "${approval_id}" \
  --arg backup_digest "${backup_digest}" \
  '.approval_file = $approval_file |
   .approval_id = $approval_id |
   .approved_backup_sha256 = $backup_digest |
   .phase = "restore-approved"' \
  "${state_file}" >"${state_file}.new"
chmod 0600 "${state_file}.new"
mv "${state_file}.new" "${state_file}"

echo "Restore aislado aprobado hasta ${expires_at}."
