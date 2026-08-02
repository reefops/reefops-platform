#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
rendered="$(kubectl kustomize "${project_root}/platform/metrics-server")"

yq eval -e '
  select(.kind == "Deployment" and .metadata.name == "metrics-server") |
  .metadata.namespace == "kube-system" and
  .spec.template.spec.serviceAccountName == "metrics-server" and
  (.spec.template.spec.containers[0].image |
    test("^registry.k8s.io/metrics-server/metrics-server@sha256:[a-f0-9]{64}$")) and
  (.spec.template.spec.containers[0].args | contains([
    "--kubelet-use-node-status-port", "--kubelet-insecure-tls",
    "--metric-resolution=15s"
  ])) and
  .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
  .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false and
  .spec.template.spec.containers[0].resources.requests.cpu == "100m" and
  .spec.template.spec.containers[0].resources.limits.memory == "300Mi"
' <<<"${rendered}" >/dev/null

yq eval -e '
  select(.kind == "APIService" and .metadata.name == "v1beta1.metrics.k8s.io") |
  .spec.service.name == "metrics-server" and
  .spec.service.namespace == "kube-system"
' <<<"${rendered}" >/dev/null

echo "Metrics Server fijado y API de recursos declarada para HPA."

