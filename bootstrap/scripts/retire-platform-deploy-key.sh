#!/usr/bin/env bash
set -euo pipefail

cluster_context="${1:-docker-desktop}"
github_owner="${REEFOPS_GITHUB_OWNER:?Define REEFOPS_GITHUB_OWNER}"
platform_repository="${REEFOPS_PLATFORM_REPOSITORY:-reefops-platform}"
platform_key_file="${REEFOPS_PLATFORM_DEPLOY_KEY_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/reefops/ssh/platform-gitops}"
repository_ref="${github_owner}/${platform_repository}"

source_json="$(
  kubectl --context "${cluster_context}" \
    -n flux-system get gitrepository reefops-platform -o json
)"
source_url="$(jq -r '.spec.url' <<<"${source_json}")"
source_generation="$(jq -r '.metadata.generation' <<<"${source_json}")"
source_commit="$(jq -r '.spec.ref.commit' <<<"${source_json}")"
artifact_revision="$(jq -r '.status.artifact.revision // ""' <<<"${source_json}")"
source_ready="$(
  jq -r '
    [.status.conditions[] |
      select(
        .type == "Ready" and
        .status == "True"
      )
    ][0].status // "False"
  ' <<<"${source_json}"
)"
ready_generation="$(
  jq -r '
    [.status.conditions[] |
      select(
        .type == "Ready" and
        .status == "True"
      )
    ][0].observedGeneration // -1
  ' <<<"${source_json}"
)"
source_secret="$(jq -r '.spec.secretRef.name // ""' <<<"${source_json}")"
repository_visibility="$(gh api "repos/${repository_ref}" --jq .visibility)"
if [[ "${source_url}" != "https://github.com/${repository_ref}.git" ||
  "${repository_visibility}" != "public" ||
  "${source_ready}" != "True" ||
  "${ready_generation}" != "${source_generation}" ||
  "${artifact_revision}" != "sha1:${source_commit}" ||
  -n "${source_secret}" ]]; then
  echo "La fuente pública HTTPS no está observada en el commit esperado." >&2
  exit 1
fi

platform_key_title="reefops-${cluster_context}-platform-read"
while IFS= read -r key_id; do
  gh api \
    --method DELETE \
    "repos/${repository_ref}/keys/${key_id}" \
    --silent
done < <(
  gh api "repos/${repository_ref}/keys" |
    jq -r --arg title "${platform_key_title}" \
      '.[] | select(.title == $title) | .id'
)

kubectl --context "${cluster_context}" \
  -n flux-system delete secret platform-git-auth --ignore-not-found

if [[ -f "${platform_key_file}" ]]; then
  rm -f -- "${platform_key_file}"
fi
if [[ -f "${platform_key_file}.pub" ]]; then
  rm -f -- "${platform_key_file}.pub"
fi

echo "Credencial obsoleta de ${repository_ref} retirada."
