#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
rendered="$(kubectl kustomize "${project_root}/platform/protected-gateway")"

yq eval -e '
  select(.kind == "EnvoyProxy" and .metadata.name == "reefops-edge") |
  .spec.provider.kubernetes.envoyService.type == "ClusterIP" and
  (.spec.provider.kubernetes.envoyDeployment.container.image |
    test("@sha256:[a-f0-9]{64}$")) and
  .spec.provider.kubernetes.envoyDeployment.pod.annotations."linkerd.io/inject" == "enabled" and
  .spec.provider.kubernetes.envoyDeployment.pod.annotations."config.linkerd.io/proxy-cpu-request" == "10m" and
  .spec.provider.kubernetes.envoyDeployment.container.securityContext.runAsUser == 65532 and
  .spec.provider.kubernetes.envoyDeployment.container.securityContext.runAsGroup == 65532 and
  .spec.provider.kubernetes.envoyHpa.minReplicas == 1 and
  .spec.provider.kubernetes.envoyHpa.maxReplicas == 5 and
  .spec.telemetry.metrics.prometheus.disable == false and
  .spec.telemetry.tracing.provider.type == "OpenTelemetry" and
  .spec.telemetry.tracing.provider.backendRefs[0].name == "otel-collector" and
  .spec.telemetry.accessLog.settings[0].sinks[0].file.path == "/dev/stdout"
' <<<"${rendered}" >/dev/null

yq eval -e '
  select(.kind == "Gateway" and .metadata.name == "reefops") |
  .spec.listeners[0].port == 8080 and
  .spec.listeners[0].allowedRoutes.namespaces.from == "Same"
' <<<"${rendered}" >/dev/null

yq eval -e '
  select(.kind == "EnvoyProxy" and .metadata.name == "reefops-edge") |
  .spec.telemetry.accessLog.settings[0].format.json.authorization_decision_id_request ==
    "%REQ(X-REEFOPS-AUTHORIZATION-DECISION-ID)%" and
  .spec.telemetry.accessLog.settings[0].format.json.authorization_decision_id_response ==
    "%RESP(X-REEFOPS-AUTHORIZATION-DECISION-ID)%" and
  .spec.telemetry.accessLog.settings[0].format.json.correlation_id_request ==
    "%REQ(X-CORRELATION-ID)%" and
  .spec.telemetry.accessLog.settings[0].format.json.correlation_id_response ==
    "%RESP(X-CORRELATION-ID)%"
' <<<"${rendered}" >/dev/null

if yq eval 'select(.kind == "HTTPRoute" or .kind == "GRPCRoute") | .metadata.name' \
  <<<"${rendered}" | awk 'NF && $0 != "---" {found=1} END {exit found ? 0 : 1}'; then
  echo "El data plane inicial no debe publicar rutas antes de ext-auth." >&2
  exit 1
fi

for policy in envoy-edge-default-deny envoy-edge-metrics-ingress envoy-edge-egress; do
  yq eval -e "select(.kind == \"NetworkPolicy\" and .metadata.name == \"${policy}\")" \
    <<<"${rendered}" >/dev/null
done

yq eval -e '
  select(.kind == "PodMonitor" and .metadata.name == "reefops-envoy-edge") |
  ([.spec.podMetricsEndpoints[].port] | contains(["metrics", "linkerd-admin"]))
' <<<"${rendered}" >/dev/null

echo "Data plane Envoy cerrado, observable y preparado para HPA validado."
