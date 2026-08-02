#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
rendered="$(kubectl kustomize "${project_root}/platform/authorizer")"

yq eval -e '
  select(.kind == "Deployment" and .metadata.name == "reefops-authorizer") |
  .metadata.namespace == "reefops-identity" and
  (.spec.replicas == null) and
  .spec.template.spec.serviceAccountName == "reefops-authorizer" and
  .spec.template.spec.automountServiceAccountToken == false and
  .spec.template.metadata.annotations."linkerd.io/inject" == "enabled" and
  (.spec.template.spec.containers[0].image |
    test("^ghcr.io/reefops/reefops-authorizer@sha256:[a-f0-9]{64}$")) and
  .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
  .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false and
  (.spec.template.spec.containers[0].envFrom | length) == 2 and
  (.spec.template.spec.containers[0].env[] |
    select(.name == "OTEL_EXPORTER_OTLP_ENDPOINT") |
    .value == "otel-collector.reefops-observability.svc.cluster.local:4317")
' <<<"${rendered}" >/dev/null

yq eval -e '
  select(.kind == "HorizontalPodAutoscaler" and
    .metadata.name == "reefops-authorizer") |
  .spec.minReplicas == 1 and .spec.maxReplicas == 5 and
  .spec.metrics[0].resource.name == "cpu" and
  .spec.metrics[0].resource.target.averageUtilization == 70
' <<<"${rendered}" >/dev/null

for policy in authorizer-default-deny authorizer-grpc-ingress \
  authorizer-metrics-ingress authorizer-dns-egress \
  authorizer-dependency-egress postgresql-authorizer-ingress; do
  yq eval -e "select(.kind == \"NetworkPolicy\" and .metadata.name == \"${policy}\")" \
    <<<"${rendered}" >/dev/null
done

yq eval -e '
  select(.kind == "ServiceMonitor" and .metadata.name == "reefops-authorizer") |
  .spec.endpoints[0].port == "metrics" and .spec.endpoints[0].path == "/metrics"
' <<<"${rendered}" >/dev/null

yq eval -e '
  select(.kind == "PrometheusRule" and .metadata.name == "reefops-authorizer") |
  ([.spec.groups[].rules[].alert] |
    contains(["ReefOpsAuthorizerUnavailable", "ReefOpsAuthorizerAuditUnavailable",
      "ReefOpsAuthorizerDependencyUnavailable", "ReefOpsAuthorizerHighLatency",
      "ReefOpsAuthorizerAtMaxReplicas"]))
' <<<"${rendered}" >/dev/null

yq eval -e '
  select(.kind == "ServerAuthorization" and
    .metadata.name == "reefops-authorizer-from-envoy") |
  .spec.client.meshTLS.serviceAccounts[0].name == "reefops-envoy-edge" and
  .spec.client.meshTLS.serviceAccounts[0].namespace == "reefops-gateway-system"
' <<<"${rendered}" >/dev/null

echo "Authorizer aislado, observable y preparado para HPA validado."
