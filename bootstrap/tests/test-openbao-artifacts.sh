#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/openbao" \
  >"${temp_dir}/active.yaml"
kubectl kustomize "${project_root}/recovery/openbao" \
  >"${temp_dir}/recovery.yaml"

chart_digest="$(
  yq eval '
    select(.kind == "OCIRepository" and .metadata.name == "openbao") |
    .spec.ref.digest
  ' "${temp_dir}/active.yaml"
)"
if [[ ! "${chart_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "El chart OpenBao no está fijado por digest OCI." >&2
  exit 1
fi

pull_output="$(
  helm pull oci://ghcr.io/openbao/charts/openbao \
    --version 0.28.6 \
    --destination "${temp_dir}" 2>&1
)"
if ! grep -F "Digest: ${chart_digest}" <<<"${pull_output}" >/dev/null; then
  echo "El chart OpenBao publicado no coincide con el digest declarado." >&2
  exit 1
fi

for deployment in active recovery; do
  release_name="openbao"
  namespace="reefops-secrets"
  if [[ "${deployment}" == "recovery" ]]; then
    release_name="openbao-recovery"
    namespace="reefops-openbao-recovery"
  fi

  release="$(
    RELEASE_NAME="${release_name}" yq eval '
      select(.kind == "HelmRelease" and
        .metadata.name == strenv(RELEASE_NAME))
    ' "${temp_dir}/${deployment}.yaml"
  )"
  if ! yq eval -e '
    .spec.chartRef.kind == "OCIRepository" and
    .spec.chartRef.name == "openbao" and
    .spec.chartRef.namespace == "flux-system" and
    (.spec.values.server.image.tag |
      test("^2\\.6\\.1@sha256:[a-f0-9]{64}$")) and
    .spec.values.server.statefulSet.securityContext.pod.runAsNonRoot == true and
    .spec.values.server.statefulSet.securityContext.pod.seccompProfile.type ==
      "RuntimeDefault" and
    .spec.values.server.statefulSet.securityContext.container.allowPrivilegeEscalation ==
      false and
    (.spec.values.server.statefulSet.securityContext.container.capabilities.drop |
      length) == 1 and
    .spec.values.server.statefulSet.securityContext.container.capabilities.drop[0] ==
      "ALL"
    ' <<<"${release}" >/dev/null; then
    echo "El release ${release_name} no conserva artefactos o hardening." >&2
    exit 1
  fi

  yq eval '.spec.values' <<<"${release}" \
    >"${temp_dir}/${deployment}-values.yaml"
  helm template "${release_name}" \
    "${temp_dir}/openbao-0.28.6.tgz" \
    --namespace "${namespace}" \
    --values "${temp_dir}/${deployment}-values.yaml" \
    >"${temp_dir}/${deployment}-chart.yaml"

  rendered_image="$(
    yq eval '
      select(.kind == "StatefulSet") |
      .spec.template.spec.containers[] |
      select(.name == "openbao") |
      .image
    ' "${temp_dir}/${deployment}-chart.yaml"
  )"
  if [[ ! "${rendered_image}" =~ ^(quay\.io/)?openbao/openbao:2\.6\.1@sha256:[a-f0-9]{64}$ ]]; then
    echo "La imagen efectiva de ${release_name} no está fijada por digest." >&2
    exit 1
  fi
done

echo "Artefactos OCI y hardening de OpenBao validados."
