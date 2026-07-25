#!/usr/bin/env bash
set -euo pipefail

: "${BAO_TOKEN:?Define BAO_TOKEN mediante lectura silenciosa}"

project_root="$(git rev-parse --show-toplevel)"
cluster_context="${REEFOPS_KUBE_CONTEXT:-docker-desktop}"
expected_environment_id="${REEFOPS_ENVIRONMENT_ID:-development}"
environment_id=""
active_namespace="reefops-secrets"
namespace="reefops-secret-delivery"
store="openbao"
external_secret="openbao-smoke-test"
target_secret="openbao-smoke-test"
policy_name="reefops-external-secrets"
policy_file="${project_root}/bootstrap/openbao/policies/external-secrets.hcl"
audit_dir="${REEFOPS_ESO_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/eso-openbao}"
lock_dir="${audit_dir}/verification.lock"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
local_port="${REEFOPS_ESO_BAO_PORT:-18201}"
temp_dir="$(mktemp -d)"
previous_policy="${temp_dir}/previous-policy.hcl"
ca_file="${temp_dir}/openbao-ca.crt"
port_forward_log="${temp_dir}/port-forward.log"
port_forward_pid=""
lock_acquired="false"
state_captured="false"
state_changed="false"
restoration_result="not-required"
result="failure"
error_code="verification-failed"
cluster_id=""
flux_revision=""
store_uid=""
store_generation=""
external_secret_uid=""
external_secret_generation=""
audit_login_before=0
audit_login_after=0
audit_read_before=0
audit_read_after=0

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

normalize_policy() {
  tr -d '[:space:]' <"$1"
}

wait_for_condition() {
  resource="$1"
  name="$2"
  expected="$3"
  attempts="${4:-45}"

  for _ in $(seq 1 "${attempts}"); do
    actual="$(
      kubectl --context "${cluster_context}" -n "${namespace}" \
        get "${resource}" "${name}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || true
    )"
    if [[ "${actual}" == "${expected}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_value() {
  expected="$1"
  attempts="${2:-45}"

  for _ in $(seq 1 "${attempts}"); do
    actual="$(
      kubectl --context "${cluster_context}" -n "${namespace}" \
        get secret "${target_secret}" \
        -o jsonpath='{.data.status}' 2>/dev/null |
        base64 --decode 2>/dev/null || true
    )"
    if [[ "${actual}" == "${expected}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

audit_count() {
  path="$1"
  operation="$2"
  kubectl --context "${cluster_context}" -n "${active_namespace}" \
    exec openbao-0 -c openbao -- \
    cat /openbao/audit/audit.log |
    jq -c --arg path "${path}" --arg operation "${operation}" '
      select(
        .type == "request" and
        .request.path == $path and
        .request.operation == $operation
      )
    ' |
    wc -l |
    tr -d ' '
}

restore_state() {
  if [[ "${state_captured}" != "true" || "${state_changed}" != "true" ]]; then
    if [[ "${restoration_result}" != "success" ]]; then
      restoration_result="not-required"
    fi
    return 0
  fi

  restoration_result="failure"
  bao policy write "${policy_name}" "${previous_policy}" >/dev/null
  restored_policy="${temp_dir}/restored-policy.hcl"
  bao policy read -format=json "${policy_name}" |
    jq -er '.rules' >"${restored_policy}"
  if [[ "$(normalize_policy "${restored_policy}")" != \
    "$(normalize_policy "${previous_policy}")" ]]; then
    return 1
  fi

  bao kv put ci/eso-smoke-test status="${previous_value}" >/dev/null
  wait_for_condition externalsecret "${external_secret}" True
  wait_for_value "${previous_value}"
  state_changed="false"
  restoration_result="success"
}

finish() {
  exit_code=$?
  trap - EXIT

  if ! restore_state; then
    exit_code=5
    result="failure"
    error_code="restoration-failed"
  fi
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  if [[ "${lock_acquired}" == "true" ]]; then
    rmdir "${lock_dir}" >/dev/null 2>&1 || true
  fi

  audit_login_delta=$((audit_login_after - audit_login_before))
  audit_read_delta=$((audit_read_after - audit_read_before))
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg local_revision "$(git rev-parse HEAD)" \
    --arg flux_revision "${flux_revision}" \
    --arg cluster_context "${cluster_context}" \
    --arg environment_id "${environment_id}" \
    --arg cluster_id "${cluster_id}" \
    --arg store_uid "${store_uid}" \
    --arg store_generation "${store_generation}" \
    --arg external_secret_uid "${external_secret_uid}" \
    --arg external_secret_generation "${external_secret_generation}" \
    --arg started_at "${started_at}" \
    --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg result "${result}" \
    --arg error_code "${error_code}" \
    --arg restoration_result "${restoration_result}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    --argjson audit_login_delta "${audit_login_delta}" \
    --argjson audit_read_delta "${audit_read_delta}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "openbao-root-bootstrap-and-kubernetes-service-account",
      authorization: "reefops-external-secrets-policy",
      environment_id: $environment_id,
      component: "external-secrets-openbao",
      cluster_context: $cluster_context,
      cluster_id: $cluster_id,
      local_revision: $local_revision,
      flux_revision: $flux_revision,
      secret_store: {
        uid: $store_uid,
        generation: $store_generation
      },
      external_secret: {
        uid: $external_secret_uid,
        generation: $external_secret_generation
      },
      audit_evidence: {
        kubernetes_login_delta: $audit_login_delta,
        synthetic_read_delta: $audit_read_delta
      },
      restoration: $restoration_result,
      started_at: $started_at,
      finished_at: $finished_at,
      result: $result,
      error: (if $result == "success" then null else $error_code end),
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"

  rm -rf "${temp_dir}"
  exit "${exit_code}"
}
trap finish EXIT

if ! mkdir "${lock_dir}" 2>/dev/null; then
  error_code="verification-already-running"
  exit 1
fi
lock_acquired="true"

if [[ "$(kubectl config current-context)" != "${cluster_context}" ]]; then
  error_code="unexpected-kubernetes-context"
  exit 1
fi
environment_id="$(
  kubectl --context "${cluster_context}" get namespace "${namespace}" \
    -o jsonpath='{.metadata.labels.reefops\.io/environment}'
)"
if [[ "${environment_id}" != "${expected_environment_id}" ]]; then
  error_code="unexpected-environment"
  exit 1
fi

kubectl --context "${cluster_context}" -n "${active_namespace}" \
  get secret openbao-ca -o jsonpath='{.data.ca\.crt}' |
  base64 --decode >"${ca_file}"
chmod 0600 "${ca_file}"

active_ca_fingerprint="$(
  openssl x509 -in "${ca_file}" -noout -fingerprint -sha256
)"
delivery_ca_fingerprint="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get configmap openbao-ca-bundle -o jsonpath='{.data.ca\.crt}' |
    openssl x509 -noout -fingerprint -sha256
)"
if [[ "${active_ca_fingerprint}" != "${delivery_ca_fingerprint}" ]]; then
  error_code="openbao-ca-mismatch"
  exit 1
fi

kubectl --context "${cluster_context}" -n "${active_namespace}" \
  port-forward service/openbao "${local_port}:8200" \
  >"${port_forward_log}" 2>&1 &
port_forward_pid=$!

export BAO_ADDR="https://127.0.0.1:${local_port}"
export BAO_CACERT="${ca_file}"
export BAO_TLS_SERVER_NAME="openbao.reefops-secrets.svc"

for _ in $(seq 1 30); do
  if bao status -format=json >"${temp_dir}/status.json" 2>/dev/null; then
    break
  fi
  sleep 1
done

cluster_id="$(
  jq -er 'select(.initialized == true and .sealed == false) | .cluster_id' \
    "${temp_dir}/status.json"
)"
in_pod_cluster_id="$(
  kubectl --context "${cluster_context}" -n "${active_namespace}" \
    exec openbao-0 -c openbao -- \
    env BAO_TLS_SERVER_NAME=openbao.reefops-secrets.svc \
    bao status -format=json |
    jq -er 'select(.initialized == true and .sealed == false) | .cluster_id'
)"
if [[ "${cluster_id}" != "${in_pod_cluster_id}" ]]; then
  error_code="openbao-cluster-mismatch"
  exit 1
fi

bao audit list -format=json | jq -e 'has("file/")' >/dev/null
bao token lookup -format=json |
  jq -e '.data.policies | index("root") != null' >/dev/null

flux_revision="$(
  kubectl --context "${cluster_context}" -n flux-system \
    get kustomization reefops-external-secrets-openbao \
    -o jsonpath='{.status.lastAppliedRevision}'
)"
kubectl --context "${cluster_context}" -n "${namespace}" \
  rollout status deployment/external-secrets --timeout=120s >/dev/null
wait_for_condition secretstore "${store}" True
wait_for_condition externalsecret "${external_secret}" True

store_uid="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get secretstore "${store}" -o jsonpath='{.metadata.uid}'
)"
store_generation="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get secretstore "${store}" -o jsonpath='{.metadata.generation}'
)"
external_secret_uid="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get externalsecret "${external_secret}" -o jsonpath='{.metadata.uid}'
)"
external_secret_generation="$(
  kubectl --context "${cluster_context}" -n "${namespace}" \
    get externalsecret "${external_secret}" -o jsonpath='{.metadata.generation}'
)"

bao policy read -format=json "${policy_name}" |
  jq -er '.rules' >"${previous_policy}"
if [[ "$(normalize_policy "${previous_policy}")" != \
  "$(normalize_policy "${policy_file}")" ]]; then
  error_code="openbao-policy-drift"
  exit 1
fi
previous_value="$(bao kv get -field=status ci/eso-smoke-test)"
state_captured="true"
wait_for_value "${previous_value}"

audit_login_before="$(audit_count auth/kubernetes/login update)"
audit_read_before="$(audit_count ci/data/eso-smoke-test read)"

probe_value="$(uuidgen | tr '[:upper:]' '[:lower:]')"
bao kv put ci/eso-smoke-test status="${probe_value}" >/dev/null
state_changed="true"
wait_for_value "${probe_value}"

deny_policy="${temp_dir}/deny-policy.hcl"
printf '%s\n' \
  'path "ci/data/eso-smoke-test" {' \
  '  capabilities = ["deny"]' \
  '}' \
  'path "ci/metadata/eso-smoke-test" {' \
  '  capabilities = ["deny"]' \
  '}' >"${deny_policy}"
chmod 0600 "${deny_policy}"
bao policy write "${policy_name}" "${deny_policy}" >/dev/null

blocked_value="$(uuidgen | tr '[:upper:]' '[:lower:]')"
bao kv put ci/eso-smoke-test status="${blocked_value}" >/dev/null
wait_for_condition externalsecret "${external_secret}" False
wait_for_value "${probe_value}" 2

audit_login_after="$(audit_count auth/kubernetes/login update)"
audit_read_after="$(audit_count ci/data/eso-smoke-test read)"
if ((audit_login_after <= audit_login_before ||
  audit_read_after <= audit_read_before)); then
  error_code="openbao-audit-evidence-missing"
  exit 1
fi

restore_state
result="success"
error_code=""
echo "ESO y OpenBao verificados con refresco, revocación, auditoría y recuperación."
