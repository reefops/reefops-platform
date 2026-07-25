#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-openbao-recovery"
pod="openbao-recovery-0"
service="openbao-recovery"
sni="openbao-recovery.reefops-openbao-recovery.svc"
state_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-recovery-drill"
state_file="${state_dir}/current.json"
init_file="/dev/shm/reefops-recovery-init.json"
backup_file="${REEFOPS_OPENBAO_RESTORE_FILE:?Define REEFOPS_OPENBAO_RESTORE_FILE}"
backup_digest="${REEFOPS_OPENBAO_RESTORE_SHA256:?Define REEFOPS_OPENBAO_RESTORE_SHA256}"
manifest_file="${REEFOPS_OPENBAO_RESTORE_MANIFEST:?Define REEFOPS_OPENBAO_RESTORE_MANIFEST}"
manifest_digest="${REEFOPS_OPENBAO_RESTORE_MANIFEST_SHA256:?Define REEFOPS_OPENBAO_RESTORE_MANIFEST_SHA256}"
age_identity="${REEFOPS_OPENBAO_RESTORE_IDENTITY:?Define REEFOPS_OPENBAO_RESTORE_IDENTITY}"
backup_dir="${REEFOPS_OPENBAO_BACKUP_DIR:?Define REEFOPS_OPENBAO_BACKUP_DIR}"
backup_recipient="${REEFOPS_OPENBAO_BACKUP_RECIPIENT:?Define REEFOPS_OPENBAO_BACKUP_RECIPIENT}"
original_material_confirmed="${REEFOPS_ORIGINAL_SEAL_MATERIAL_CONFIRMED:-}"
restore_confirmation="${REEFOPS_CONFIRM_OPENBAO_RESTORE:-}"
lock_dir="${state_dir}/operation.lock"

if [[ ! -f "${state_file}" ]]; then
  echo "No existe un drill inicializado." >&2
  exit 1
fi
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Ya existe una operación del drill en curso." >&2
  exit 1
fi
if ! jq -e \
  --arg cluster_context "${cluster_context}" \
  --arg backup_digest "${backup_digest}" \
  '
    .schema_version == "1" and
    .phase == "restore-approved" and
    .cluster_context == $cluster_context and
    .approved_backup_sha256 == $backup_digest
  ' "${state_file}" >/dev/null; then
  rmdir "${lock_dir}"
  echo "El estado del drill no autoriza este restore." >&2
  exit 1
fi
correlation_id="$(jq -er '.correlation_id' "${state_file}")"
drill_id="$(jq -er '.drill_id' "${state_file}")"
kubernetes_cluster_uid="$(jq -er '.kubernetes_cluster_uid' "${state_file}")"
approval_file="$(jq -er '.approval_file' "${state_file}")"
expected_gitops_revision="$(jq -er '.gitops_revision' "${state_file}")"
current_gitops_revision="$(
  kubectl --context "${cluster_context}" -n flux-system \
    get kustomization reefops-openbao-recovery \
    -o jsonpath='{.status.lastAppliedRevision}'
)"
current_kubernetes_cluster_uid="$(
  kubectl --context "${cluster_context}" get namespace kube-system \
    -o jsonpath='{.metadata.uid}'
)"
if [[ "${current_gitops_revision}" != "${expected_gitops_revision}" ||
  "${current_kubernetes_cluster_uid}" != "${kubernetes_cluster_uid}" ]]; then
  rmdir "${lock_dir}"
  echo "La revisión GitOps o el clúster cambiaron desde la aprobación." >&2
  exit 1
fi
if [[ "${original_material_confirmed}" != "true" ||
  "${restore_confirmation}" != "force-restore-${backup_digest}" ]]; then
  rmdir "${lock_dir}"
  echo "Faltan las confirmaciones explícitas del restore." >&2
  exit 1
fi
temp_dir="$(mktemp -d)"
ca_file="${temp_dir}/ca.crt"
port_forward_log="${temp_dir}/port-forward.log"
port_forward_pid=""

finish() {
  exit_code=$?
  trap - EXIT
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
  fi
  rm -f "${ca_file}" "${port_forward_log}"
  rmdir "${temp_dir}"
  rmdir "${lock_dir}"
  unset BAO_TOKEN
  exit "${exit_code}"
}
trap finish EXIT

kubectl --context "${cluster_context}" -n "${namespace}" \
  get secret openbao-recovery-tls -o jsonpath='{.data.ca\.crt}' |
  base64 --decode >"${ca_file}"
chmod 0600 "${ca_file}"

kubectl --context "${cluster_context}" -n "${namespace}" \
  port-forward "service/${service}" 18200:8200 >"${port_forward_log}" 2>&1 &
port_forward_pid=$!
for _ in {1..20}; do
  if BAO_ADDR=https://127.0.0.1:18200 \
    BAO_CACERT="${ca_file}" \
    BAO_TLS_SERVER_NAME="${sni}" \
    bao status >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! kill -0 "${port_forward_pid}" 2>/dev/null; then
  echo "No se pudo establecer el port-forward aislado." >&2
  exit 1
fi

BAO_TOKEN="$(
  # Expansion belongs to awk inside the container.
  # shellcheck disable=SC2016
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec "${pod}" -c openbao -- \
    awk -F'"' '/"root_token"/ {print $4}' "${init_file}"
)"
export BAO_TOKEN

BAO_ADDR=https://127.0.0.1:18200 \
BAO_CACERT="${ca_file}" \
BAO_TLS_SERVER_NAME="${sni}" \
REEFOPS_CLUSTER_CONTEXT="${cluster_context}" \
REEFOPS_CORRELATION_ID="${correlation_id}" \
REEFOPS_CAUSATION_ID="${drill_id}" \
REEFOPS_OPENBAO_RESTORE_FILE="${backup_file}" \
REEFOPS_OPENBAO_RESTORE_SHA256="${backup_digest}" \
REEFOPS_OPENBAO_RESTORE_MANIFEST="${manifest_file}" \
REEFOPS_OPENBAO_RESTORE_MANIFEST_SHA256="${manifest_digest}" \
REEFOPS_OPENBAO_RESTORE_IDENTITY="${age_identity}" \
REEFOPS_OPENBAO_RESTORE_MODE=disaster-recovery \
REEFOPS_OPENBAO_RESTORE_TARGET_SCOPE=isolated-recovery \
REEFOPS_OPENBAO_RESTORE_TARGET_NAMESPACE="${namespace}" \
REEFOPS_OPENBAO_RESTORE_TARGET_SERVICE="${service}" \
REEFOPS_OPENBAO_RESTORE_APPROVAL_FILE="${approval_file}" \
REEFOPS_OPENBAO_BACKUP_DIR="${backup_dir}" \
REEFOPS_OPENBAO_BACKUP_RECIPIENT="${backup_recipient}" \
REEFOPS_ORIGINAL_SEAL_MATERIAL_CONFIRMED="${original_material_confirmed}" \
REEFOPS_CONFIRM_OPENBAO_RESTORE="${restore_confirmation}" \
  "${project_root}/bootstrap/scripts/restore-openbao.sh"

kubectl --context "${cluster_context}" -n "${namespace}" \
  exec "${pod}" -c openbao -- rm -f "${init_file}"
jq '.phase = "snapshot-applied-awaiting-original-unseal"' \
  "${state_file}" >"${state_file}.new"
chmod 0600 "${state_file}.new"
mv "${state_file}.new" "${state_file}"

echo "Snapshot aplicado al target aislado."
echo "Introduce ahora las claves Shamir originales mediante el comando interactivo."
