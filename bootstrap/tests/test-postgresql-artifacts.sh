#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/cloudnative-pg-stack" \
  >"${temp_dir}/cnpg.yaml"
kubectl kustomize "${project_root}/platform/barman-cloud-stack" \
  >"${temp_dir}/barman.yaml"

verify_chart() {
  manifest="$1"
  repository="$2"
  version="$3"
  package_sha="$4"
  expected_digest="$5"
  destination="${temp_dir}/${repository}"
  mkdir "${destination}"
  declared_digest="$(
    yq eval "select(.kind == \"OCIRepository\") | .spec.ref.digest" "${manifest}"
  )"
  [[ "${declared_digest}" == "${expected_digest}" ]] || {
    echo "Digest OCI inesperado para ${repository}." >&2
    return 1
  }
  pull_output="$(
    helm pull "oci://ghcr.io/reefops/${repository}" \
      --version "${version}" --destination "${destination}" 2>&1
  )"
  grep -F "Digest: ${expected_digest}" <<<"${pull_output}" >/dev/null || {
    echo "El mirror OCI de ${repository} no coincide." >&2
    return 1
  }
  archive="${destination}/${repository}-${version}.tgz"
  [[ "$(shasum -a 256 "${archive}" | awk '{print $1}')" == "${package_sha}" ]] || {
    echo "El paquete ${repository} difiere del upstream aprobado." >&2
    return 1
  }
}

verify_chart "${temp_dir}/cnpg.yaml" cloudnative-pg 0.29.0 \
  668e065ff53508d58238788fd35b355a925060843629a951df0e6a9362e6d32f \
  sha256:0553f0dcb0790533d95d5f31efe811687ca9164994ef1cfb3e93888d272c7b3a
verify_chart "${temp_dir}/barman.yaml" plugin-barman-cloud 0.7.0 \
  683494c04cc94f7d33c4ac5f3d8d64c209634b48bd0e84da31d7d1fad22cdcdb \
  sha256:1494ce378b6121430db69d4015debb8ac839996118fa1fd38f4f7053995c0fcf

cosign verify \
  ghcr.io/cloudnative-pg/cloudnative-pg@sha256:a2701eb97cdd2a34b1fdb2cb51987f544b706e40bec72ae7146cd8580efefebb \
  --certificate-identity='https://github.com/cloudnative-pg/cloudnative-pg/.github/workflows/release-publish.yml@refs/tags/v1.30.0' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  >/dev/null
cosign verify \
  ghcr.io/cloudnative-pg/postgis@sha256:0b3f86d55fcbafad6fcde45ca58fa816d4d37bab26abc67a4cefe16d562fd05f \
  --certificate-identity='https://github.com/cloudnative-pg/postgres-containers/.github/workflows/bake_targets.yml@refs/heads/main' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  >/dev/null

yq eval '
  select(.kind == "HelmRelease" and .metadata.name == "cloudnative-pg") |
  .spec.values
  ' "${temp_dir}/cnpg.yaml" >"${temp_dir}/cnpg-values.yaml"
yq eval '
  select(.kind == "HelmRelease" and
    .metadata.name == "plugin-barman-cloud") |
  .spec.values
  ' "${temp_dir}/barman.yaml" >"${temp_dir}/barman-values.yaml"
helm template cloudnative-pg \
  "${temp_dir}/cloudnative-pg/cloudnative-pg-0.29.0.tgz" \
  --namespace reefops-database-system \
  --values "${temp_dir}/cnpg-values.yaml" >"${temp_dir}/cnpg-rendered.yaml"
helm template plugin-barman-cloud \
  "${temp_dir}/plugin-barman-cloud/plugin-barman-cloud-0.7.0.tgz" \
  --namespace reefops-database-system \
  --values "${temp_dir}/barman-values.yaml" >"${temp_dir}/barman-rendered.yaml"
kubeconform -strict -ignore-missing-schemas \
  "${temp_dir}/cnpg-rendered.yaml" "${temp_dir}/barman-rendered.yaml"

if yq eval '
  select(.kind == "Service" and
    (.spec.type == "LoadBalancer" or .spec.type == "NodePort")) |
  .metadata.name
  ' "${temp_dir}/cnpg-rendered.yaml" "${temp_dir}/barman-rendered.yaml" |
  sed '/^---$/d' | grep -q .; then
  echo "Los charts PostgreSQL renderizan exposición norte-sur." >&2
  exit 1
fi

if ! yq eval -e '
  select(.kind == "HelmRelease" and .metadata.name == "cloudnative-pg") |
  .metadata.namespace == "reefops-database-system" and
  .spec.values.replicaCount == 1 and
  .spec.values.config.clusterWide == true and
  .spec.values.config.data.WATCH_NAMESPACE == "reefops-data" and
  (.spec.values.image.tag |
    test("^1.30.0@sha256:[a-f0-9]{64}$")) and
  .spec.values.rbac.aggregateClusterRoles == false
  ' "${temp_dir}/cnpg.yaml" >/dev/null; then
  echo "CloudNativePG no conserva versión, scope o hardening." >&2
  exit 1
fi
if ! yq eval -e '
  select(.kind == "HelmRelease" and
    .metadata.name == "plugin-barman-cloud") |
  .metadata.namespace == "reefops-database-system" and
  .spec.values.replicaCount == 1 and
  (.spec.values.image.tag |
    test("^v0.13.0@sha256:[a-f0-9]{64}$")) and
  (.spec.values.sidecarImage.tag |
    test("^v0.13.0@sha256:[a-f0-9]{64}$"))
  ' "${temp_dir}/barman.yaml" >/dev/null; then
  echo "Barman Cloud no conserva versión o digests." >&2
  exit 1
fi

echo "Mirrors, paquetes e imágenes PostgreSQL fijados y validados."
