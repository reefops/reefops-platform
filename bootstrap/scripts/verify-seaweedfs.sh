#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source "${project_root}/bootstrap/scripts/lib/seaweedfs-common.sh"
cluster_context="${REEFOPS_KUBE_CONTEXT:-docker-desktop}"
environment_id="${REEFOPS_ENVIRONMENT_ID:-development}"
namespace="reefops-data"
local_port="${REEFOPS_SEAWEEDFS_VERIFY_PORT:-18333}"
state_dir="${REEFOPS_SEAWEEDFS_AUDIT_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/reefops/seaweedfs}"
evidence_file="${state_dir}/operations.jsonl"
evidence_lock="${evidence_file}.lock"
temp_dir="$(mktemp -d)"
port_forward_log="${temp_dir}/port-forward.log"
credentials_file="${temp_dir}/credentials.json"
object_file="${temp_dir}/object.bin"
download_file="${temp_dir}/download.bin"
multipart_file="${temp_dir}/multipart.bin"
part_one="${temp_dir}/part-one.bin"
part_two="${temp_dir}/part-two.bin"
port_forward_pid=""
endpoint=""
lock_acquired="false"
evidence_chain_valid="false"
bucket=""
result="failure"
failure_phase="preflight"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
platform_revision=""
gitops_revision=""
chart_digest=""
kubernetes_authorization_verified="false"
object_sha256=""
pvc_uids_before=""
pvc_uids_after=""
cleanup_status="not-run"

record_evidence() {
  previous_hash=""
  if [[ -s "${evidence_file}" ]]; then
    previous_hash="$(tail -n 1 "${evidence_file}" | jq -er '.record_sha256')"
  fi
  base_record="$(
    jq -cn \
      --arg schema_version "1" \
      --arg operation_id "${operation_id}" \
      --arg operation "seaweedfs-s3-contract" \
      --arg actor "$(id -un)" \
      --arg authentication "kubernetes-operator-and-eso-secret" \
      --arg authorization "local-platform-operator" \
      --arg environment_id "${environment_id}" \
      --arg cluster_context "${cluster_context}" \
      --arg platform_revision "${platform_revision}" \
      --arg gitops_revision "${gitops_revision}" \
      --arg chart_digest "${chart_digest}" \
      --arg image_digest "sha256:c7d6c721b30ae711db766bbbfd40192776e263d4e51e22f57baef7bef93c12c6" \
      --arg object_sha256 "${object_sha256}" \
      --arg pvc_uids_before "${pvc_uids_before}" \
      --arg pvc_uids_after "${pvc_uids_after}" \
      --arg started_at "${started_at}" \
      --arg finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --arg result "${result}" \
      --arg failure_phase "${failure_phase}" \
      --arg correlation_id "${correlation_id}" \
      --arg causation_id "${causation_id}" \
      --arg cleanup_status "${cleanup_status}" \
      --arg kubernetes_authorization_verified "${kubernetes_authorization_verified}" \
      --arg previous_record_sha256 "${previous_hash}" \
      '{
        schema_version: $schema_version,
        operation_id: $operation_id,
        operation: $operation,
        actor: $actor,
        authentication: $authentication,
        authorization: $authorization,
        environment_id: $environment_id,
        cluster_context: $cluster_context,
        platform_revision: $platform_revision,
        gitops_revision: $gitops_revision,
        chart_digest: $chart_digest,
        image_digest: $image_digest,
        object_sha256: $object_sha256,
        pvc_uids_before: ($pvc_uids_before | split(",") | map(select(length > 0))),
        pvc_uids_after: ($pvc_uids_after | split(",") | map(select(length > 0))),
        tested_capabilities: [
          "PutObject", "GetObject", "HeadObject", "DeleteObject",
          "ListObjectsV2", "RangeGet", "Metadata", "Tags", "Checksum",
          "MultipartComplete", "MultipartAbort", "PresignedGet",
          "PodRestartPersistence"
        ],
        payload_classification: "synthetic",
        started_at: $started_at,
        finished_at: $finished_at,
        result: $result,
        failure_phase: (if $result == "success" then null else $failure_phase end),
        correlation_id: $correlation_id,
        causation_id: $causation_id,
        cleanup_status: $cleanup_status,
        kubernetes_authorization_verified:
          ($kubernetes_authorization_verified == "true"),
        previous_record_sha256: $previous_record_sha256
      }'
  )"
  record_hash="$(
    printf '%s' "${base_record}" | shasum -a 256 | awk '{print $1}'
  )"
  jq -c --arg record_sha256 "${record_hash}" \
    '. + {record_sha256: $record_sha256}' <<<"${base_record}" \
    >>"${evidence_file}"
}

cleanup() {
  exit_code=$?
  trap - EXIT
  set +e
  cleanup_failed="false"
  cleanup_status="success"
  if [[ -n "${bucket}" && -n "${AWS_ACCESS_KEY_ID:-}" &&
    -n "${endpoint}" ]]; then
    if ! seaweedfs_cleanup_bucket \
      "${endpoint}" "${bucket}" "${operation_id}"; then
      cleanup_failed="true"
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
  find "${temp_dir}" -type f -delete
  rmdir "${temp_dir}" >/dev/null 2>&1
  if [[ "${lock_acquired}" == "true" &&
    "${evidence_chain_valid}" == "true" ]]; then
    record_evidence || exit_code=5
  fi
  if [[ "${lock_acquired}" == "true" ]]; then
    rmdir "${evidence_lock}" >/dev/null 2>&1
  fi
  if [[ "${cleanup_failed}" == "true" && "${exit_code}" -eq 0 ]]; then
    exit_code=5
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

for command in kubectl jq yq aws curl openssl shasum; do
  command -v "${command}" >/dev/null || {
    echo "Falta la herramienta ${command}." >&2
    exit 2
  }
done

install -d -m 0700 "${state_dir}"
touch "${evidence_file}"
chmod 0600 "${evidence_file}"
if ! mkdir "${evidence_lock}" 2>/dev/null; then
  echo "Ya existe una verificación SeaweedFS en curso." >&2
  exit 2
fi
lock_acquired="true"
if ! validate_evidence_chain "${evidence_file}"; then
  echo "La cadena de evidencia SeaweedFS no es íntegra." >&2
  exit 2
fi
evidence_chain_valid="true"

if [[ "$(git -C "${project_root}" branch --show-current)" != "main" ]] ||
  [[ -n "$(git -C "${project_root}" status --porcelain)" ]]; then
  echo "La aceptación exige main limpio en reefops-platform." >&2
  exit 2
fi
platform_revision="$(git -C "${project_root}" rev-parse HEAD)"
gitops_revision="$(
  kubectl -n flux-system get gitrepository flux-system -o json |
    jq -er '.status.artifact.revision | sub("^(main@)?sha1:"; "")'
)"

if [[ "$(kubectl config current-context)" != "${cluster_context}" ]] ||
  [[ "$(
    kubectl get namespace "${namespace}" \
      -o jsonpath='{.metadata.labels.reefops\.io/environment}'
  )" != "${environment_id}" ]]; then
  echo "Contexto o entorno Kubernetes inesperado." >&2
  exit 2
fi

data_config_revision="$(
  kubectl -n flux-system get kustomization \
    reefops-data-secret-delivery-config -o json |
    jq -er '
      select(.status.conditions[] |
        .type == "Ready" and .status == "True") |
      .status.lastAppliedRevision |
      sub("^(main@)?sha1:"; "")
    '
)"
if [[ "${data_config_revision}" != "${gitops_revision}" ]]; then
  echo "La configuración privada de entrega no aplica la revisión GitOps exacta." >&2
  exit 2
fi

for reconciliation in \
  reefops-external-secrets-data \
  reefops-seaweedfs-secret \
  reefops-seaweedfs-stack \
  reefops-seaweedfs-config; do
  applied_revision="$(
    kubectl -n flux-system get kustomization "${reconciliation}" \
      -o json |
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
  kubectl -n flux-system get ocirepository seaweedfs -o json \
    >"${temp_dir}/chart-source.json"
  jq -er '.status.artifact.revision' "${temp_dir}/chart-source.json"
)"
if ! jq -e \
  --arg oci_digest \
    "sha256:e06855fbad1c4f74e7f1d25af477668e6be247ab213b940ac6229533a8b87a4b" \
  --arg package_digest \
    "sha256:dbecd4c1f3cd5ae2eac62f3a0ccd92c05c1b05a20bd2b5f574c1e69dec440da2" '
    .spec.ref.digest == $oci_digest and
    .status.artifact.revision == $oci_digest and
    .status.artifact.digest == $package_digest and
    any(.status.conditions[];
      .type == "Ready" and .status == "True")
  ' "${temp_dir}/chart-source.json" >/dev/null; then
  echo "El chart desplegado no coincide con el digest autorizado." >&2
  exit 2
fi
for permission in \
  "get secret/seaweedfs-s3-config" \
  "create pods/portforward" \
  "delete pods"; do
  read -r verb resource <<<"${permission}"
  if [[ "$(kubectl auth can-i "${verb}" "${resource}" -n "${namespace}")" != "yes" ]]; then
    echo "El actor Kubernetes no está autorizado para ${permission}." >&2
    exit 2
  fi
done
kubernetes_authorization_verified="true"

failure_phase="readiness"
kubectl -n "${namespace}" wait \
  --for=condition=Ready secretstore/openbao-seaweedfs --timeout=180s
kubectl -n "${namespace}" wait \
  --for=condition=Ready externalsecret/seaweedfs-s3-config --timeout=180s
kubectl -n "${namespace}" wait \
  --for=condition=Ready pod \
  -l app.kubernetes.io/name=seaweedfs \
  --timeout=300s

kubectl get ingress -A -o json >"${temp_dir}/ingresses.json"
kubectl -n "${namespace}" get service -o json >"${temp_dir}/services.json"
kubectl -n "${namespace}" get pod \
  -l app.kubernetes.io/name=seaweedfs -o json >"${temp_dir}/pods.json"
if jq -e '.items[] | select(.metadata.namespace == "reefops-data")' \
  "${temp_dir}/ingresses.json" >/dev/null ||
  jq -e '
    .items[] |
    select(
      .spec.type == "NodePort" or
      .spec.type == "LoadBalancer" or
      ((.spec.externalIPs // []) | length > 0)
    )
  ' "${temp_dir}/services.json" >/dev/null ||
  jq -e '
    .items[] |
    select(
      .spec.hostNetwork == true or
      any(.spec.containers[].ports[]?; .hostPort != null)
    )
  ' "${temp_dir}/pods.json" >/dev/null; then
  echo "SeaweedFS tiene una exposición de red no autorizada." >&2
  exit 3
fi

if jq -e --arg digest \
    "docker.io/chrislusf/seaweedfs@sha256:c7d6c721b30ae711db766bbbfd40192776e263d4e51e22f57baef7bef93c12c6" '
      .items | length == 4 and
      all(.[].spec.containers[]; .image == $digest)
    ' "${temp_dir}/pods.json" >/dev/null; then
  :
else
  echo "Los cuatro pods no usan la imagen fijada." >&2
  exit 3
fi

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

failure_phase="s3-contract"
bucket="reefops-acceptance-${operation_id}"
if ! seaweedfs_assert_bucket_absent "${endpoint}" "${bucket}"; then
  echo "No se puede demostrar que el bucket sintético esté ausente." >&2
  exit 3
fi
aws --endpoint-url "${endpoint}" s3api create-bucket \
  --bucket "${bucket}" >/dev/null
seaweedfs_mark_bucket_owned "${endpoint}" "${bucket}" "${operation_id}"
openssl rand 1048576 >"${object_file}"
object_sha256="$(shasum -a 256 "${object_file}" | awk '{print $1}')"
aws --endpoint-url "${endpoint}" s3api put-object \
  --bucket "${bucket}" \
  --key "contract/object.bin" \
  --body "${object_file}" \
  --metadata "correlation-id=${correlation_id},sha256=${object_sha256}" \
  --tagging "classification=synthetic&purpose=acceptance" \
  --checksum-algorithm SHA256 >/dev/null
aws --endpoint-url "${endpoint}" s3api head-object \
  --bucket "${bucket}" --key "contract/object.bin" \
  --checksum-mode ENABLED >"${temp_dir}/head.json"
if [[ "$(jq -er '.Metadata.sha256' "${temp_dir}/head.json")" != "${object_sha256}" ]]; then
  echo "HEAD no conserva la metadata esperada." >&2
  exit 3
fi
aws --endpoint-url "${endpoint}" s3api get-object \
  --bucket "${bucket}" --key "contract/object.bin" \
  "${download_file}" >/dev/null
if [[ "$(shasum -a 256 "${download_file}" | awk '{print $1}')" != "${object_sha256}" ]]; then
  echo "GET no conserva el contenido." >&2
  exit 3
fi
aws --endpoint-url "${endpoint}" s3api get-object \
  --bucket "${bucket}" --key "contract/object.bin" \
  --range bytes=0-31 "${temp_dir}/range.bin" >/dev/null
[[ "$(wc -c <"${temp_dir}/range.bin" | tr -d ' ')" == "32" ]]
aws --endpoint-url "${endpoint}" s3api get-object-tagging \
  --bucket "${bucket}" --key "contract/object.bin" |
  jq -e '.TagSet | length == 2' >/dev/null
if ! aws --endpoint-url "${endpoint}" s3api list-objects-v2 \
  --bucket "${bucket}" --prefix "contract/" |
  jq -e '
    (.Contents // []) | length == 1 and
    .[0].Key == "contract/object.bin"
  ' >/dev/null; then
  echo "ListObjectsV2 no devuelve la clave sintética exacta." >&2
  exit 3
fi
presigned_url="$(
  aws --endpoint-url "${endpoint}" s3 presign \
    "s3://${bucket}/contract/object.bin" --expires-in 60
)"
curl -fsS "${presigned_url}" -o "${temp_dir}/presigned.bin"
if [[ "$(shasum -a 256 "${temp_dir}/presigned.bin" | awk '{print $1}')" != "${object_sha256}" ]]; then
  echo "La URL prefirmada no conserva el contenido." >&2
  exit 3
fi
presigned_url=""

dd if=/dev/urandom of="${multipart_file}" bs=1048576 count=6 status=none
dd if="${multipart_file}" of="${part_one}" bs=1048576 count=5 status=none
dd if="${multipart_file}" of="${part_two}" bs=1048576 skip=5 count=1 status=none
upload_id="$(
  aws --endpoint-url "${endpoint}" s3api create-multipart-upload \
    --bucket "${bucket}" --key "contract/multipart.bin" |
    jq -er '.UploadId'
)"
etag_one="$(
  aws --endpoint-url "${endpoint}" s3api upload-part \
    --bucket "${bucket}" --key "contract/multipart.bin" \
    --part-number 1 --upload-id "${upload_id}" --body "${part_one}" |
    jq -er '.ETag'
)"
etag_two="$(
  aws --endpoint-url "${endpoint}" s3api upload-part \
    --bucket "${bucket}" --key "contract/multipart.bin" \
    --part-number 2 --upload-id "${upload_id}" --body "${part_two}" |
    jq -er '.ETag'
)"
jq -n \
  --arg etag_one "${etag_one}" \
  --arg etag_two "${etag_two}" \
  '{Parts: [
    {ETag: $etag_one, PartNumber: 1},
    {ETag: $etag_two, PartNumber: 2}
  ]}' >"${temp_dir}/multipart.json"
aws --endpoint-url "${endpoint}" s3api complete-multipart-upload \
  --bucket "${bucket}" --key "contract/multipart.bin" \
  --upload-id "${upload_id}" \
  --multipart-upload "file://${temp_dir}/multipart.json" >/dev/null
abort_upload_id="$(
  aws --endpoint-url "${endpoint}" s3api create-multipart-upload \
    --bucket "${bucket}" --key "contract/aborted.bin" |
    jq -er '.UploadId'
)"
aws --endpoint-url "${endpoint}" s3api abort-multipart-upload \
  --bucket "${bucket}" --key "contract/aborted.bin" \
  --upload-id "${abort_upload_id}"

failure_phase="restart-persistence"
pvc_uids_before="$(
  kubectl -n "${namespace}" get pvc \
    -l app.kubernetes.io/instance=reefops-seaweedfs \
    -o json |
    jq -r '[.items[].metadata.uid] | sort | join(",")'
)"
for component in filer volume master s3; do
  pod="$(
    kubectl -n "${namespace}" get pod \
      -l "app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=${component}" \
      -o jsonpath='{.items[0].metadata.name}'
  )"
  kubectl -n "${namespace}" delete pod "${pod}" --wait=false >/dev/null
  kubectl -n "${namespace}" wait \
    --for=condition=Ready pod \
    -l "app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=${component}" \
    --timeout=300s >/dev/null
done
kill "${port_forward_pid}" >/dev/null 2>&1 || true
wait "${port_forward_pid}" >/dev/null 2>&1 || true
kubectl -n "${namespace}" port-forward service/reefops-seaweedfs-s3 \
  "${local_port}:8333" >"${port_forward_log}" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 60); do
  if curl -sS "http://127.0.0.1:${local_port}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
pvc_uids_after="$(
  kubectl -n "${namespace}" get pvc \
    -l app.kubernetes.io/instance=reefops-seaweedfs \
    -o json |
    jq -r '[.items[].metadata.uid] | sort | join(",")'
)"
if [[ "${pvc_uids_before}" != "${pvc_uids_after}" ]]; then
  echo "Los PVC cambiaron durante el reinicio." >&2
  exit 4
fi
aws --endpoint-url "${endpoint}" s3api get-object \
  --bucket "${bucket}" --key "contract/object.bin" \
  "${temp_dir}/after-restart.bin" >/dev/null
if [[ "$(shasum -a 256 "${temp_dir}/after-restart.bin" | awk '{print $1}')" != "${object_sha256}" ]]; then
  echo "El objeto no persistió al reinicio." >&2
  exit 4
fi

result="success"
failure_phase=""
echo "Contrato S3 y persistencia SeaweedFS verificados."
