#!/usr/bin/env bash
set -euo pipefail

cluster_context="${1:-docker-desktop}"
github_owner="${REEFOPS_GITHUB_OWNER:?Define REEFOPS_GITHUB_OWNER}"
github_repository="${REEFOPS_GITHUB_REPOSITORY:-reefops-gitops}"
git_branch="${REEFOPS_GIT_BRANCH:-main}"
age_key_file="${REEFOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/reefops/age/keys.txt}"
platform_repository="${REEFOPS_PLATFORM_REPOSITORY:-reefops-platform}"
expected_remote_path="clusters/local/kustomization.yaml"
flux_toolkit_version="v2.9.3"

kubectl config use-context "${cluster_context}" >/dev/null

gh repo view "${github_owner}/${github_repository}" >/dev/null
gh repo view "${github_owner}/${platform_repository}" >/dev/null
gh api \
  "repos/${github_owner}/${github_repository}/contents/${expected_remote_path}?ref=${git_branch}" \
  --silent
github_token="$(gh auth token --hostname github.com)"
export GITHUB_TOKEN="${github_token}"

bootstrap_args=(
  --owner="${github_owner}"
  --repository="${github_repository}"
  --branch="${git_branch}"
  --path="clusters/local"
  --token-auth=false
  --version="${flux_toolkit_version}"
)

authenticated_owner="$(gh api user --jq .login)"
if [[ "${github_owner,,}" == "${authenticated_owner,,}" ]]; then
  bootstrap_args+=(--personal)
fi

flux_bootstrapped=false
if kubectl --context "${cluster_context}" \
    -n flux-system get deployment source-controller >/dev/null 2>&1 &&
  kubectl --context "${cluster_context}" \
    -n flux-system get gitrepository flux-system >/dev/null 2>&1 &&
  kubectl --context "${cluster_context}" \
    -n flux-system get kustomization flux-system >/dev/null 2>&1; then
  flux_bootstrapped=true
fi

main_protected=false
if gh api \
  "repos/${github_owner}/${github_repository}/branches/${git_branch}/protection" \
  --silent >/dev/null 2>&1; then
  main_protected=true
fi

if [[ "${flux_bootstrapped}" == "false" && "${main_protected}" == "true" ]]; then
  echo "Retira temporalmente la protección antes del bootstrap inicial." >&2
  exit 1
fi

if [[ "${flux_bootstrapped}" == "false" ]]; then
  flux bootstrap github "${bootstrap_args[@]}"
else
  flux check --context "${cluster_context}"
fi

unset GITHUB_TOKEN
unset github_token

if [[ ! -f "${age_key_file}" ]]; then
  install -d -m 0700 "$(dirname "${age_key_file}")"
  age-keygen -o "${age_key_file}"
  chmod 0600 "${age_key_file}"
  echo "Clave age creada fuera del repositorio: ${age_key_file}"
fi

kubectl --context "${cluster_context}" -n flux-system create secret generic sops-age \
  --from-file=age.agekey="${age_key_file}" \
  --dry-run=client \
  -o yaml |
  kubectl --context "${cluster_context}" apply -f -

flux reconcile source git flux-system --context "${cluster_context}"
flux reconcile source git reefops-platform \
  --namespace flux-system \
  --context "${cluster_context}"
flux reconcile kustomization flux-system \
  --with-source \
  --context "${cluster_context}"
flux check --context "${cluster_context}"
