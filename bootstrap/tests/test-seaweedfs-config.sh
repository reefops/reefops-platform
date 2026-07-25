#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/seaweedfs-secret" \
  >"${temp_dir}/secret.yaml"
kubectl kustomize "${project_root}/platform/seaweedfs-config" \
  >"${temp_dir}/config.yaml"

store="$(
  yq eval '
    select(.kind == "SecretStore" and .metadata.name == "openbao-seaweedfs")
  ' "${temp_dir}/secret.yaml"
)"
external_secret="$(
  yq eval '
    select(.kind == "ExternalSecret" and
      .metadata.name == "seaweedfs-s3-config")
  ' "${temp_dir}/secret.yaml"
)"
if ! yq eval -e '
  .metadata.namespace == "reefops-data" and
  .spec.provider.vault.path == "platform" and
  .spec.provider.vault.version == "v2" and
  .spec.provider.vault.caProvider.name == "openbao-ca-bundle" and
  .spec.provider.vault.auth.kubernetes.role ==
    "reefops-seaweedfs-external-secrets" and
  .spec.provider.vault.auth.kubernetes.serviceAccountRef.name ==
    "external-secrets-seaweedfs-openbao"
  ' <<<"${store}" >/dev/null ||
  ! yq eval -e '
  .metadata.namespace == "reefops-data" and
  .spec.target.name == "seaweedfs-s3-config" and
  .spec.target.creationPolicy == "Owner" and
  .spec.target.deletionPolicy == "Delete" and
  (.spec.data | length) == 4 and
  (.spec.target.template.data.seaweedfs_s3_config |
    contains("\"actions\":[\"Admin\",\"Read\",\"Write\"]")) and
  (.spec.target.template.data.seaweedfs_s3_config |
    contains("\"name\":\"reefops-barman-cloud\"")) and
  (.spec.target.template.data.seaweedfs_s3_config |
    contains("\"Read:reefops-postgresql-backup\"")) and
  (.spec.target.template.data.seaweedfs_s3_config |
    contains("\"Write:reefops-postgresql-backup\""))
  ' <<<"${external_secret}" >/dev/null; then
  echo "La entrega S3 no conserva TLS, scope o template autenticado." >&2
  exit 1
fi

token_role="$(
  yq eval '
    select(.kind == "Role" and
      .metadata.name ==
        "external-secrets-seaweedfs-openbao-token-request")
  ' "${temp_dir}/secret.yaml"
)"
if ! yq eval -e '
  (.rules | length) == 1 and
  .rules[0].resources[0] == "serviceaccounts/token" and
  .rules[0].resourceNames[0] == "external-secrets-seaweedfs-openbao" and
  .rules[0].verbs[0] == "create"
  ' <<<"${token_role}" >/dev/null; then
  echo "El controller puede solicitar tokens fuera de su identidad." >&2
  exit 1
fi

monitor_count="$(
  yq eval 'select(.kind == "ServiceMonitor") | .metadata.name' \
    "${temp_dir}/config.yaml" |
    sed '/^---$/d' |
    awk 'NF {count++} END {print count+0}'
)"
if [[ "${monitor_count}" -ne 4 ]] ||
  ! yq eval -e '
    select(.kind == "ServiceMonitor") |
    .metadata.namespace == "reefops-observability" and
    .metadata.labels.release == "reefops-monitoring" and
    .spec.namespaceSelector.matchNames[0] == "reefops-data" and
    .spec.endpoints[0].port == "metrics"
  ' "${temp_dir}/config.yaml" >/dev/null; then
  echo "No están declarados los cuatro targets de métricas." >&2
  exit 1
fi

if ! yq eval -e '
  select(.kind == "NetworkPolicy" and
    .metadata.name == "seaweedfs-isolation") |
  .metadata.namespace == "reefops-data" and
  (.spec.policyTypes | contains(["Ingress", "Egress"])) and
  .spec.ingress[1].from[0].namespaceSelector.matchLabels[
    "reefops.io/s3-access"] == "true" and
  .spec.ingress[1].from[0].podSelector.matchLabels[
    "reefops.io/s3-client"] == "true" and
  .spec.ingress[1].ports[0].port == 8333 and
  .spec.ingress[2].from[0].namespaceSelector.matchLabels[
    "kubernetes.io/metadata.name"] == "reefops-observability" and
  .spec.ingress[2].ports[0].port == 9327
  ' "${temp_dir}/config.yaml" >/dev/null; then
  echo "La política de red no restringe S3 y métricas." >&2
  exit 1
fi

if ! grep -F 'path "platform/data/seaweedfs/s3"' \
  "${project_root}/bootstrap/openbao/policies/seaweedfs-external-secrets.hcl" \
  >/dev/null ||
  ! grep -F 'path "platform/data/postgresql/barman-s3"' \
    "${project_root}/bootstrap/openbao/policies/seaweedfs-external-secrets.hcl" \
    >/dev/null ||
  grep -E 'capabilities.*(create|update|delete|list|sudo)' \
    "${project_root}/bootstrap/openbao/policies/seaweedfs-external-secrets.hcl" \
    >/dev/null; then
  echo "La política OpenBao excede lectura de la ruta S3 exacta." >&2
  exit 1
fi

credential_bootstrap="${project_root}/bootstrap/scripts/bootstrap-seaweedfs-credentials.sh"
# shellcheck disable=SC2016
for contract in \
  'kv put -cas=0' \
  '"@${secret_file}"' \
  'validate_evidence_chain'; do
  if ! grep -F "${contract}" "${credential_bootstrap}" >/dev/null; then
    echo "El bootstrap create-once no materializa: ${contract}" >&2
    exit 1
  fi
done
# shellcheck disable=SC2016
if grep -F 'access_key="${access_key}"' "${credential_bootstrap}" >/dev/null ||
  grep -F 'secret_key="${secret_key}"' "${credential_bootstrap}" >/dev/null; then
  echo "El bootstrap expone secretos en argumentos de procesos." >&2
  exit 1
fi

if (
  # shellcheck disable=SC1091
  source "${project_root}/bootstrap/scripts/lib/seaweedfs-common.sh"
  # shellcheck disable=SC2329
  aws() {
    return 42
  }
  seaweedfs_cleanup_bucket "http://unreachable.invalid" "synthetic" "operation"
); then
  echo "La limpieza confunde un error de inventario con bucket ausente." >&2
  exit 1
fi

verifier="${project_root}/bootstrap/scripts/verify-seaweedfs.sh"
for contract in \
  'reefops-seaweedfs-secret' \
  'reefops-seaweedfs-stack' \
  'reefops-seaweedfs-config' \
  'create-multipart-upload' \
  'abort-multipart-upload' \
  '(.Contents // []) | length == 1' \
  'presign' \
  'delete pod' \
  'pvc_uids_before' \
  'validate_evidence_chain' \
  'kubectl auth can-i' \
  'get gitrepository flux-system -o json' \
  'get ocirepository seaweedfs' \
  'seaweedfs_cleanup_bucket' \
  'seaweedfs_mark_bucket_owned' \
  'record_evidence'; do
  if ! grep -F "${contract}" "${verifier}" >/dev/null; then
    echo "La aceptación no materializa el contrato: ${contract}" >&2
    exit 1
  fi
done

if grep -F '.KeyCount == 1' "${verifier}" >/dev/null; then
  echo "La aceptación depende de KeyCount, omitido por SeaweedFS 4.39." >&2
  exit 1
fi

if grep -F 'flux get source git' "${verifier}" >/dev/null; then
  echo "La aceptación depende de una salida no estable del CLI de Flux." >&2
  exit 1
fi

recovery_verifier="${project_root}/bootstrap/scripts/verify-seaweedfs-recovery.sh"
for revision_verifier in "${verifier}" "${recovery_verifier}"; do
  if ! grep -F 'sub("^(main@)?sha1:"; "")' \
    "${revision_verifier}" >/dev/null; then
    echo "Un verificador no normaliza las revisiones Git fijadas por commit." >&2
    exit 1
  fi
  for chart_contract in \
    ".spec.ref.digest == \$oci_digest" \
    ".status.artifact.revision == \$oci_digest" \
    ".status.artifact.digest == \$package_digest"; do
    if ! grep -F "${chart_contract}" "${revision_verifier}" >/dev/null; then
      echo "Un verificador confunde el manifiesto OCI y el paquete Helm." >&2
      exit 1
    fi
  done
done

for contract in \
  '/Volumes/reefops-backup/seaweedfs' \
  'age --recipient' \
  'age --decrypt' \
  'archive_sha256' \
  'isolated-restore' \
  'active_bucket_overwritten: false' \
  'validate_evidence_chain' \
  'cluster_resource_id' \
  'kubectl auth can-i' \
  'put-object-tagging'; do
  if ! grep -F "${contract}" "${recovery_verifier}" >/dev/null; then
    echo "La recuperación no materializa el contrato: ${contract}" >&2
    exit 1
  fi
done

echo "Entrega, red y observabilidad SeaweedFS validadas."
