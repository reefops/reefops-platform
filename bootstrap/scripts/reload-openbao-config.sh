#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
namespace="reefops-secrets"
pod="openbao-0"
container="openbao"
configmap="openbao-config"
source_config="/openbao/config/extraconfig-from-values.hcl"
runtime_config="/tmp/storageconfig.hcl"
audit_dir="${REEFOPS_OPENBAO_CONFIG_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-config}"
lock_dir="${audit_dir}/reload.lock"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result="failure"
before_hash=""
desired_hash=""
after_hash=""
reload_observed="false"
configmap_uid=""
configmap_resource_version=""
pod_uid=""
git_revision="$(git rev-parse HEAD)"

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Ya existe una recarga OpenBao en curso en este host." >&2
  exit 1
fi

finish() {
  exit_code=$?
  trap - EXIT
  rmdir "${lock_dir}"
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg before_hash "${before_hash}" \
    --arg desired_hash "${desired_hash}" \
    --arg after_hash "${after_hash}" \
    --arg reload_observed "${reload_observed}" \
    --arg cluster_context "${cluster_context}" \
    --arg configmap_uid "${configmap_uid}" \
    --arg configmap_resource_version "${configmap_resource_version}" \
    --arg pod_uid "${pod_uid}" \
    --arg git_revision "${git_revision}" \
    --arg started_at "${started_at}" \
    --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg result "${result}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "local-kubernetes-context",
      authorization: "kubernetes-exec-openbao-sighup",
      before_sha256: $before_hash,
      desired_sha256: $desired_hash,
      after_sha256: $after_hash,
      reload_observed: ($reload_observed == "true"),
      cluster_context: $cluster_context,
      configmap_uid: $configmap_uid,
      configmap_resource_version: $configmap_resource_version,
      pod_uid: $pod_uid,
      git_revision: $git_revision,
      started_at: $started_at,
      finished_at: $finished_at,
      result: $result,
      error: (if $result == "success" then null else "config-reload-failed" end),
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

exec_in_openbao() {
  kubectl --context "${cluster_context}" -n "${namespace}" \
    exec "${pod}" -c "${container}" -- "$@"
}

configmap_uid="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get configmap "${configmap}" -o jsonpath='{.metadata.uid}'
)"
configmap_resource_version="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get configmap "${configmap}" -o jsonpath='{.metadata.resourceVersion}'
)"
pod_uid="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get pod "${pod}" -o jsonpath='{.metadata.uid}'
)"
before_hash="$(exec_in_openbao sha256sum "${runtime_config}" | awk '{print $1}')"
desired_hash="$(exec_in_openbao sha256sum "${source_config}" | awk '{print $1}')"

if [[ "${before_hash}" != "${desired_hash}" ]]; then
  current_resource_version="$(
    kubectl --context "${cluster_context}" -n "${namespace}" \
      get configmap "${configmap}" -o jsonpath='{.metadata.resourceVersion}'
  )"
  if [[ "${current_resource_version}" != "${configmap_resource_version}" ]]; then
    echo "El ConfigMap cambió durante la operación; vuelve a intentarlo." >&2
    exit 1
  fi
  exec_in_openbao cp "${source_config}" "${runtime_config}.new"
  exec_in_openbao mv "${runtime_config}.new" "${runtime_config}"
fi

# Always signal: a previous attempt may have copied the file but failed before
# the process accepted it.
# Expansion is intentionally performed by the shell inside the container.
# shellcheck disable=SC2016
exec_in_openbao /bin/sh -c 'kill -HUP "$(pidof bao)"'

for _ in {1..10}; do
  if kubectl --context "${cluster_context}" -n "${namespace}" \
    logs "${pod}" -c "${container}" --since-time="${started_at}" |
    grep -Fq "OpenBao reload triggered"; then
    reload_observed="true"
    break
  fi
  sleep 1
done
if [[ "${reload_observed}" != "true" ]]; then
  echo "OpenBao no confirmó la recarga de configuración." >&2
  exit 1
fi

after_hash="$(exec_in_openbao sha256sum "${runtime_config}" | awk '{print $1}')"
if [[ "${after_hash}" != "${desired_hash}" ]]; then
  echo "La configuración activa no coincide con la reconciliada." >&2
  exit 1
fi

kubectl --context "${cluster_context}" -n "${namespace}" \
  wait --for=condition=Ready "pod/${pod}" --timeout=30s >/dev/null
final_configmap_uid="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get configmap "${configmap}" -o jsonpath='{.metadata.uid}'
)"
final_resource_version="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get configmap "${configmap}" -o jsonpath='{.metadata.resourceVersion}'
)"
final_pod_uid="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get pod "${pod}" -o jsonpath='{.metadata.uid}'
)"
final_desired_hash="$(exec_in_openbao sha256sum "${source_config}" | awk '{print $1}')"
if [[ "${final_configmap_uid}" != "${configmap_uid}" ||
  "${final_resource_version}" != "${configmap_resource_version}" ||
  "${final_pod_uid}" != "${pod_uid}" ||
  "${final_desired_hash}" != "${desired_hash}" ]]; then
  echo "La procedencia GitOps o el pod cambió durante la recarga." >&2
  exit 1
fi

exec_in_openbao test -f /openbao/audit/audit.log
result="success"

echo "Configuración OpenBao activa: ${after_hash}"
