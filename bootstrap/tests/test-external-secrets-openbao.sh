#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/external-secrets" \
  >"${temp_dir}/operator.yaml"
kubectl kustomize "${project_root}/platform/external-secrets-openbao" \
  >"${temp_dir}/integration.yaml"
kubectl kustomize "${project_root}/platform/openbao" \
  >"${temp_dir}/openbao.yaml"

release="$(
  yq eval \
    'select(.kind == "HelmRelease" and .metadata.name == "external-secrets")' \
    "${temp_dir}/operator.yaml"
)"
chart_digest="$(
  yq eval '
    select(.kind == "OCIRepository" and
      .metadata.name == "external-secrets") |
    .spec.ref.digest
  ' "${temp_dir}/operator.yaml"
)"
integration="$(
  yq eval \
    'select(.kind == "SecretStore" and .metadata.name == "openbao")' \
    "${temp_dir}/integration.yaml"
)"

if ! yq eval -e '
  .metadata.namespace == "reefops-secret-delivery" and
  .spec.values.scopedNamespace == "reefops-secret-delivery" and
  .spec.values.scopedRBAC == true and
  .spec.values.processClusterExternalSecret == false and
  .spec.values.processClusterPushSecret == false and
  .spec.values.processClusterStore == false and
  .spec.values.processClusterGenerator == false and
  .spec.values.processPushSecret == false and
  .spec.values.rbac.serviceAccountTokenCreate == false and
  .spec.values.rbac.aggregateToView == false and
  .spec.values.rbac.aggregateToEdit == false and
  .spec.values.rbac.aggregateToAdmin == false and
  .spec.values.webhook.create == false and
  .spec.values.certController.create == false and
  (.spec.values.image.tag |
    test("^v2\\.8\\.0@sha256:[a-f0-9]{64}$")) and
  .spec.values.image.tag == .spec.values.webhook.image.tag and
  .spec.values.image.tag == .spec.values.certController.image.tag
  ' <<<"${release}" >/dev/null; then
  echo "ESO no conserva versión, digest y alcance namespaced." >&2
  exit 1
fi

pull_output="$(
  helm pull oci://ghcr.io/external-secrets/charts/external-secrets \
    --version 2.8.0 \
    --destination "${temp_dir}" 2>&1
)"
if ! grep -F "Digest: ${chart_digest}" <<<"${pull_output}" >/dev/null; then
  echo "El chart ESO publicado no coincide con el digest declarado." >&2
  exit 1
fi
yq eval '
  select(.kind == "HelmRelease" and .metadata.name == "external-secrets") |
  .spec.values
' "${temp_dir}/operator.yaml" >"${temp_dir}/values.yaml"
helm template external-secrets \
  "${temp_dir}/external-secrets-2.8.0.tgz" \
  --namespace reefops-secret-delivery \
  --values "${temp_dir}/values.yaml" >"${temp_dir}/chart.yaml"

cluster_rbac_count="$(
  yq eval '
    select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding" or
      .kind == "ValidatingWebhookConfiguration" or
      .kind == "MutatingWebhookConfiguration") |
    .metadata.name
  ' "${temp_dir}/chart.yaml" |
  awk 'NF {count++} END {print count+0}'
)"
deployment_names="$(
  yq eval 'select(.kind == "Deployment") | .metadata.name' \
    "${temp_dir}/chart.yaml"
)"
if [[ "${cluster_rbac_count}" -ne 0 ||
  "${deployment_names}" != "external-secrets" ]]; then
  echo "El RBAC efectivo de ESO excede el controller namespaced." >&2
  exit 1
fi

if ! yq eval -e '
  .metadata.namespace == "reefops-secret-delivery" and
  .spec.provider.vault.server ==
    "https://openbao.reefops-secrets.svc:8200" and
  .spec.provider.vault.path == "ci" and
  .spec.provider.vault.version == "v2" and
  .spec.provider.vault.caProvider.type == "ConfigMap" and
  .spec.provider.vault.caProvider.name == "openbao-ca-bundle" and
  .spec.provider.vault.caProvider.key == "ca.crt" and
  .spec.provider.vault.auth.kubernetes.mountPath == "kubernetes" and
  .spec.provider.vault.auth.kubernetes.role ==
    "reefops-external-secrets" and
  .spec.provider.vault.auth.kubernetes.serviceAccountRef.name ==
    "external-secrets-openbao"
  ' <<<"${integration}" >/dev/null; then
  echo "SecretStore no conserva TLS y autenticación Kubernetes mínimos." >&2
  exit 1
fi

role_names="$(
  yq eval '
    select(.kind == "Role" and
      .metadata.name == "external-secrets-openbao-token-request") |
    .rules[0].resourceNames[]
  ' "${temp_dir}/operator.yaml"
)"
if [[ "${role_names}" != "external-secrets-openbao" ]]; then
  echo "ESO puede solicitar tokens para ServiceAccounts no autorizadas." >&2
  exit 1
fi

if ! yq eval -e '
  select(.kind == "NetworkPolicy" and
    .metadata.name == "openbao-ingress") |
  .spec.ingress[0].from[0].namespaceSelector.matchLabels[
    "reefops.io/openbao-access"] == "true" and
  .spec.ingress[0].from[0].namespaceSelector.matchLabels[
    "reefops.io/environment"] == "development" and
  .spec.ingress[0].from[1].namespaceSelector.matchLabels[
    "kubernetes.io/metadata.name"] == "reefops-secret-delivery" and
  .spec.ingress[0].from[1].namespaceSelector.matchLabels[
    "reefops.io/environment"] == "development" and
  .spec.ingress[0].from[1].podSelector.matchLabels[
    "app.kubernetes.io/name"] == "external-secrets" and
  (.spec.ingress[0].from | length) == 2
  ' "${temp_dir}/openbao.yaml" >/dev/null; then
  echo "OpenBao no limita ESO por capacidad y entorno del namespace." >&2
  exit 1
fi

if grep -RIE \
  'skip.?verify|tokenSecretRef|capabilities[[:space:]]*=[[:space:]]*[[][^]]*(list|create|update|delete|sudo)' \
  "${project_root}/platform/external-secrets" \
  "${project_root}/platform/external-secrets-openbao" \
  "${project_root}/bootstrap/openbao/policies/external-secrets.hcl"; then
  echo "La integración ESO contiene una ampliación de privilegios prohibida." >&2
  exit 1
fi

echo "Integración declarativa ESO/OpenBao validada."
