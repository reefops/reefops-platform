#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source "${project_root}/bootstrap/scripts/lib/seaweedfs-common.sh"
audit_dir="${REEFOPS_POSTGRESQL_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/postgresql}"
evidence_file="${audit_dir}/credential-operations.jsonl"
evidence_lock="${evidence_file}.lock"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
result="failure"
disposition="unchanged"
cluster_context="${REEFOPS_KUBE_CONTEXT:?Falta contexto validado}"
environment_id="${REEFOPS_ENVIRONMENT_ID:?Falta entorno validado}"
cluster_id="${REEFOPS_OPENBAO_CLUSTER_ID:?Falta cluster_id validado}"
secret_path="platform/postgresql/barman-s3"
access_key=""
secret_key=""
temp_dir="$(mktemp -d)"
metadata_file="${temp_dir}/metadata.json"
metadata_error="${temp_dir}/metadata.error"
secret_file="${temp_dir}/secret.json"
lock_acquired="false"

install -d -m 0700 "${audit_dir}"
touch "${evidence_file}"
chmod 0600 "${evidence_file}"

finish() {
  exit_code=$?
  trap - EXIT
  access_key=""
  secret_key=""
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
      --arg cluster_id "${cluster_id}" \
      --arg secret_path "${secret_path}" \
      --arg correlation_id "${correlation_id}" \
      --arg causation_id "${causation_id}" \
      --arg previous_record_sha256 "${previous_hash}" \
      '{
        operation_id: $operation_id,
        operation: "postgresql-backup-credentials-bootstrap",
        actor: $actor,
        authentication: "openbao-bootstrap-token",
        authorization: "openbao-root-bootstrap",
        revision: $revision,
        cluster_context: $cluster_context,
        environment_id: $environment_id,
        cluster_id: $cluster_id,
        secret_path: $secret_path,
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
  echo "Ya existe un bootstrap de credenciales PostgreSQL en curso." >&2
  exit 1
fi
lock_acquired="true"
if ! validate_evidence_chain "${evidence_file}"; then
  rmdir "${evidence_lock}" >/dev/null 2>&1 || true
  lock_acquired="false"
  echo "La cadena de evidencia de credenciales no es íntegra." >&2
  exit 1
fi

bao status >/dev/null
if bao kv metadata get -format=json "${secret_path}" \
  >"${metadata_file}" 2>"${metadata_error}"; then
  disposition="already-present"
  result="success"
  echo "La credencial Barman ya existe; no se ha leído, mostrado ni rotado."
  exit 0
fi
if ! grep -Eq 'Code: 404|No value found' "${metadata_error}"; then
  echo "No se pudo determinar de forma segura si la credencial existe." >&2
  exit 1
fi

access_key="$(openssl rand -hex 10 | tr '[:lower:]' '[:upper:]')"
secret_key="$(openssl rand -hex 32)"
printf '{"access_key":"%s","secret_key":"%s"}\n' \
  "${access_key}" "${secret_key}" >"${secret_file}"
chmod 0600 "${secret_file}"

if ! bao kv put -cas=0 "${secret_path}" "@${secret_file}" >/dev/null 2>&1; then
  if bao kv metadata get -format=json "${secret_path}" \
    >"${metadata_file}" 2>"${metadata_error}"; then
    disposition="created-concurrently"
    result="success"
    echo "Otra operación creó la credencial Barman; no se ha rotado."
    exit 0
  fi
  echo "La creación atómica de la credencial Barman ha fallado." >&2
  exit 1
fi

if ! bao kv metadata get -format=json "${secret_path}" |
  jq -e '.data.current_version == 1 and .data.versions["1"].deletion_time == ""' \
    >/dev/null; then
  echo "No se pudo verificar la primera versión de la credencial Barman." >&2
  exit 1
fi

disposition="created"
result="success"
echo "Credencial Barman creada una sola vez y custodiada en OpenBao."
