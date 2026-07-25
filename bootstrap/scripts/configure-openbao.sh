#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
policy_dir="${project_root}/bootstrap/openbao/policies"
audit_dir="${REEFOPS_OPENBAO_BOOTSTRAP_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-bootstrap}"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result="failure"
cluster_context="${REEFOPS_KUBE_CONTEXT:?Falta contexto validado}"
environment_id="${REEFOPS_ENVIRONMENT_ID:?Falta entorno validado}"
cluster_id="${REEFOPS_OPENBAO_CLUSTER_ID:?Falta cluster_id validado}"

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

finish() {
  exit_code=$?
  trap - EXIT
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg started_at "${started_at}" \
    --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg result "${result}" \
    --arg revision "$(git rev-parse HEAD)" \
    --arg cluster_context "${cluster_context}" \
    --arg environment_id "${environment_id}" \
    --arg cluster_id "${cluster_id}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "openbao-bootstrap-token",
      authorization: "openbao-root-bootstrap",
      revision: $revision,
      cluster_context: $cluster_context,
      environment_id: $environment_id,
      cluster_id: $cluster_id,
      started_at: $started_at,
      finished_at: $finished_at,
      result: $result,
      error: (if $result == "success" then null else "configuration-failed" end),
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

bao status >/dev/null

bao audit list -format=json | jq -e 'has("file/")' >/dev/null || {
  echo "Falta el audit device declarativo file/; corrige GitOps y realiza unseal." >&2
  exit 1
}

if ! bao secrets list -format=json | jq -e 'has("ci/")' >/dev/null; then
  bao secrets enable -path=ci kv-v2
fi

if ! bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  bao auth enable kubernetes
fi

bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443 >/dev/null

bao policy write reefops-backup "${policy_dir}/backup.hcl" >/dev/null
bao policy write reefops-smoke-test "${policy_dir}/smoke-test.hcl" >/dev/null
bao policy write reefops-external-secrets \
  "${policy_dir}/external-secrets.hcl" >/dev/null

bao write auth/kubernetes/role/reefops-backup \
  bound_service_account_names=openbao-backup \
  bound_service_account_namespaces=reefops-system \
  policies=reefops-backup \
  token_ttl=15m \
  token_max_ttl=30m >/dev/null

bao write auth/kubernetes/role/reefops-smoke-test \
  bound_service_account_names=openbao-smoke-test \
  bound_service_account_namespaces=reefops-system \
  policies=reefops-smoke-test \
  token_ttl=5m \
  token_max_ttl=5m >/dev/null

bao write auth/kubernetes/role/reefops-external-secrets \
  bound_service_account_names=external-secrets-openbao \
  bound_service_account_namespaces=reefops-secret-delivery \
  policies=reefops-external-secrets \
  token_ttl=5m \
  token_max_ttl=10m >/dev/null

bao kv put ci/healthcheck status=ready >/dev/null
bao kv put ci/eso-smoke-test status=ready >/dev/null

result="success"
echo "OpenBao configurado con auditoría, KV CI, políticas, Kubernetes y ESO."
