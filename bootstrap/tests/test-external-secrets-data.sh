#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/external-secrets-data" \
  >"${temp_dir}/controller.yaml"
kubectl kustomize "${project_root}/platform/seaweedfs-secret" \
  >"${temp_dir}/seaweedfs.yaml"
kubectl kustomize "${project_root}/platform/postgresql-secret" \
  >"${temp_dir}/postgresql.yaml"

if ! yq eval -e '
  select(.kind == "HelmRelease" and
    .metadata.name == "external-secrets-data") |
  .metadata.namespace == "reefops-data" and
  .spec.releaseName == "external-secrets-data" and
  .spec.values.installCRDs == false and
  .spec.values.scopedNamespace == "reefops-data" and
  .spec.values.scopedRBAC == true and
  .spec.values.processClusterExternalSecret == false and
  .spec.values.processClusterPushSecret == false and
  .spec.values.processClusterStore == false and
  .spec.values.processClusterGenerator == false and
  .spec.values.processPushSecret == false and
  .spec.values.rbac.serviceAccountTokenCreate == false and
  .spec.values.webhook.create == false and
  .spec.values.certController.create == false and
  (.spec.values.image.tag |
    test("^v2\\.8\\.0@sha256:[a-f0-9]{64}$")) and
  .spec.values.resources.requests.cpu == "20m" and
  .spec.values.resources.requests.memory == "64Mi" and
  .spec.values.resources.limits.cpu == "250m" and
  .spec.values.resources.limits.memory == "256Mi"
  ' "${temp_dir}/controller.yaml" >/dev/null; then
  echo "El controlador ESO de datos no conserva alcance y recursos mínimos." >&2
  exit 1
fi

for consumer in seaweedfs postgresql; do
  if ! yq eval -e '
    select(.kind == "RoleBinding") |
    (.subjects | length) == 1 and
    .subjects[0].kind == "ServiceAccount" and
    .subjects[0].name == "external-secrets-data" and
    .subjects[0].namespace == "reefops-data"
    ' "${temp_dir}/${consumer}.yaml" >/dev/null; then
    echo "La autorización ESO de ${consumer} no usa el controlador neutral." >&2
    exit 1
  fi
done

seaweedfs_identity="$(
  yq eval '
    select(.kind == "SecretStore" and .metadata.name == "openbao-seaweedfs") |
    .spec.provider.vault.auth.kubernetes.serviceAccountRef.name
  ' "${temp_dir}/seaweedfs.yaml"
)"
postgresql_identity="$(
  yq eval '
    select(.kind == "SecretStore" and .metadata.name == "openbao-postgresql") |
    .spec.provider.vault.auth.kubernetes.serviceAccountRef.name
  ' "${temp_dir}/postgresql.yaml"
)"
if [[ "${seaweedfs_identity}" != "external-secrets-seaweedfs-openbao" ||
  "${postgresql_identity}" != "external-secrets-postgresql-openbao" ||
  "${seaweedfs_identity}" == "${postgresql_identity}" ]]; then
  echo "Los consumidores de datos no conservan identidades OpenBao separadas." >&2
  exit 1
fi

if yq eval '
  select(.kind == "HelmRelease" and
    .metadata.name == "external-secrets-data") |
  .metadata.name
  ' "${temp_dir}/seaweedfs.yaml" "${temp_dir}/postgresql.yaml" |
  sed '/^---$/d' | grep -q .; then
  echo "Un consumidor no debe ser propietario del controlador ESO compartido." >&2
  exit 1
fi

echo "Controlador ESO de datos neutral e identidades por consumidor validados."
