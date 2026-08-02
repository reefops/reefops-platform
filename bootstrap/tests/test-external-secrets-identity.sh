#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
rendered="$(kubectl kustomize "${project_root}/platform/external-secrets-identity")"
yq eval -e '
  select(.kind == "HelmRelease" and
    .metadata.name == "external-secrets-identity") |
  .metadata.namespace == "reefops-identity" and
  .spec.chartRef.name == "external-secrets" and
  .spec.values.scopedNamespace == "reefops-identity" and
  .spec.values.scopedRBAC == true and
  .spec.values.installCRDs == false and
  .spec.values.leaderElect == false and
  .spec.values.processClusterExternalSecret == false and
  .spec.values.processClusterStore == false and
  .spec.values.webhook.create == false and
  .spec.values.certController.create == false and
  (.spec.values.image.tag | test("^v2\\.8\\.0@sha256:[a-f0-9]{64}$"))
' <<<"${rendered}" >/dev/null || {
  echo "ESO identity no conserva alcance namespaced y digest." >&2
  exit 1
}
echo "Controller ESO de identidad namespaced validado."
