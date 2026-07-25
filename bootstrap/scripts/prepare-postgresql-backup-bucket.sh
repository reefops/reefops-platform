#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source "${project_root}/bootstrap/scripts/lib/seaweedfs-common.sh"
cluster_context="${REEFOPS_KUBE_CONTEXT:-docker-desktop}"
environment_id="${REEFOPS_ENVIRONMENT_ID:-development}"
namespace="reefops-data"
bucket="reefops-postgresql-backup"
local_port="${REEFOPS_POSTGRESQL_S3_PORT:-18333}"
audit_dir="${REEFOPS_POSTGRESQL_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/postgresql}"
evidence_file="${audit_dir}/bucket-operations.jsonl"
evidence_lock="${evidence_file}.lock"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result="failure"
disposition="unchanged"
temp_dir="$(mktemp -d)"
config_file="${temp_dir}/s3-config.json"
probe_file="${temp_dir}/probe"
port_forward_log="${temp_dir}/port-forward.log"
port_forward_pid=""
lock_acquired="false"

install -d -m 0700 "${audit_dir}"
touch "${evidence_file}"
chmod 0600 "${evidence_file}"

finish() {
  exit_code=$?
  trap - EXIT
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  find "${temp_dir}" -type f -exec sh -c ': > "$1"' _ {} \;
  find "${temp_dir}" -type f -delete
  rmdir "${temp_dir}" >/dev/null 2>&1 || true
  if [[ "${lock_acquired}" != "true" ]]; then
    exit "${exit_code}"
  fi
  previous_hash=""
  if [[ -s "${evidence_file}" ]]; then
    previous_hash="$(tail -n 1 "${evidence_file}" | jq -er '.record_sha256')"
  fi
  base_record="$(
    jq -cn \
      --arg operation_id "${operation_id}" \
      --arg actor "$(id -un)" \
      --arg started_at "${started_at}" \
      --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --arg result "${result}" \
      --arg disposition "${disposition}" \
      --arg revision "$(git -C "${project_root}" rev-parse HEAD)" \
      --arg cluster_context "${cluster_context}" \
      --arg environment_id "${environment_id}" \
      --arg bucket "${bucket}" \
      --arg correlation_id "${correlation_id}" \
      --arg causation_id "${causation_id}" \
      --arg previous_record_sha256 "${previous_hash}" \
      '{
        operation_id: $operation_id,
        operation: "postgresql-backup-bucket-prepare",
        actor: $actor,
        authentication: "kubernetes-secret-and-s3-signature-v4",
        authorization: "seaweedfs-admin-bootstrap",
        revision: $revision,
        cluster_context: $cluster_context,
        environment_id: $environment_id,
        bucket: $bucket,
        disposition: $disposition,
        started_at: $started_at,
        finished_at: $finished_at,
        result: $result,
        correlation_id: $correlation_id,
        causation_id: $causation_id,
        previous_record_sha256: $previous_record_sha256
      }'
  )"
  record_hash="$(printf '%s' "${base_record}" | shasum -a 256 | awk '{print $1}')"
  jq -c --arg record_sha256 "${record_hash}" \
    '. + {record_sha256: $record_sha256}' <<<"${base_record}" >>"${evidence_file}"
  rmdir "${evidence_lock}" >/dev/null 2>&1 || exit_code=1
  exit "${exit_code}"
}
trap finish EXIT

if ! mkdir "${evidence_lock}" 2>/dev/null; then
  echo "Ya existe una preparación del bucket PostgreSQL en curso." >&2
  exit 1
fi
lock_acquired="true"
validate_evidence_chain "${evidence_file}" || {
  rmdir "${evidence_lock}" >/dev/null 2>&1 || true
  lock_acquired="false"
  echo "La cadena de evidencia del bucket no es íntegra." >&2
  exit 1
}

if [[ "$(kubectl config current-context)" != "${cluster_context}" ]] ||
  [[ "$(
    kubectl --context "${cluster_context}" get namespace "${namespace}" \
      -o jsonpath='{.metadata.labels.reefops\.io/environment}'
  )" != "${environment_id}" ]]; then
  echo "Contexto o entorno Kubernetes inesperado." >&2
  exit 1
fi

kubectl --context "${cluster_context}" -n "${namespace}" \
  get secret seaweedfs-s3-config \
  -o jsonpath='{.data.seaweedfs_s3_config}' |
  base64 --decode >"${config_file}"
chmod 0600 "${config_file}"
jq -e '
  [.identities[].name] |
  contains(["reefops-development", "reefops-barman-cloud"])
  ' "${config_file}" >/dev/null || {
    echo "La ACL S3 reconciliada aún no contiene la identidad Barman." >&2
    exit 1
  }

kubectl --context "${cluster_context}" -n "${namespace}" \
  port-forward service/reefops-seaweedfs-s3 "${local_port}:8333" \
  >"${port_forward_log}" 2>&1 &
port_forward_pid=$!
endpoint="http://127.0.0.1:${local_port}"
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error "${endpoint}/status" \
    >"${temp_dir}/status" 2>/dev/null; then
    break
  fi
  sleep 1
done

AWS_ACCESS_KEY_ID="$(
  jq -er '.identities[] | select(.name == "reefops-development") |
    .credentials[0].accessKey' "${config_file}"
)"
AWS_SECRET_ACCESS_KEY="$(
  jq -er '.identities[] | select(.name == "reefops-development") |
    .credentials[0].secretKey' "${config_file}"
)"
AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

if seaweedfs_bucket_exists "${endpoint}" "${bucket}"; then
  disposition="already-present"
else
  bucket_status=$?
  [[ "${bucket_status}" -eq 1 ]] || {
    echo "No se pudo inventariar el almacenamiento S3." >&2
    exit 1
  }
  aws --endpoint-url "${endpoint}" s3api create-bucket \
    --bucket "${bucket}" >/dev/null
  disposition="created"
fi

AWS_ACCESS_KEY_ID="$(
  jq -er '.identities[] | select(.name == "reefops-barman-cloud") |
    .credentials[0].accessKey' "${config_file}"
)"
AWS_SECRET_ACCESS_KEY="$(
  jq -er '.identities[] | select(.name == "reefops-barman-cloud") |
    .credentials[0].secretKey' "${config_file}"
)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
printf '%s\n' "${operation_id}" >"${probe_file}"
aws --endpoint-url "${endpoint}" s3api put-object \
  --bucket "${bucket}" --key ".reefops-barman-probe" \
  --body "${probe_file}" >/dev/null
aws --endpoint-url "${endpoint}" s3api head-object \
  --bucket "${bucket}" --key ".reefops-barman-probe" >/dev/null
aws --endpoint-url "${endpoint}" s3api delete-object \
  --bucket "${bucket}" --key ".reefops-barman-probe" >/dev/null

result="success"
echo "Bucket PostgreSQL preparado y acceso Barman de mínimo privilegio verificado."
