#!/usr/bin/env bash
set -euo pipefail

brew_prefix="$(brew --prefix)"
export PATH="${brew_prefix}/opt/node@24/bin:${brew_prefix}/opt/kubernetes-cli@1.34/bin:${brew_prefix}/bin:${PATH}"

missing=0
for tool in go python3.12 uv node pnpm golangci-lint gofumpt protoc buf sqlc \
  kubectl helm flux sops age bao task jq yq kubeconform shellcheck pre-commit ffmpeg \
  gh actionlint cosign syft trivy oras rg; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Falta la herramienta de desarrollo: ${tool}" >&2
    missing=1
  fi
done

if (( missing != 0 )); then
  exit 1
fi

[[ "$(go env GOVERSION)" == go1.26.* ]] || {
  echo "Se esperaba Go 1.26.x." >&2
  exit 1
}
[[ "$(python3.12 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" == "3.12" ]] || {
  echo "Se esperaba Python 3.12.x." >&2
  exit 1
}
[[ "$(node --version)" == v24.* ]] || {
  echo "Se esperaba Node.js 24.x." >&2
  exit 1
}
[[ "$(kubectl version --client -o json | jq -r '.clientVersion.minor')" == "34" ]] || {
  echo "Se esperaba kubectl 1.34.x." >&2
  exit 1
}

go version
python3.12 --version
uv --version
node --version
pnpm --version
golangci-lint --version | head -n 1
protoc --version
buf --version
sqlc version
kubectl version --client
helm version --short
flux version --client
sops --version | head -n 1
age --version
bao version
task --version
yq --version
kubeconform -v
shellcheck --version | head -n 2
pre-commit --version
ffmpeg -version | head -n 1
gh --version | head -n 1
actionlint --version
cosign version | head -n 1
syft version
trivy --version
oras version
