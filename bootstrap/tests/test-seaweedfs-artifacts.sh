#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/seaweedfs-stack" \
  >"${temp_dir}/stack.yaml"

chart_digest="$(
  yq eval '
    select(.kind == "OCIRepository" and .metadata.name == "seaweedfs") |
    .spec.ref.digest
  ' "${temp_dir}/stack.yaml"
)"
if [[ ! "${chart_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "El chart SeaweedFS no está fijado por digest." >&2
  exit 1
fi

pull_output="$(
  helm pull oci://ghcr.io/reefops/seaweedfs \
    --version 4.39.0 --destination "${temp_dir}" 2>&1
)"
if ! grep -F "Digest: ${chart_digest}" <<<"${pull_output}" >/dev/null; then
  echo "El mirror OCI no coincide con el digest declarado." >&2
  exit 1
fi

if [[ "$(
  shasum -a 256 "${temp_dir}/seaweedfs-4.39.0.tgz" | awk '{print $1}'
)" != "dbecd4c1f3cd5ae2eac62f3a0ccd92c05c1b05a20bd2b5f574c1e69dec440da2" ]]; then
  echo "El mirror modificó el paquete upstream." >&2
  exit 1
fi

release="$(
  yq eval '
    select(.kind == "HelmRelease" and .metadata.name == "reefops-seaweedfs")
  ' "${temp_dir}/stack.yaml"
)"
if ! yq eval -e '
  .metadata.namespace == "reefops-data" and
  .spec.chartRef.kind == "OCIRepository" and
  .spec.chartRef.name == "seaweedfs" and
  .spec.chartRef.namespace == "flux-system" and
  .spec.values.global.seaweedfs.createClusterRole == false and
  .spec.values.global.seaweedfs.automountServiceAccountToken == false and
  .spec.values.global.seaweedfs.enableReplication == false and
  .spec.values.global.seaweedfs.replicationPlacement == "000" and
  .spec.values.master.replicas == 1 and
  .spec.values.volume.replicas == 1 and
  .spec.values.filer.replicas == 1 and
  .spec.values.s3.replicas == 1 and
  .spec.values.s3.enabled == true and
  .spec.values.s3.enableAuth == true and
  .spec.values.s3.existingConfigSecret == "seaweedfs-s3-config" and
  .spec.values.admin.enabled == false and
  .spec.values.worker.enabled == false and
  .spec.values.sftp.enabled == false and
  .spec.values.cosi.enabled == false and
  .spec.values.allInOne.enabled == false
  ' <<<"${release}" >/dev/null; then
  echo "El HelmRelease no conserva el perfil local y autenticado." >&2
  exit 1
fi

yq eval '.spec.values' <<<"${release}" >"${temp_dir}/values.yaml"
helm template reefops-seaweedfs \
  "${temp_dir}/seaweedfs-4.39.0.tgz" \
  --namespace reefops-data \
  --values "${temp_dir}/values.yaml" >"${temp_dir}/rendered.yaml"

if yq eval -e '
  select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding" or
    .kind == "Ingress")
  ' "${temp_dir}/rendered.yaml" >/dev/null 2>&1 ||
  yq eval -e '
  select(.kind == "Service" and
    (.spec.type == "LoadBalancer" or .spec.type == "NodePort"))
  ' "${temp_dir}/rendered.yaml" >/dev/null 2>&1; then
  echo "SeaweedFS renderiza RBAC global o exposición de red." >&2
  exit 1
fi

workload_count="$(
  yq eval '
    select(.kind == "StatefulSet" or .kind == "Deployment") |
    .metadata.name
  ' "${temp_dir}/rendered.yaml" |
    sed '/^---$/d' |
    awk 'NF {count++} END {print count+0}'
)"
if [[ "${workload_count}" -ne 4 ]]; then
  echo "La topología efectiva no contiene exactamente cuatro workloads." >&2
  exit 1
fi

noncompliant_containers="$(
  yq eval '
    select(.kind == "StatefulSet" or .kind == "Deployment") |
    .spec.template.spec.containers[0] |
    select(
      (.image |
        test("^docker.io/chrislusf/seaweedfs@sha256:[a-f0-9]{64}$") |
        not) or
      .securityContext.allowPrivilegeEscalation != false or
      (.securityContext.capabilities.drop | contains(["ALL"]) | not) or
      .resources.requests.cpu == null or
      .resources.requests.memory == null or
      .resources.limits.cpu == null or
      .resources.limits.memory == null
    ) |
    .name
  ' "${temp_dir}/rendered.yaml" | sed '/^---$/d'
)"
if [[ -n "${noncompliant_containers}" ]]; then
  echo "Un workload no conserva digest, hardening o límites." >&2
  exit 1
fi

non_restricted="$(
  yq eval '
    select(.kind == "StatefulSet" or .kind == "Deployment") |
    select(
      .spec.template.spec.securityContext.runAsNonRoot != true or
      .spec.template.spec.securityContext.seccompProfile.type !=
        "RuntimeDefault"
    ) |
    .metadata.name
  ' "${temp_dir}/rendered.yaml" | sed '/^---$/d'
)"
if [[ -n "${non_restricted}" ]]; then
  echo "Un workload no cumple el contexto restricted." >&2
  exit 1
fi

claim_summary="$(
  yq eval -o=json '
    select(.kind == "StatefulSet") |
    .spec.volumeClaimTemplates[] |
    {
      "class": .spec.storageClassName,
      "size": .spec.resources.requests.storage,
      "keep": .metadata.annotations."helm.sh/resource-policy"
    }
  ' "${temp_dir}/rendered.yaml" | jq -s .
)"
if ! jq -e '
  length == 3 and
  all(.[]; .class == "reefops-hostpath-retain" and .keep == "keep") and
  ([.[].size] | sort) == (["1Gi", "2Gi", "20Gi"] | sort)
  ' <<<"${claim_summary}" >/dev/null; then
  echo "Los PVC no conservan clase, tamaño y retención declarados." >&2
  exit 1
fi

echo "Mirror, imagen, topología, seguridad y persistencia SeaweedFS validados."
