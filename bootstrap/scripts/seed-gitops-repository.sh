#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
github_owner="${REEFOPS_GITHUB_OWNER:?Define REEFOPS_GITHUB_OWNER}"
github_repository="${REEFOPS_GITHUB_REPOSITORY:-reefops-gitops}"
git_branch="${REEFOPS_GIT_BRANCH:-main}"
repository_ref="${github_owner}/${github_repository}"
platform_repository="${REEFOPS_PLATFORM_REPOSITORY:-reefops-platform}"

gh repo view "${repository_ref}" >/dev/null
if gh api "repos/${repository_ref}/commits" --silent >/dev/null 2>&1; then
  echo "El repositorio ${repository_ref} no está vacío; se rechaza el seed." >&2
  exit 1
fi

repository_ssh_url="$(gh repo view "${repository_ref}" --json sshUrl --jq .sshUrl)"
seed_dir="$(mktemp -d)"
trap 'rm -rf "${seed_dir}"' EXIT

git -C "${seed_dir}" init -b "${git_branch}" >/dev/null
git -C "${seed_dir}" remote add origin "${repository_ssh_url}"

cp -R "${project_root}/infra/clusters" "${seed_dir}/clusters"
cp -R "${project_root}/infra/applications" "${seed_dir}/applications"
cp "${project_root}/.sops.yaml" "${seed_dir}/.sops.yaml"
cp "${project_root}/infra/bootstrap/templates/gitops/README.md" \
  "${seed_dir}/README.md"
install -d "${seed_dir}/clusters/local/workloads"
cp "${project_root}/infra/bootstrap/templates/gitops/kustomization.yaml" \
  "${seed_dir}/clusters/local/workloads/kustomization.yaml"
cp "${project_root}/infra/bootstrap/templates/gitops/platform-source.yaml" \
  "${seed_dir}/clusters/local/workloads/platform-source.yaml"
cp "${project_root}/infra/bootstrap/templates/gitops/platform-reconciliation.yaml" \
  "${seed_dir}/clusters/local/workloads/platform-reconciliation.yaml"

yq -i '.spec.path = "./clusters/local/workloads"' \
  "${seed_dir}/clusters/local/reconciliation.yaml"
yq -i \
  ".spec.url = \"https://github.com/${github_owner}/${platform_repository}.git\"" \
  "${seed_dir}/clusters/local/workloads/platform-source.yaml"
platform_commit="$(
  gh api "repos/${github_owner}/${platform_repository}/commits/main" --jq .sha
)"
yq -i ".spec.ref.commit = \"${platform_commit}\"" \
  "${seed_dir}/clusters/local/workloads/platform-source.yaml"

kubectl kustomize "${seed_dir}/clusters/local/workloads" >/dev/null

git -C "${seed_dir}" add .
git -C "${seed_dir}" commit -m "bootstrap ReefOps GitOps desired state"
git -C "${seed_dir}" push --set-upstream origin "${git_branch}"

echo "Estado GitOps inicial publicado en ${repository_ref}:${git_branch}."
