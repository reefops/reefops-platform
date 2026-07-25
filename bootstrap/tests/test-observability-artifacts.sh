#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/observability-stack" \
  >"${temp_dir}/stack.yaml"

chart_digest="$(
  yq eval '
    select(.kind == "OCIRepository" and
      .metadata.name == "kube-prometheus-stack") |
    .spec.ref.digest
  ' "${temp_dir}/stack.yaml"
)"
if [[ ! "${chart_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "El chart de observabilidad no está fijado por digest OCI." >&2
  exit 1
fi

pull_output="$(
  helm pull \
    oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
    --version 86.0.0 \
    --destination "${temp_dir}" 2>&1
)"
if ! grep -F "Digest: ${chart_digest}" <<<"${pull_output}" >/dev/null; then
  echo "El chart publicado no coincide con el digest declarado." >&2
  exit 1
fi

release="$(
  yq eval '
    select(.kind == "HelmRelease" and
      .metadata.name == "reefops-monitoring")
  ' "${temp_dir}/stack.yaml"
)"
if ! yq eval -e '
  .spec.chartRef.kind == "OCIRepository" and
  .spec.chartRef.name == "kube-prometheus-stack" and
  .spec.chartRef.namespace == "flux-system" and
  .spec.install.crds == "CreateReplace" and
  .spec.upgrade.crds == "CreateReplace" and
  .spec.values.prometheus.prometheusSpec.retention == "7d" and
  .spec.values.prometheus.prometheusSpec.retentionSize == "8GB" and
  .spec.values.grafana.enabled == false and
  .spec.values.prometheusOperator.namespaces.releaseNamespace == true and
  .spec.values.prometheus.prometheusSpec.serviceMonitorSelector.matchLabels.release ==
    "reefops-monitoring" and
  .spec.values.prometheus.prometheusSpec.ruleSelector.matchLabels.release ==
    "reefops-monitoring" and
  .spec.values."prometheus-node-exporter".hostNetwork == false and
  .spec.values."prometheus-node-exporter".hostPID == false and
  .spec.values."prometheus-node-exporter".namespaceOverride ==
    "reefops-node-observability"
  ' <<<"${release}" >/dev/null; then
  echo "El release no conserva el alcance o hardening acordados." >&2
  exit 1
fi

yq eval '.spec.values' <<<"${release}" >"${temp_dir}/values.yaml"
helm template reefops-monitoring \
  "${temp_dir}/kube-prometheus-stack-86.0.0.tgz" \
  --namespace reefops-observability \
  --values "${temp_dir}/values.yaml" \
  >"${temp_dir}/rendered.yaml"

for resource_kind in ClusterRole ClusterRoleBinding; do
  if ! yq eval -e \
    "select(.kind == \"${resource_kind}\" and
      .metadata.name == \"reefops-monitoring-operator\")" \
    "${temp_dir}/rendered.yaml" >/dev/null; then
    echo "El post-render ya no apunta a la RBAC real del operador." >&2
    exit 1
  fi
  if ! PATCH_MARKER="\$patch: delete" yq eval -e \
    ".spec.postRenderers[0].kustomize.patches[] |
      select(.target.kind == \"${resource_kind}\" and
        .target.name == \"reefops-monitoring-operator\" and
        (.patch | contains(strenv(PATCH_MARKER))))" \
    <<<"${release}" >/dev/null; then
    echo "Falta la eliminación efectiva de ${resource_kind} del operador." >&2
    exit 1
  fi
done

if grep -F '@sha256:sha256:' "${temp_dir}/rendered.yaml" >/dev/null; then
  echo "El render contiene un digest con prefijo duplicado." >&2
  exit 1
fi

runtime_images="$(
  yq eval '
    select(.kind == "Deployment" or
      .kind == "DaemonSet" or
      .kind == "StatefulSet" or
      .kind == "Job") |
    (.spec.template.spec.initContainers[]?.image,
     .spec.template.spec.containers[]?.image) |
    select(tag == "!!str")
  ' "${temp_dir}/rendered.yaml" |
    sed '/^---$/d'
)"
runtime_images+=$'\n'"$(
  yq eval '
    select(.kind == "Prometheus" or .kind == "Alertmanager") |
    .spec.image |
    select(tag == "!!str")
  ' "${temp_dir}/rendered.yaml" |
    sed '/^---$/d'
)"

while IFS= read -r image; do
  [[ -z "${image}" ]] && continue
  if [[ ! "${image}" =~ @sha256:[a-f0-9]{64}$ ]]; then
    echo "Imagen efectiva no fijada por digest: ${image}" >&2
    exit 1
  fi
done <<<"${runtime_images}"

operator_args="$(
  yq eval '
    select(.kind == "Deployment" and
      .metadata.name == "reefops-monitoring-operator") |
    .spec.template.spec.containers[] |
    select(.name == "kube-prometheus-stack") |
    .args[]
  ' "${temp_dir}/rendered.yaml"
)"
for argument in \
  "--prometheus-config-reloader=" \
  "--thanos-default-base-image="; do
  image="$(awk -F= -v prefix="${argument}" '$0 ~ "^" prefix {print $2}' \
    <<<"${operator_args}")"
  if [[ ! "${image}" =~ @sha256:[a-f0-9]{64}$ ]]; then
    echo "Imagen inyectada por el operador no fijada: ${argument}" >&2
    exit 1
  fi
done

echo "Chart, imágenes, retención y selectores de observabilidad validados."
