#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
touch "${test_root}/ca.crt"

if BAO_ADDR=https://127.0.0.1:8200 \
  BAO_CACERT="${test_root}/ca.crt" \
  BAO_TLS_SERVER_NAME=openbao.reefops-secrets.svc \
  REEFOPS_OPENBAO_VERIFY_PATH=ci/healthcheck \
  "${project_root}/bootstrap/scripts/verify-openbao-recovery.sh" \
  >/dev/null 2>&1; then
  echo "La verificación aceptó el endpoint de la autoridad activa." >&2
  exit 1
fi

echo "Allowlist del target OpenBao probada."
