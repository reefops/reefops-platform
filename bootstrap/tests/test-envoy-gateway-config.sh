#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/envoy-gateway-config" \
  >"${temp_dir}/config.yaml"

if grep -F 'envoy-gateway-' \
  "${project_root}/platform/kustomization.yaml" >/dev/null; then
  echo "El agregado platform no debe saltarse el orden stack/config." >&2
  exit 1
fi

monitor="$(
  yq eval '
    select(.kind == "ServiceMonitor" and .metadata.name == "envoy-gateway")
  ' "${temp_dir}/config.yaml"
)"
if ! yq eval -e '
  .metadata.namespace == "reefops-observability" and
  .metadata.labels.release == "reefops-monitoring" and
  (.spec.namespaceSelector.matchNames | length) == 1 and
  .spec.namespaceSelector.matchNames[0] == "reefops-gateway-system" and
  .spec.selector.matchLabels."control-plane" == "envoy-gateway" and
  .spec.selector.matchLabels."app.kubernetes.io/instance" ==
    "reefops-envoy-gateway" and
  .spec.endpoints[0].port == "metrics"
  ' <<<"${monitor}" >/dev/null; then
  echo "El ServiceMonitor no tiene ownership o selector exacto." >&2
  exit 1
fi

deny_policy="$(
  yq eval '
    select(.kind == "NetworkPolicy" and
      .metadata.name == "default-deny-ingress")
  ' "${temp_dir}/config.yaml"
)"
metrics_policy="$(
  yq eval '
    select(.kind == "NetworkPolicy" and
      .metadata.name == "allow-prometheus-metrics")
  ' "${temp_dir}/config.yaml"
)"
if ! yq eval -e '
  .metadata.namespace == "reefops-gateway-system" and
  (.spec.podSelector | keys | length) == 0 and
  (.spec.policyTypes | length) == 1 and
  .spec.policyTypes[0] == "Ingress" and
  (.spec | has("ingress") | not)
  ' <<<"${deny_policy}" >/dev/null ||
  ! yq eval -e '
  .metadata.namespace == "reefops-gateway-system" and
  .spec.podSelector.matchLabels."control-plane" == "envoy-gateway" and
  .spec.ingress[0].from[0].namespaceSelector.matchLabels[
    "kubernetes.io/metadata.name"] == "reefops-observability" and
  (.spec.ingress[0].ports | length) == 1 and
  .spec.ingress[0].ports[0].protocol == "TCP" and
  .spec.ingress[0].ports[0].port == 19001
  ' <<<"${metrics_policy}" >/dev/null; then
  echo "Las NetworkPolicy no aíslan el controlador y sus métricas." >&2
  exit 1
fi

verifier="${project_root}/bootstrap/scripts/verify-envoy-gateway.sh"
for contract in \
  'reefops-envoy-gateway-stack' \
  'reefops-envoy-gateway-config' \
  'gatewayclasses.gateway.networking.k8s.io' \
  'LoadBalancer' \
  'NodePort' \
  'serviceMonitor/reefops-observability/envoy-gateway' \
  'record_evidence'; do
  if ! grep -F "${contract}" "${verifier}" >/dev/null; then
    echo "La aceptación no materializa el contrato: ${contract}" >&2
    exit 1
  fi
done

echo "Métricas, aislamiento y aceptación de Envoy Gateway validados."
