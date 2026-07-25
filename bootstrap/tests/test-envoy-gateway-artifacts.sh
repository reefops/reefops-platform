#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/envoy-gateway-stack" \
  >"${temp_dir}/stack.yaml"

chart_digest="$(
  yq eval '
    select(.kind == "OCIRepository" and .metadata.name == "envoy-gateway") |
    .spec.ref.digest
  ' "${temp_dir}/stack.yaml"
)"
if [[ ! "${chart_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "El chart de Envoy Gateway no está fijado por digest." >&2
  exit 1
fi

pull_output="$(
  helm pull oci://docker.io/envoyproxy/gateway-helm \
    --version v1.8.3 --destination "${temp_dir}" 2>&1
)"
if ! grep -F "Digest: ${chart_digest}" <<<"${pull_output}" >/dev/null; then
  echo "El chart publicado no coincide con el digest declarado." >&2
  exit 1
fi

release="$(
  yq eval '
    select(.kind == "HelmRelease" and
      .metadata.name == "reefops-envoy-gateway")
  ' "${temp_dir}/stack.yaml"
)"
if ! yq eval -e '
  .metadata.namespace == "reefops-gateway-system" and
  .spec.chartRef.kind == "OCIRepository" and
  .spec.chartRef.name == "envoy-gateway" and
  .spec.chartRef.namespace == "flux-system" and
  .spec.install.crds == "CreateReplace" and
  .spec.upgrade.crds == "CreateReplace" and
  .spec.values.service.type == "ClusterIP" and
  .spec.values.topologyInjector.enabled == false and
  .spec.values.config.envoyGateway.provider.kubernetes.deploy.type ==
    "GatewayNamespace" and
  .spec.values.config.envoyGateway.provider.kubernetes.watch.type ==
    "Namespaces" and
  (.spec.values.config.envoyGateway.provider.kubernetes.watch.namespaces |
    length) == 1 and
  .spec.values.config.envoyGateway.provider.kubernetes.watch.namespaces[0] ==
    "reefops-gateway-system" and
  (.spec.values.global.images.envoyGateway.image |
    test("@sha256:[a-f0-9]{64}$"))
  ' <<<"${release}" >/dev/null; then
  echo "El HelmRelease no conserva digest, alcance inerte o namespace mode." >&2
  exit 1
fi

yq eval '.spec.values' <<<"${release}" >"${temp_dir}/values.yaml"
helm template reefops-envoy-gateway \
  "${temp_dir}/gateway-helm-v1.8.3.tgz" \
  --namespace reefops-gateway-system \
  --include-crds \
  --values "${temp_dir}/values.yaml" >"${temp_dir}/rendered.yaml"

for crd in \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  grpcroutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io \
  gatewayclasses.gateway.networking.k8s.io \
  listenersets.gateway.networking.k8s.io \
  tlsroutes.gateway.networking.k8s.io \
  backendtlspolicies.gateway.networking.k8s.io \
  envoyproxies.gateway.envoyproxy.io \
  securitypolicies.gateway.envoyproxy.io; do
  if ! yq eval -e \
    "select(.kind == \"CustomResourceDefinition\" and
      .metadata.name == \"${crd}\")" \
    "${temp_dir}/rendered.yaml" >/dev/null; then
    echo "El chart no contiene la CRD esperada ${crd}." >&2
    exit 1
  fi
done

if yq eval -e '
  select(.kind == "GatewayClass" or .kind == "Gateway" or
    .kind == "HTTPRoute" or .kind == "GRPCRoute" or
    .kind == "TCPRoute" or .kind == "TLSRoute" or
    .kind == "UDPRoute" or .kind == "ListenerSet" or
    .kind == "EnvoyProxy" or .kind == "Ingress")
  ' "${temp_dir}/rendered.yaml" >/dev/null 2>&1; then
  echo "El stack inerte no puede declarar entrada o rutas." >&2
  exit 1
fi

if yq eval -e '
  select(.kind == "MutatingWebhookConfiguration" and
    (.metadata.name | contains("envoy-gateway")))
  ' "${temp_dir}/rendered.yaml" >/dev/null 2>&1; then
  echo "El topology injector debe permanecer desactivado." >&2
  exit 1
fi

if yq eval -e '
  select(.kind == "Service" and
    (.spec.type == "LoadBalancer" or .spec.type == "NodePort"))
  ' "${temp_dir}/rendered.yaml" >/dev/null 2>&1; then
  echo "El chart renderiza un Service expuesto." >&2
  exit 1
fi

runtime_images="$(
  yq eval '
    select(.kind == "Deployment" or .kind == "Job") |
    .spec.template.spec.containers[]?.image
  ' "${temp_dir}/rendered.yaml" | sed '/^---$/d'
)"
while IFS= read -r image; do
  [[ -z "${image}" ]] && continue
  if [[ ! "${image}" =~ @sha256:[a-f0-9]{64}$ ]]; then
    echo "Imagen efectiva no fijada por digest: ${image}" >&2
    exit 1
  fi
done <<<"${runtime_images}"

ratelimit_image="$(
  yq eval \
    '.spec.values.global.images.ratelimit.image' <<<"${release}"
)"
if [[ ! "${ratelimit_image}" =~ @sha256:[a-f0-9]{64}$ ]]; then
  echo "La imagen latente de rate-limit no está fijada por digest." >&2
  exit 1
fi

noncompliant_containers="$(
  yq eval '
    select(.kind == "Deployment" or .kind == "Job") |
    .spec.template.spec.containers[] |
    select(
      .securityContext.runAsNonRoot != true or
      .securityContext.allowPrivilegeEscalation != false or
      .securityContext.seccompProfile.type != "RuntimeDefault" or
      (.securityContext.capabilities.drop | contains(["ALL"]) | not) or
      (.resources.requests.cpu | length == 0) or
      (.resources.requests.memory | length == 0) or
      (.resources.limits.cpu | length == 0) or
      (.resources.limits.memory | length == 0)
    ) |
    .name
  ' "${temp_dir}/rendered.yaml" | sed '/^---$/d'
)"
if [[ -n "${noncompliant_containers}" ]]; then
  echo "Los workloads no conservan hardening o límites." >&2
  exit 1
fi

if yq eval -e '
  select(.kind == "ClusterRole") |
  .rules[]? |
  select(.resources[]? == "secrets" or .resources[]? == "services" or
    .resources[]? == "httproutes" or .resources[]? == "gateways")
  ' "${temp_dir}/rendered.yaml" >/dev/null 2>&1; then
  echo "El modo namespaced concede datos sensibles a nivel clúster." >&2
  exit 1
fi

echo "Chart, CRD, imágenes, RBAC y alcance inerte de Envoy validados."
