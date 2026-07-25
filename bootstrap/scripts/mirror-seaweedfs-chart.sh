#!/usr/bin/env bash
set -euo pipefail

chart_version="4.39.0"
upstream_digest="dbecd4c1f3cd5ae2eac62f3a0ccd92c05c1b05a20bd2b5f574c1e69dec440da2"
upstream_url="https://seaweedfs.github.io/seaweedfs/helm/seaweedfs-${chart_version}.tgz"
target="oci://ghcr.io/reefops"
temp_dir="$(mktemp -d)"
package="${temp_dir}/seaweedfs-${chart_version}.tgz"

cleanup() {
  find "${temp_dir}" -type f -exec sh -c ': > "$1"' _ {} \;
  find "${temp_dir}" -type f -delete
  rmdir "${temp_dir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

curl -fsSL "${upstream_url}" -o "${package}"
if [[ "$(shasum -a 256 "${package}" | awk '{print $1}')" != "${upstream_digest}" ]]; then
  echo "El paquete SeaweedFS no coincide con el digest upstream." >&2
  exit 1
fi

gh auth token |
  helm registry login ghcr.io --username "$(gh api user --jq .login)" \
    --password-stdin >/dev/null
helm push "${package}" "${target}"
