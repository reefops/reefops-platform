#!/usr/bin/env bash
set -euo pipefail

bao status >/dev/null

if ! bao audit list -format=json | jq -e 'has("file/")' >/dev/null; then
  bao audit enable file file_path=/openbao/audit/audit.log
fi

if ! bao secrets list -format=json | jq -e 'has("ci/")' >/dev/null; then
  bao secrets enable -path=ci kv-v2
fi

if ! bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  bao auth enable kubernetes
fi

bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443 >/dev/null

echo "OpenBao configurado con audit file, KV CI y autenticación Kubernetes."
