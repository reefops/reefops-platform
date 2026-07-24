#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
github_owner="${REEFOPS_GITHUB_OWNER:?Define REEFOPS_GITHUB_OWNER}"
github_repository="${REEFOPS_PLATFORM_REPOSITORY:-reefops-platform}"
git_branch="${REEFOPS_GIT_BRANCH:-main}"
repository_ref="${github_owner}/${github_repository}"

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

cp -R "${project_root}/infra/bootstrap" "${seed_dir}/bootstrap"
cp -R "${project_root}/infra/infrastructure" "${seed_dir}/infrastructure"
cp -R "${project_root}/infra/platform" "${seed_dir}/platform"
install -d "${seed_dir}/docs"
cp "${project_root}/docs/gestion-secretos.md" "${seed_dir}/docs/gestion-secretos.md"
cp "${project_root}/infra/bootstrap/templates/platform/README.md" \
  "${seed_dir}/README.md"
cp "${project_root}/infra/bootstrap/templates/platform/Taskfile.yml" \
  "${seed_dir}/Taskfile.yml"
cp "${project_root}/LICENSE" "${seed_dir}/LICENSE"

git -C "${seed_dir}" add .
git -C "${seed_dir}" commit -m "bootstrap ReefOps platform catalog"
git -C "${seed_dir}" push --set-upstream origin "${git_branch}"

echo "Catálogo de plataforma inicial publicado en ${repository_ref}:${git_branch}."
