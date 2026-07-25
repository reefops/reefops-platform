#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
audit_dir="${REEFOPS_OPENBAO_BOOTSTRAP_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-bootstrap}"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result="failure"

: "${BAO_ADDR:?Define BAO_ADDR para el endpoint local con port-forward}"
: "${BAO_CACERT:?Define BAO_CACERT con la CA pública de OpenBao}"

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

finish() {
  exit_code=$?
  trap - EXIT
  unset BAO_TOKEN
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg started_at "${started_at}" \
    --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg result "${result}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "kubernetes-short-lived-token",
      authorization: "reefops-smoke-test",
      started_at: $started_at,
      finished_at: $finished_at,
      result: $result,
      error: (if $result == "success" then null else "bootstrap-verification-failed" end),
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

bao status -format=json |
  jq -e '.initialized == true and .sealed == false' >/dev/null

service_account_token="$(
  kubectl --context "${cluster_context}" \
    -n reefops-system create token openbao-smoke-test --duration=5m
)"
login_response="$(
  printf '%s' "${service_account_token}" |
    bao write -format=json auth/kubernetes/login \
      role=reefops-smoke-test jwt=-
)"
unset service_account_token
BAO_TOKEN="$(jq -er '.auth.client_token' <<<"${login_response}")"
export BAO_TOKEN
unset login_response

bao kv metadata get -format=json ci/healthcheck |
  jq -e '.data.current_version >= 1' >/dev/null

result="success"
echo "OpenBao verificado mediante identidad Kubernetes de mínimo privilegio."
