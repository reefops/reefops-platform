#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/environments/development" >"${temp_dir}/development.yaml"
kubectl kustomize "${project_root}/environments/production-foundation" >"${temp_dir}/production-foundation.yaml"
kubectl kustomize "${project_root}/environments/production" >"${temp_dir}/production.yaml"

for environment in development production; do
  config_count="$(
    yq eval \
      "select(.kind == \"ConfigMap\" and
       .metadata.name == \"reefops-environment\" and
       .data.environment_id == \"${environment}\" and
       .metadata.labels.\"reefops.io/environment\" == \"${environment}\") |
       .metadata.namespace" \
      "${temp_dir}/${environment}.yaml" |
      awk '/^reefops-/ {count++} END {print count+0}'
  )"
  if [[ "${config_count}" -ne 7 ]]; then
    echo "${environment} no tiene identidad local en sus siete namespaces." >&2
    exit 1
  fi
done

namespace_count="$(
  yq eval \
    'select(.kind == "Namespace" and
     .metadata.labels."reefops.io/environment" == "production" and
     .metadata.annotations."kustomize.toolkit.fluxcd.io/prune" == "disabled") |
     .metadata.name' \
    "${temp_dir}/production-foundation.yaml" |
    awk '/^reefops-prod-/ {count++} END {print count+0}'
)"
policy_count="$(
  yq eval \
    'select(.kind == "NetworkPolicy" and
     .metadata.name == "default-deny" and
     (.spec.policyTypes | contains(["Ingress", "Egress"]))) |
     .metadata.namespace' \
    "${temp_dir}/production.yaml" |
    awk '/^reefops-prod-/ {count++} END {print count+0}'
)"
if [[ "${namespace_count}" -ne 7 || "${policy_count}" -ne 7 ]]; then
  echo "La foundation production no conserva namespaces protegidos y default-deny." >&2
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

echo "Foundations development/production validadas."
