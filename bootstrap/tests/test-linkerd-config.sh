#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
for root in linkerd-certificates linkerd-crds linkerd-cni linkerd-control-plane; do
  kubectl kustomize "${project_root}/platform/${root}" >"${temp_dir}/${root}.yaml"
done

if ! yq eval -e '
  select(.kind == "Certificate" and .metadata.name == "linkerd-trust-anchor") |
  .metadata.namespace == "cert-manager" and .spec.isCA == true and
  .spec.privateKey.algorithm == "ECDSA" and
  .spec.privateKey.rotationPolicy == "Always"
' "${temp_dir}/linkerd-certificates.yaml" >/dev/null ||
  ! yq eval -e '
  select(.kind == "Certificate" and .metadata.name == "linkerd-identity-issuer") |
  .metadata.namespace == "linkerd" and .spec.duration == "48h" and
  .spec.renewBefore == "25h" and
  .spec.privateKey.rotationPolicy == "Always"
' "${temp_dir}/linkerd-certificates.yaml" >/dev/null; then
  echo "Los certificados Linkerd no conservan CA, rotación o duración." >&2
  exit 1
fi

if [[ "$(yq eval 'select(.kind == "OCIRepository") | .metadata.name' \
  "${temp_dir}/linkerd-crds.yaml" | sed '/^---$/d' | awk 'NF {n++} END {print n+0}')" -ne 2 ]]; then
  echo "Linkerd no contiene sus dos fuentes OCI separadas." >&2
  exit 1
fi

yq eval -e '
  select(.kind == "HelmRelease" and .metadata.name == "linkerd-cni") |
  .metadata.namespace == "linkerd-cni" and
  .spec.chartRef.name == "linkerd2-cni" and
  (.spec.values.image.version |
    test("^v1\\.7\\.0-alpha\\.1@sha256:[a-f0-9]{64}$")) and
  .spec.values.privileged == false
' "${temp_dir}/linkerd-cni.yaml" >/dev/null || {
  echo "Linkerd CNI perdió digest, aislamiento o mínimo privilegio." >&2
  exit 1
}

yq eval -e '
  select(.kind == "HelmRelease" and .metadata.name == "linkerd-control-plane") |
  .spec.chartRef.kind == "OCIRepository" and
  .spec.chartRef.name == "linkerd-control-plane" and
  .spec.values.identity.externalCA == true and
  .spec.values.cniEnabled == true and
  .spec.values.identity.issuer.scheme == "kubernetes.io/tls" and
  (.spec.values.controllerImageVersion |
    test("^edge-26\\.7\\.2@sha256:[a-f0-9]{64}$")) and
  (.spec.values.proxy.image.version |
    test("^edge-26\\.7\\.2@sha256:[a-f0-9]{64}$")) and
  .spec.values.controllerReplicas == 1 and
  .spec.values.webhookFailurePolicy == "Fail"
' "${temp_dir}/linkerd-control-plane.yaml" >/dev/null || {
  echo "Linkerd incumple versión, digests, CA externa o fallo cerrado." >&2
  exit 1
}

echo "Linkerd, certificados rotables y digests validados."
