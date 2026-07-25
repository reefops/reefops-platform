#!/usr/bin/env bash

validate_evidence_chain() {
  evidence_path="$1"
  expected_previous=""

  [[ -e "${evidence_path}" ]] || return 0
  while IFS= read -r evidence_line; do
    [[ -n "${evidence_line}" ]] || continue
    previous="$(
      jq -er '.previous_record_sha256 // ""' <<<"${evidence_line}"
    )" || return 1
    recorded_hash="$(
      jq -er '.record_sha256' <<<"${evidence_line}"
    )" || return 1
    base_record="$(jq -c 'del(.record_sha256)' <<<"${evidence_line}")" ||
      return 1
    computed_hash="$(
      printf '%s' "${base_record}" | shasum -a 256 | awk '{print $1}'
    )"
    [[ "${previous}" == "${expected_previous}" ]] || return 1
    [[ "${recorded_hash}" == "${computed_hash}" ]] || return 1
    expected_previous="${recorded_hash}"
  done <"${evidence_path}"
}

seaweedfs_bucket_exists() {
  endpoint="$1"
  bucket_name="$2"
  bucket_inventory="$(
    aws --endpoint-url "${endpoint}" s3api list-buckets
  )" || return 2
  jq -e '.Buckets | type == "array"' <<<"${bucket_inventory}" >/dev/null ||
    return 2
  if jq -e --arg bucket "${bucket_name}" \
    '.Buckets | any(.Name == $bucket)' <<<"${bucket_inventory}" >/dev/null; then
    return 0
  fi
  return 1
}

seaweedfs_assert_bucket_absent() {
  endpoint="$1"
  bucket_name="$2"
  if seaweedfs_bucket_exists "${endpoint}" "${bucket_name}"; then
    return 1
  else
    bucket_status=$?
  fi
  [[ "${bucket_status}" -eq 1 ]]
}

seaweedfs_assert_bucket_owned() {
  endpoint="$1"
  bucket_name="$2"
  owner_operation="$3"
  observed_owner="$(
    aws --endpoint-url "${endpoint}" s3api head-object \
      --bucket "${bucket_name}" --key ".reefops-operation" |
      jq -er '.Metadata["operation-id"]'
  )"
  [[ "${observed_owner}" == "${owner_operation}" ]]
}

seaweedfs_mark_bucket_owned() {
  endpoint="$1"
  bucket_name="$2"
  owner_operation="$3"
  aws --endpoint-url "${endpoint}" s3api put-object \
    --bucket "${bucket_name}" \
    --key ".reefops-operation" \
    --metadata "operation-id=${owner_operation}" >/dev/null
}

seaweedfs_cleanup_bucket() {
  endpoint="$1"
  bucket_name="$2"
  owner_operation="$3"

  if seaweedfs_bucket_exists "${endpoint}" "${bucket_name}"; then
    :
  else
    bucket_status=$?
    if [[ "${bucket_status}" -eq 1 ]]; then
      return 0
    fi
    return 1
  fi
  seaweedfs_assert_bucket_owned \
    "${endpoint}" "${bucket_name}" "${owner_operation}" || return 1

  uploads="$(
    aws --endpoint-url "${endpoint}" s3api list-multipart-uploads \
      --bucket "${bucket_name}" |
      jq -c '.Uploads // [] | .[]'
  )" || return 1
  while IFS= read -r upload; do
    [[ -n "${upload}" ]] || continue
    upload_key="$(jq -er '.Key' <<<"${upload}")" || return 1
    upload_id="$(jq -er '.UploadId' <<<"${upload}")" || return 1
    aws --endpoint-url "${endpoint}" s3api abort-multipart-upload \
      --bucket "${bucket_name}" \
      --key "${upload_key}" \
      --upload-id "${upload_id}" || return 1
  done <<<"${uploads}"

  aws --endpoint-url "${endpoint}" s3 rb "s3://${bucket_name}" --force \
    >/dev/null || return 1
  seaweedfs_assert_bucket_absent "${endpoint}" "${bucket_name}"
}
