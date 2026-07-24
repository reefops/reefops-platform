#!/usr/bin/env bash
set -euo pipefail

cluster_context="${1:-docker-desktop}"
github_owner="${REEFOPS_GITHUB_OWNER:?Define REEFOPS_GITHUB_OWNER}"
github_repository="${REEFOPS_GITHUB_REPOSITORY:-reefops-gitops}"
git_branch="${REEFOPS_GIT_BRANCH:-main}"
age_key_file="${REEFOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/reefops/age/keys.txt}"
platform_repository="${REEFOPS_PLATFORM_REPOSITORY:-reefops-platform}"
platform_key_file="${REEFOPS_PLATFORM_DEPLOY_KEY_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/reefops/ssh/platform-gitops}"
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

flux_installed=false
if kubectl --context "${cluster_context}" \
  -n flux-system get deployment source-controller >/dev/null 2>&1; then
  flux_installed=true
fi

main_protected=false
if gh api \
  "repos/${github_owner}/${github_repository}/branches/${git_branch}/protection" \
  --silent >/dev/null 2>&1; then
  main_protected=true
fi

if [[ "${flux_installed}" == "false" && "${main_protected}" == "true" ]]; then
  echo "Retira temporalmente la protección antes del bootstrap inicial." >&2
  exit 1
fi

if [[ "${flux_installed}" == "false" ]]; then
  flux bootstrap github "${bootstrap_args[@]}"
else
  flux check --context "${cluster_context}"
fi

unset GITHUB_TOKEN
unset github_token

if [[ ! -f "${platform_key_file}" ]]; then
  install -d -m 0700 "$(dirname "${platform_key_file}")"
  ssh-keygen \
    -q \
    -t ed25519 \
    -N "" \
    -C "reefops-${cluster_context}-platform-read" \
    -f "${platform_key_file}"
  chmod 0600 "${platform_key_file}"
  chmod 0644 "${platform_key_file}.pub"
fi

platform_key_title="reefops-${cluster_context}-platform-read"
platform_public_key="$(<"${platform_key_file}.pub")"
platform_public_key_material="$(awk '{print $1 " " $2}' "${platform_key_file}.pub")"
platform_key_json="$(
  gh api "repos/${github_owner}/${platform_repository}/keys" |
    jq -c \
      --arg title "${platform_key_title}" \
      '[.[] | select(.title == $title)]'
)"
platform_key_count="$(jq 'length' <<<"${platform_key_json}")"
if [[ "${platform_key_count}" == "0" ]]; then
  gh api \
    --method POST \
    "repos/${github_owner}/${platform_repository}/keys" \
    -f title="${platform_key_title}" \
    -f key="${platform_public_key}" \
    -F read_only=true \
    --silent
elif [[ "${platform_key_count}" == "1" ]]; then
  registered_key="$(jq -r '.[0].key' <<<"${platform_key_json}")"
  registered_key_material="$(awk '{print $1 " " $2}' <<<"${registered_key}")"
  registered_read_only="$(jq -r '.[0].read_only' <<<"${platform_key_json}")"
  if [[ "${registered_key_material}" != "${platform_public_key_material}" ||
    "${registered_read_only}" != "true" ]]; then
    echo "La deploy key existente no coincide o no es de solo lectura." >&2
    exit 1
  fi
else
  echo "Hay más de una deploy key con el título esperado." >&2
  exit 1
fi

flux create secret git platform-git-auth \
  --url="ssh://git@github.com/${github_owner}/${platform_repository}.git" \
  --private-key-file="${platform_key_file}" \
  --namespace=flux-system \
  --export |
  kubectl --context "${cluster_context}" apply -f -

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
