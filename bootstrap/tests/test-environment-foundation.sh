#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/environments/development" >"${temp_dir}/development.yaml"

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
if [[ "${config_count}" -ne 8 ]]; then
  echo "Development no tiene identidad local en sus ocho namespaces." >&2
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
