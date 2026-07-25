#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/environments/development" >"${temp_dir}/development.yaml"
kubectl kustomize "${project_root}/infrastructure/base" >"${temp_dir}/infrastructure.yaml"

config_count="$(
  yq eval \
    'select(.kind == "ConfigMap" and
     .metadata.name == "reefops-environment" and
     .data.environment_id == "development" and
     .metadata.labels."reefops.io/environment" == "development") |
     .metadata.namespace' \
    "${temp_dir}/development.yaml" |
    awk '/^reefops-/ {count++} END {print count+0}'
)"
if [[ "${config_count}" -ne 10 ]]; then
  echo "Development no tiene identidad local en sus diez namespaces." >&2
  exit 1
fi

if ! yq eval -e '
  select(.kind == "StorageClass" and
    .metadata.name == "reefops-hostpath-retain") |
  .provisioner == "docker.io/hostpath" and
  .reclaimPolicy == "Retain" and
  .allowVolumeExpansion == false
  ' "${temp_dir}/infrastructure.yaml" >/dev/null; then
  echo "La StorageClass stateful no conserva los PV al borrar claims." >&2
  exit 1
fi
if ! yq eval -e '
  select(.kind == "StorageClass" and
    .metadata.name == "reefops-hostpath-delete") |
  .provisioner == "docker.io/hostpath" and
  .reclaimPolicy == "Delete" and
  .allowVolumeExpansion == false and
  .metadata.labels."reefops.io/lifecycle" == "ephemeral"
  ' "${temp_dir}/infrastructure.yaml" >/dev/null; then
  echo "La StorageClass efímera no elimina los PV al cerrar un simulacro." >&2
  exit 1
fi

openbao_policy="$(
  kubectl kustomize "${project_root}/platform/openbao" |
    yq eval 'select(.kind == "NetworkPolicy" and .metadata.name == "openbao-ingress")' -
)"
if ! yq eval -e \
  '.spec.ingress[0].from[0].namespaceSelector.matchLabels."reefops.io/environment" ==
   "development" and
   .spec.ingress[0].from[0].namespaceSelector.matchLabels."reefops.io/openbao-access" ==
   "true"' <<<"${openbao_policy}" >/dev/null; then
  echo "OpenBao development no exige entorno y capacidad simultáneamente." >&2
  exit 1
fi

echo "Foundation development y aislamiento futuro validados."
