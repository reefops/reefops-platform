#!/usr/bin/env bash
set -euo pipefail

cluster_context="${1:-docker-desktop}"
missing=0

for tool in git gh kubectl flux sops age age-keygen bao helm ssh-keygen task; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Falta la herramienta requerida: ${tool}" >&2
    missing=1
  fi
done

if (( missing != 0 )); then
  exit 1
fi

current_context="$(kubectl config current-context)"
if [[ "${current_context}" != "${cluster_context}" ]]; then
  echo "Contexto activo inesperado: ${current_context}; esperado: ${cluster_context}" >&2
  exit 1
fi

kubectl --context "${cluster_context}" wait \
  --for=condition=Ready nodes --all --timeout=30s >/dev/null

default_storage_classes="$(
  kubectl --context "${cluster_context}" get storageclass -o json |
    jq '[.items[] | select(
      .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or
      .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true"
    )] | length'
)"
if [[ "${default_storage_classes}" != "1" ]]; then
  echo "Se requiere exactamente una StorageClass predeterminada." >&2
  exit 1
fi

git rev-parse --is-inside-work-tree >/dev/null
git rev-parse --verify HEAD >/dev/null 2>&1 || {
  echo "El repositorio necesita al menos un commit antes del bootstrap." >&2
  exit 1
}

flux check --pre --context "${cluster_context}"
