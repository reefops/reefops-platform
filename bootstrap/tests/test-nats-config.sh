#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/nats-stack" >"${temp_dir}/stack.yaml"
kubectl kustomize "${project_root}/platform/nats-config" >"${temp_dir}/config.yaml"

if ! yq eval -e '
  select(.kind == "OCIRepository" and .metadata.name == "nats") |
  .metadata.namespace == "flux-system" and
  .spec.ref.digest ==
    "sha256:125e2ce8ba16d6f2765dd4cc84799a5e59520172893edb5b0196c69d2dc799b4" and
  .spec.layerSelector.mediaType ==
    "application/vnd.cncf.helm.chart.content.v1.tar+gzip" and
  .spec.layerSelector.operation == "copy" and
  .spec.url == "oci://ghcr.io/reefops/nats"
' "${temp_dir}/stack.yaml" >/dev/null ||
  ! yq eval -e '
  select(.kind == "HelmRelease" and .metadata.name == "reefops-nats") |
  .metadata.namespace == "reefops-system" and
  .metadata.annotations."reefops.io/chart-sha256" ==
    "86e0fbfe000b6d7fe70a3032ad3a667252f2d3dd2022e95f7330704d947d0f84" and
  .spec.chartRef.kind == "OCIRepository" and
  .spec.chartRef.name == "nats" and
  .spec.values.config.cluster.enabled == false and
  .spec.values.config.jetstream.enabled == true and
  .spec.values.config.jetstream.fileStore.pvc.size == "10Gi" and
  .spec.values.config.jetstream.fileStore.pvc.storageClassName ==
    "reefops-hostpath-retain" and
  .spec.values.config.websocket.enabled == false and
  .spec.values.config.mqtt.enabled == false and
  .spec.values.config.leafnodes.enabled == false and
  .spec.values.config.gateway.enabled == false and
  (.spec.values.container.image.fullImageName |
    test("^nats@sha256:[a-f0-9]{64}$")) and
  (.spec.values.promExporter.image.fullImageName |
    test("^natsio/prometheus-nats-exporter@sha256:[a-f0-9]{64}$")) and
  .spec.values.natsBox.enabled == false and
  .spec.values.service.merge.spec.type == "ClusterIP"
' "${temp_dir}/stack.yaml" >/dev/null; then
  echo "NATS incumple versión, persistencia, superficie o digests." >&2
  exit 1
fi

policy_count="$(yq eval 'select(.kind == "NetworkPolicy") | .metadata.name' \
  "${temp_dir}/config.yaml" | sed '/^---$/d' | awk 'NF {n++} END {print n+0}')"
[[ "${policy_count}" -eq 2 ]] || {
  echo "NATS no conserva deny-by-default y allowlist de observabilidad." >&2
  exit 1
}
yq eval -e '
  select(.kind == "PodMonitor" and .metadata.name == "reefops-nats") |
  .metadata.namespace == "reefops-observability" and
  .metadata.labels.release == "reefops-monitoring" and
  .spec.podMetricsEndpoints[0].port == "prom-metrics"
' "${temp_dir}/config.yaml" >/dev/null || {
  echo "NATS no tiene monitor interno seleccionable." >&2
  exit 1
}

echo "NATS JetStream, persistencia, aislamiento y observabilidad validados."
