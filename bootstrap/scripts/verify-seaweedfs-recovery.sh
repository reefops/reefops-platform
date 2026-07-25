#!/usr/bin/env bash
set -Eeuo pipefail

backup_dir="${REEFOPS_SEAWEEDFS_BACKUP_DIR:?Define el directorio externo de backup}"
age_recipient="${REEFOPS_SEAWEEDFS_BACKUP_RECIPIENT:?Define el recipient age}"
age_identity="${REEFOPS_SEAWEEDFS_VERIFY_IDENTITY:?Define la identidad age}"
project_root="$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source "${project_root}/bootstrap/scripts/lib/seaweedfs-common.sh"
cluster_context="${REEFOPS_KUBE_CONTEXT:-docker-desktop}"
environment_id="${REEFOPS_ENVIRONMENT_ID:-development}"
namespace="reefops-data"
local_port="${REEFOPS_SEAWEEDFS_RECOVERY_PORT:-18334}"
state_dir="${REEFOPS_SEAWEEDFS_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/seaweedfs}"
acceptance_evidence="${state_dir}/operations.jsonl"
acceptance_lock="${acceptance_evidence}.lock"
recovery_evidence="${state_dir}/recovery-operations.jsonl"
recovery_lock="${recovery_evidence}.lock"
temp_dir="$(mktemp -d)"
export_dir="${temp_dir}/export"
restore_dir="${temp_dir}/restore"
credentials_file="${temp_dir}/credentials.json"
port_forward_log="${temp_dir}/port-forward.log"
plain_archive="${temp_dir}/seaweedfs-recovery.tar.gz"
plain_manifest="${temp_dir}/manifest.json"
restored_archive="${temp_dir}/restored.tar.gz"
restored_manifest="${temp_dir}/restored-manifest.json"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
backup_file="${backup_dir}/seaweedfs-synthetic-${timestamp}-${operation_id}.tar.gz.age"
manifest_file="${backup_file}.manifest.json.age"
source_bucket="reefops-recovery-source-${operation_id}"
restore_bucket="reefops-recovery-target-${operation_id}"
object_key="synthetic/recovery.bin"
port_forward_pid=""
endpoint=""
lock_acquired="false"
acceptance_lock_acquired="false"
evidence_chains_valid="false"
result="failure"
failure_phase="preflight"
platform_revision=""
object_sha256=""
encrypted_sha256=""
cluster_resource_id=""
chart_digest=""
cleanup_status="not-run"

record_evidence() {
  previous_hash=""
  if [[ -s "${recovery_evidence}" ]]; then
    previous_hash="$(
      tail -n 1 "${recovery_evidence}" | jq -er '.record_sha256'
    )"
  fi
  base_record="$(
    jq -cn \
      --arg schema_version "1" \
      --arg operation_id "${operation_id}" \
      --arg operation "seaweedfs-isolated-logical-restore" \
      --arg actor "$(id -un)" \
      --arg authorization "local-platform-operator" \
      --arg environment_id "${environment_id}" \
      --arg cluster_context "${cluster_context}" \
      --arg platform_revision "${platform_revision}" \
      --arg object_sha256 "${object_sha256}" \
      --arg encrypted_sha256 "${encrypted_sha256}" \
      --arg cluster_resource_id "${cluster_resource_id}" \
      --arg chart_digest "${chart_digest}" \
      --arg cleanup_status "${cleanup_status}" \
      --arg backup_file "$(basename "${backup_file}")" \
      --arg manifest_file "$(basename "${manifest_file}")" \
      --arg started_at "${started_at}" \
      --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --arg result "${result}" \
      --arg failure_phase "${failure_phase}" \
      --arg correlation_id "${correlation_id}" \
      --arg causation_id "${causation_id}" \
      --arg previous_record_sha256 "${previous_hash}" \
      '{
        schema_version: $schema_version,
        operation_id: $operation_id,
        operation: $operation,
        actor: $actor,
        authentication: "kubernetes-operator-and-age-identity",
        authorization: $authorization,
        environment_id: $environment_id,
        cluster_context: $cluster_context,
        platform_revision: $platform_revision,
        payload_classification: "synthetic",
        object_sha256: $object_sha256,
        encrypted_sha256: $encrypted_sha256,
        cluster_resource_id: $cluster_resource_id,
        chart_digest: $chart_digest,
        cleanup_status: $cleanup_status,
        restoration: (if $result == "success" then "verified" else "failure" end),
        backup_file: $backup_file,
        manifest_file: $manifest_file,
        restore_target: "isolated-ephemeral-bucket",
        active_bucket_overwritten: false,
        started_at: $started_at,
        finished_at: $finished_at,
        result: $result,
        failure_phase: (if $result == "success" then null else $failure_phase end),
        correlation_id: $correlation_id,
        causation_id: $causation_id,
        previous_record_sha256: $previous_record_sha256
      }'
  )"
  record_hash="$(
    printf '%s' "${base_record}" | shasum -a 256 | awk '{print $1}'
  )"
  jq -c --arg record_sha256 "${record_hash}" \
    '. + {record_sha256: $record_sha256}' <<<"${base_record}" \
    >>"${recovery_evidence}"
}

cleanup() {
  exit_code=$?
  trap - EXIT
  set +e
  cleanup_failed="false"
  cleanup_status="success"
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${endpoint}" ]]; then
    if ! seaweedfs_cleanup_bucket \
      "${endpoint}" "${source_bucket}" "${operation_id}"; then
      cleanup_failed="true"
    fi
    if ! seaweedfs_cleanup_bucket \
      "${endpoint}" "${restore_bucket}" "${operation_id}"; then
      cleanup_failed="true"
    fi
    if [[ "${cleanup_failed}" == "true" ]]; then
      cleanup_status="failure"
      result="failure"
      failure_phase="cleanup"
    fi
  fi
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1
    wait "${port_forward_pid}" >/dev/null 2>&1
  fi
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  find "${temp_dir}" -type f -exec sh -c ': > "$1"' _ {} \;
  find "${temp_dir}" -depth -type f -delete
  find "${temp_dir}" -depth -type d -exec rmdir {} \; 2>/dev/null
  if [[ "${lock_acquired}" == "true" &&
    "${evidence_chains_valid}" == "true" ]]; then
    record_evidence || exit_code=6
  fi
  if [[ "${lock_acquired}" == "true" ]]; then
    rmdir "${recovery_lock}" >/dev/null 2>&1
  fi
  if [[ "${acceptance_lock_acquired}" == "true" ]]; then
    rmdir "${acceptance_lock}" >/dev/null 2>&1
  fi
  if [[ "${cleanup_failed}" == "true" && "${exit_code}" -eq 0 ]]; then
    exit_code=6
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

for command in kubectl jq aws curl age age-keygen tar shasum openssl; do
  command -v "${command}" >/dev/null || {
    echo "Falta la herramienta ${command}." >&2
    exit 2
  }
done
if [[ ! -f "${age_identity}" ]] ||
  [[ "$(age-keygen -y "${age_identity}")" != "${age_recipient}" ]]; then
  echo "La identidad age no corresponde al recipient de backup." >&2
  exit 2
fi
if [[ "${backup_dir}" != "/Volumes/reefops-backup/seaweedfs" &&
  "${backup_dir}" != /Volumes/reefops-backup/seaweedfs/* ]]; then
  echo "El backup debe salir de Docker Desktop hacia el volumen QNAP previsto." >&2
  exit 2
fi

install -d -m 0700 "${state_dir}" "${backup_dir}" "${export_dir}" "${restore_dir}"
if ! mkdir "${acceptance_lock}" 2>/dev/null; then
  echo "La aceptación S3 está siendo escrita; no se inicia el restore." >&2
  exit 2
fi
acceptance_lock_acquired="true"
touch "${recovery_evidence}"
chmod 0600 "${recovery_evidence}"
if ! mkdir "${recovery_lock}" 2>/dev/null; then
  echo "Ya existe una recuperación SeaweedFS en curso." >&2
  exit 2
fi
lock_acquired="true"
if ! validate_evidence_chain "${acceptance_evidence}" ||
  ! validate_evidence_chain "${recovery_evidence}"; then
  echo "Una cadena de evidencia SeaweedFS no es íntegra." >&2
  exit 2
fi
evidence_chains_valid="true"

if [[ "$(git -C "${project_root}" branch --show-current)" != "main" ]] ||
  [[ -n "$(git -C "${project_root}" status --porcelain)" ]]; then
  echo "La recuperación exige main limpio en reefops-platform." >&2
  exit 2
fi
platform_revision="$(git -C "${project_root}" rev-parse HEAD)"
if [[ ! -s "${acceptance_evidence}" ]] ||
  ! tail -n 1 "${acceptance_evidence}" |
    jq -e --arg revision "${platform_revision}" \
      '.result == "success" and .platform_revision == $revision' >/dev/null; then
  echo "Falta una aceptación S3 satisfactoria para la revisión activa." >&2
  exit 2
fi
if [[ "$(kubectl config current-context)" != "${cluster_context}" ]] ||
  [[ "$(
    kubectl get namespace "${namespace}" \
      -o jsonpath='{.metadata.labels.reefops\.io/environment}'
  )" != "${environment_id}" ]]; then
  echo "Contexto o entorno Kubernetes inesperado." >&2
  exit 2
fi
for reconciliation in \
  reefops-seaweedfs-secret \
  reefops-seaweedfs-stack \
  reefops-seaweedfs-config; do
  applied_revision="$(
    kubectl -n flux-system get kustomization "${reconciliation}" -o json |
      jq -er '
        select(.status.conditions[] |
          .type == "Ready" and .status == "True") |
        .status.lastAppliedRevision |
        sub("^(main@)?sha1:"; "")
      '
  )"
  if [[ "${applied_revision}" != "${platform_revision}" ]]; then
    echo "${reconciliation} no aplica la revisión local exacta." >&2
    exit 2
  fi
done
chart_digest="$(
  kubectl -n flux-system get ocirepository seaweedfs -o json |
    jq -er '.status.artifact.digest'
)"
if [[ "${chart_digest}" != \
  "sha256:e06855fbad1c4f74e7f1d25af477668e6be247ab213b940ac6229533a8b87a4b" ]]; then
  echo "El chart desplegado no coincide con el digest autorizado." >&2
  exit 2
fi
kubectl -n "${namespace}" get pod \
  -l app.kubernetes.io/name=seaweedfs -o json >"${temp_dir}/pods.json"
if ! jq -e --arg digest \
  "docker.io/chrislusf/seaweedfs@sha256:c7d6c721b30ae711db766bbbfd40192776e263d4e51e22f57baef7bef93c12c6" '
    .items | length == 4 and
    all(.[].spec.containers[]; .image == $digest)
  ' "${temp_dir}/pods.json" >/dev/null; then
  echo "El runtime SeaweedFS no coincide con la revisión autorizada." >&2
  exit 2
fi
for permission in \
  "get secret/seaweedfs-s3-config" \
  "create pods/portforward"; do
  read -r verb resource <<<"${permission}"
  if [[ "$(kubectl auth can-i "${verb}" "${resource}" -n "${namespace}")" != "yes" ]]; then
    echo "El actor Kubernetes no está autorizado para ${permission}." >&2
    exit 2
  fi
done
cluster_resource_id="$(
  {
    kubectl get namespace "${namespace}" -o jsonpath='{.metadata.uid}'
    printf ':'
    kubectl -n "${namespace}" get pvc \
      -l app.kubernetes.io/instance=reefops-seaweedfs -o json |
      jq -r '[.items[].metadata.uid] | sort | join(",")'
  } | shasum -a 256 | awk '{print $1}'
)"

kubectl -n "${namespace}" get secret seaweedfs-s3-config \
  -o jsonpath='{.data.seaweedfs_s3_config}' |
  base64 --decode >"${credentials_file}"
chmod 0600 "${credentials_file}"
AWS_ACCESS_KEY_ID="$(
  jq -er '.identities[0].credentials[0].accessKey' "${credentials_file}"
)"
AWS_SECRET_ACCESS_KEY="$(
  jq -er '.identities[0].credentials[0].secretKey' "${credentials_file}"
)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="us-east-1"

kubectl -n "${namespace}" port-forward service/reefops-seaweedfs-s3 \
  "${local_port}:8333" >"${port_forward_log}" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 60); do
  if curl -sS "http://127.0.0.1:${local_port}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
endpoint="http://127.0.0.1:${local_port}"
aws --endpoint-url "${endpoint}" s3api list-buckets >/dev/null

failure_phase="create-synthetic-source"
if ! seaweedfs_assert_bucket_absent "${endpoint}" "${source_bucket}" ||
  ! seaweedfs_assert_bucket_absent "${endpoint}" "${restore_bucket}"; then
  echo "No se puede demostrar la ausencia de los buckets del ensayo." >&2
  exit 3
fi
openssl rand 2097152 >"${export_dir}/recovery.bin"
object_sha256="$(
  shasum -a 256 "${export_dir}/recovery.bin" | awk '{print $1}'
)"
aws --endpoint-url "${endpoint}" s3api create-bucket \
  --bucket "${source_bucket}" >/dev/null
seaweedfs_mark_bucket_owned \
  "${endpoint}" "${source_bucket}" "${operation_id}"
aws --endpoint-url "${endpoint}" s3api put-object \
  --bucket "${source_bucket}" --key "${object_key}" \
  --body "${export_dir}/recovery.bin" \
  --metadata "correlation-id=${correlation_id},sha256=${object_sha256}" \
  --tagging "classification=synthetic&purpose=recovery" >/dev/null
aws --endpoint-url "${endpoint}" s3api head-object \
  --bucket "${source_bucket}" --key "${object_key}" \
  >"${export_dir}/head.json"
aws --endpoint-url "${endpoint}" s3api get-object-tagging \
  --bucket "${source_bucket}" --key "${object_key}" \
  >"${export_dir}/tags.json"

failure_phase="encrypt-backup"
jq -n \
  --arg schema_version "1" \
  --arg environment_id "${environment_id}" \
  --arg source_bucket "${source_bucket}" \
  --arg object_key "${object_key}" \
  --arg object_sha256 "${object_sha256}" \
  --arg correlation_id "${correlation_id}" \
  '{
    schema_version: $schema_version,
    environment_id: $environment_id,
    source_bucket: $source_bucket,
    object_key: $object_key,
    object_sha256: $object_sha256,
    correlation_id: $correlation_id,
    payload_classification: "synthetic"
  }' >"${export_dir}/inventory.json"
tar -czf "${plain_archive}" -C "${export_dir}" .
archive_sha256="$(
  shasum -a 256 "${plain_archive}" | awk '{print $1}'
)"
age --recipient "${age_recipient}" \
  --output "${backup_file}" "${plain_archive}"
chmod 0600 "${backup_file}"
encrypted_sha256="$(
  shasum -a 256 "${backup_file}" | awk '{print $1}'
)"
jq -n \
  --arg schema_version "1" \
  --arg created_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg actor "$(id -un)" \
  --arg environment_id "${environment_id}" \
  --arg platform_revision "${platform_revision}" \
  --arg archive_sha256 "${archive_sha256}" \
  --arg encrypted_sha256 "${encrypted_sha256}" \
  --arg object_sha256 "${object_sha256}" \
  --arg correlation_id "${correlation_id}" \
  --arg causation_id "${causation_id}" \
  '{
    schema_version: $schema_version,
    component: "seaweedfs-development",
    created_at: $created_at,
    actor: $actor,
    environment_id: $environment_id,
    platform_revision: $platform_revision,
    chart_digest: "sha256:e06855fbad1c4f74e7f1d25af477668e6be247ab213b940ac6229533a8b87a4b",
    image_digest: "sha256:c7d6c721b30ae711db766bbbfd40192776e263d4e51e22f57baef7bef93c12c6",
    archive_sha256: $archive_sha256,
    encrypted_sha256: $encrypted_sha256,
    object_sha256: $object_sha256,
    payload_classification: "synthetic",
    correlation_id: $correlation_id,
    causation_id: $causation_id,
    minimum_retention_days: 30
  }' >"${plain_manifest}"
age --recipient "${age_recipient}" \
  --output "${manifest_file}" "${plain_manifest}"
chmod 0600 "${manifest_file}"

failure_phase="isolated-restore"
seaweedfs_cleanup_bucket "${endpoint}" "${source_bucket}" "${operation_id}"
age --decrypt --identity "${age_identity}" \
  --output "${restored_archive}" "${backup_file}"
age --decrypt --identity "${age_identity}" \
  --output "${restored_manifest}" "${manifest_file}"
if [[ "$(shasum -a 256 "${backup_file}" | awk '{print $1}')" != "$(
  jq -er '.encrypted_sha256' "${restored_manifest}"
)" ]] ||
  [[ "$(shasum -a 256 "${restored_archive}" | awk '{print $1}')" != "$(
    jq -er '.archive_sha256' "${restored_manifest}"
  )" ]]; then
  echo "El artefacto restaurado no coincide con su manifiesto." >&2
  exit 4
fi
tar -xzf "${restored_archive}" -C "${restore_dir}"
if [[ "$(shasum -a 256 "${restore_dir}/recovery.bin" | awk '{print $1}')" != "${object_sha256}" ]]; then
  echo "El payload descifrado no conserva su checksum." >&2
  exit 4
fi

aws --endpoint-url "${endpoint}" s3api create-bucket \
  --bucket "${restore_bucket}" >/dev/null
seaweedfs_mark_bucket_owned \
  "${endpoint}" "${restore_bucket}" "${operation_id}"
metadata="$(
  jq -c '.Metadata' "${restore_dir}/head.json"
)"
aws --endpoint-url "${endpoint}" s3api put-object \
  --bucket "${restore_bucket}" --key "${object_key}" \
  --body "${restore_dir}/recovery.bin" \
  --metadata "${metadata}" >/dev/null
aws --endpoint-url "${endpoint}" s3api put-object-tagging \
  --bucket "${restore_bucket}" --key "${object_key}" \
  --tagging "file://${restore_dir}/tags.json"
aws --endpoint-url "${endpoint}" s3api get-object \
  --bucket "${restore_bucket}" --key "${object_key}" \
  "${temp_dir}/verified.bin" >/dev/null
if [[ "$(shasum -a 256 "${temp_dir}/verified.bin" | awk '{print $1}')" != "${object_sha256}" ]]; then
  echo "La restauración aislada no conserva el contenido." >&2
  exit 4
fi
aws --endpoint-url "${endpoint}" s3api head-object \
  --bucket "${restore_bucket}" --key "${object_key}" |
  jq -e --arg sha "${object_sha256}" '.Metadata.sha256 == $sha' >/dev/null
aws --endpoint-url "${endpoint}" s3api get-object-tagging \
  --bucket "${restore_bucket}" --key "${object_key}" |
  jq -e '.TagSet | length == 2' >/dev/null

failure_phase="cleanup"
seaweedfs_cleanup_bucket "${endpoint}" "${restore_bucket}" "${operation_id}"
result="success"
failure_phase=""
echo "Backup lógico cifrado y restauración aislada SeaweedFS verificados."
echo "Backup: ${backup_file}"
echo "Manifiesto: ${manifest_file}"
