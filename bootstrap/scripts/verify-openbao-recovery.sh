#!/usr/bin/env bash
set -euo pipefail

verify_path="${REEFOPS_OPENBAO_VERIFY_PATH:?Define una ruta KV sintética}"
audit_dir="${REEFOPS_OPENBAO_RESTORE_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-restore}"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
result="failure"

install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

finish() {
  exit_code=$?
  trap - EXIT
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg verify_path "${verify_path}" \
    --arg result "${result}" \
    --arg correlation_id "${correlation_id}" \
    --arg causation_id "${causation_id}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authentication: "restored-openbao-identity",
      authorization: "openbao-recovery-verification-policy",
      verify_path: $verify_path,
      result: $result,
      error: (if $result == "success" then null else "recovery-verification-failed" end),
      correlation_id: $correlation_id,
      causation_id: $causation_id
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

bao status -format=json | jq -e '.initialized == true and .sealed == false' >/dev/null
bao audit list -format=json | jq -e 'has("file/")' >/dev/null
bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null
bao secrets list -format=json | jq -e 'has("ci/")' >/dev/null
bao kv metadata get -format=json "${verify_path}" >/dev/null
result="success"

echo "Recuperación OpenBao verificada con la ruta sintética ${verify_path}."
