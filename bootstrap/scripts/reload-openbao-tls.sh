#!/usr/bin/env bash
set -euo pipefail

cluster_context="${REEFOPS_CLUSTER_CONTEXT:-docker-desktop}"
endpoint="${REEFOPS_OPENBAO_LOCAL_ENDPOINT:-127.0.0.1:8200}"
ca_file="${BAO_CACERT:?Define BAO_CACERT con la CA pública}"
audit_dir="${REEFOPS_OPENBAO_TLS_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/openbao-tls}"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
desired_serial="$(
  kubectl --context "${cluster_context}" -n reefops-secrets \
    get secret openbao-tls -o jsonpath='{.data.tls\.crt}' |
    base64 --decode |
    openssl x509 -noout -serial
)"

served_serial() {
  openssl s_client \
    -connect "${endpoint}" \
    -servername openbao.reefops-secrets.svc \
    -CAfile "${ca_file}" </dev/null 2>/dev/null |
    openssl x509 -noout -serial
}

before_serial="$(served_serial)"
result="failure"
install -d -m 0700 "${audit_dir}"
touch "${audit_dir}/operations.jsonl"
chmod 0600 "${audit_dir}/operations.jsonl"

# shellcheck disable=SC2329
finish() {
  exit_code=$?
  trap - EXIT
  jq -cn \
    --arg operation_id "${operation_id}" \
    --arg actor "$(id -un)" \
    --arg before "${before_serial}" \
    --arg desired "${desired_serial}" \
    --arg result "${result}" \
    '{
      operation_id: $operation_id,
      actor: $actor,
      authorization: "kubernetes-exec-openbao-sighup",
      before_serial: $before,
      desired_serial: $desired,
      result: $result,
      error: (if $result == "success" then null else "tls-reload-failed" end)
    }' >>"${audit_dir}/operations.jsonl"
  exit "${exit_code}"
}
trap finish EXIT

if [[ "${before_serial}" != "${desired_serial}" ]]; then
  # Expansion is intentionally performed by the shell inside the container.
  # shellcheck disable=SC2016
  kubectl --context "${cluster_context}" -n reefops-secrets \
    exec openbao-0 -c openbao -- /bin/sh -c 'kill -HUP "$(pidof bao)"'
fi

for _ in {1..10}; do
  if [[ "$(served_serial)" == "${desired_serial}" ]]; then
    result="success"
    echo "OpenBao sirve el certificado ${desired_serial}."
    exit 0
  fi
  sleep 1
done

echo "OpenBao no recargó el certificado esperado." >&2
exit 1
