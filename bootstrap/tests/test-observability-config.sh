#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/observability-stack" \
  >"${temp_dir}/stack.yaml"
kubectl kustomize "${project_root}/platform/observability-config" \
  >"${temp_dir}/config.yaml"

if grep -F 'observability-' \
  "${project_root}/platform/kustomization.yaml" >/dev/null; then
  echo "El agregado platform no debe saltarse el orden stack/config." >&2
  exit 1
fi

monitor_count="$(
  yq eval '
    select(.kind == "ServiceMonitor" and
      .metadata.labels.release == "reefops-monitoring" and
      .metadata.labels."reefops.io/monitoring-instance" == "platform") |
    .metadata.name
  ' "${temp_dir}/config.yaml" |
    awk '/^(cert-manager|external-secrets|flux)$/ {count++} END {print count+0}'
)"
if [[ "${monitor_count}" -ne 3 ]]; then
  echo "Los tres monitores de plataforma no tienen ownership explícito." >&2
  exit 1
fi

rule="$(
  yq eval '
    select(.kind == "PrometheusRule" and
      .metadata.name == "reefops-platform")
  ' "${temp_dir}/config.yaml"
)"
if ! yq eval -e '
  .metadata.labels.release == "reefops-monitoring" and
  .metadata.labels."reefops.io/monitoring-instance" == "platform" and
  ([.spec.groups[].rules[].alert] |
    contains(["ReefOpsFluxReconciliationFailure",
      "ReefOpsCertificateExpiringSoon",
      "ReefOpsOpenBaoUnavailable",
      "ReefOpsExternalSecretsUnavailable",
      "ReefOpsExternalSecretNotReady",
      "ReefOpsSecretStoreNotReady"])) and
  ([.spec.groups[].rules[] |
    select(.alert == "ReefOpsOpenBaoUnavailable" or
      .alert == "ReefOpsExternalSecretsUnavailable") |
    .expr | test("absent\\(")] | length) == 2
  ' <<<"${rule}" >/dev/null; then
  echo "Las reglas ReefOps no cubren ownership o ausencia de series." >&2
  exit 1
fi

if yq eval '
  select(.kind == "Secret" or .kind == "ClusterRole" or
    .kind == "ClusterRoleBinding") |
  .metadata.name
  ' "${temp_dir}/config.yaml" |
  awk 'NF && $0 != "---" {found=1} END {exit found ? 0 : 1}'; then
  echo "La configuración de Grafana no debe crear Secrets ni RBAC cluster-wide." >&2
  exit 1
fi

grafana="$(
  yq eval '
    select(.kind == "Deployment" and .metadata.name == "grafana")
  ' "${temp_dir}/config.yaml"
)"
if ! yq eval -e '
  .spec.template.spec.automountServiceAccountToken == false and
  .spec.template.spec.securityContext.runAsNonRoot == true and
  .spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault" and
  (.spec.template.spec.containers[0].image |
    test("@sha256:[a-f0-9]{64}$")) and
  .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation ==
    false and
  .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem ==
    true and
  (.spec.template.spec.containers[0].securityContext.capabilities.drop |
    contains(["ALL"]))
  ' <<<"${grafana}" >/dev/null; then
  echo "Grafana no conserva ejecución sin credencial y hardening restringido." >&2
  exit 1
fi

release="$(
  yq eval '
    select(.kind == "HelmRelease" and
      .metadata.name == "reefops-monitoring")
  ' "${temp_dir}/stack.yaml"
)"
if ! yq eval -e '
  .spec.values.grafana.enabled == false and
  .spec.values.prometheusOperator.namespaces.releaseNamespace == true and
  (.spec.postRenderers[0].kustomize.patches |
    map(select(.target.kind == "ClusterRole" or
      .target.kind == "ClusterRoleBinding")) | length) == 2 and
  (.spec.values."kube-state-metrics".collectors |
    contains(["secrets"]) | not) and
  .spec.values."prometheus-node-exporter".hostNetwork == false and
  .spec.values."prometheus-node-exporter".hostPID == false and
  .spec.values."prometheus-node-exporter".hostRootFsMount.mountPropagation ==
    "None" and
  .spec.values.prometheusOperator.tls.enabled == false and
  .spec.values."prometheus-node-exporter".containerSecurityContext.allowPrivilegeEscalation ==
    false and
  (.spec.values."prometheus-node-exporter".containerSecurityContext.capabilities.drop |
    contains(["ALL"])) and
  .spec.values."prometheus-node-exporter".containerSecurityContext.seccompProfile.type ==
    "RuntimeDefault"
  ' <<<"${release}" >/dev/null; then
  echo "El stack no aplica least privilege o hardening del node-exporter." >&2
  exit 1
fi

if yq eval '
  select(.kind == "ClusterRole") |
  .rules[]? |
  select(.resources[]? == "secrets")
  ' "${temp_dir}/stack.yaml" |
  awk 'NF && $0 != "---" {found=1} END {exit found ? 0 : 1}'; then
  echo "La RBAC declarada no puede conceder Secrets a nivel clúster." >&2
  exit 1
fi

if ! yq eval -e '
  .spec.values.kubelet.enabled == false and
  .spec.values.prometheusOperator.kubeletService.enabled == false and
  .spec.values.prometheusOperator.kubeletEndpointsEnabled == false and
  .spec.values.prometheusOperator.kubeletEndpointSliceEnabled == false
  ' <<<"${release}" >/dev/null; then
  echo "El operador no debe gestionar recursos kubelet en kube-system." >&2
  exit 1
fi

verifier="${project_root}/bootstrap/scripts/verify-observability.sh"
for contract in \
  'reefops_operation_id' \
  'api/v2/silence' \
  'kubectl auth can-i' \
  'Ready=True' \
  'prometheus_history_preserved' \
  'grafana_state_preserved' \
  'record_evidence; then'; do
  if ! grep -F "${contract}" "${verifier}" >/dev/null; then
    echo "La aceptación no materializa el contrato: ${contract}" >&2
    exit 1
  fi
done

for server in otel-collector-otlp tempo-otlp; do
  yq eval -e "
    select(.kind == \"Server\" and .metadata.name == \"${server}\") |
    .spec.accessPolicy == \"all-authenticated\"
  " "${temp_dir}/config.yaml" >/dev/null
done
if grep -F 'kubectl -n flux-system wait' "${verifier}" >/dev/null; then
  echo "El verificador busca el HelmRelease en el namespace incorrecto." >&2
  exit 1
fi

policy_count="$(
  yq eval '
    select(.kind == "NetworkPolicy" and
      (.metadata.namespace == "reefops-observability" or
       .metadata.namespace == "reefops-node-observability")) |
    .metadata.name
  ' "${temp_dir}/config.yaml" |
    awk 'NF && $0 != "---" {count++} END {print count+0}'
)"
if [[ "${policy_count}" -lt 4 ]]; then
  echo "Faltan políticas de aislamiento de observabilidad." >&2
  exit 1
fi

for workload in tempo otel-collector; do
  yq eval -e "
    select(.kind == \"Deployment\" and .metadata.name == \"${workload}\") |
    .spec.template.spec.automountServiceAccountToken == false and
    .spec.template.spec.serviceAccountName == \"${workload}\" and
    .spec.template.metadata.annotations.\"linkerd.io/inject\" == \"enabled\" and
    (.spec.template.spec.containers[0].image |
      test(\"@sha256:[a-f0-9]{64}$\")) and
    .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
    .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false
  " "${temp_dir}/config.yaml" >/dev/null
done

yq eval -e '
  select(.kind == "MeshTLSAuthentication" and .metadata.name == "otel-collector-producers") |
  (.spec.identities | contains([
    "reefops-authorizer.reefops-identity.serviceaccount.identity.linkerd.cluster.local",
    "reefops-envoy-edge.reefops-gateway-system.serviceaccount.identity.linkerd.cluster.local"
  ]))
' "${temp_dir}/config.yaml" >/dev/null

yq eval -e '
  select(.kind == "MeshTLSAuthentication" and .metadata.name == "tempo-from-collector") |
  (.spec.identities | contains([
    "otel-collector.reefops-observability.serviceaccount.identity.linkerd.cluster.local"
  ]))
' "${temp_dir}/config.yaml" >/dev/null

if ! yq eval -e '
  select(.kind == "ConfigMap" and .metadata.name == "otel-collector-config") |
  (.data."config.yaml" | contains("attributes/redact")) and
  (.data."config.yaml" | contains("http.request.header.authorization")) and
  (.data."config.yaml" | contains("url.path")) and
  (.data."config.yaml" | contains("otlp/tempo"))
  ' "${temp_dir}/config.yaml" >/dev/null; then
  echo "El Collector no conserva el contrato de redacción y export OTLP interno." >&2
  exit 1
fi

if ! yq eval -e '
  select(.kind == "ConfigMap" and .metadata.name == "grafana-datasource") |
  (.data."prometheus.yaml" | contains("uid: tempo")) and
  (.data."prometheus.yaml" | contains("http://tempo:3200"))
  ' "${temp_dir}/config.yaml" >/dev/null; then
  echo "Grafana no tiene el datasource Tempo interno aprovisionado." >&2
  exit 1
fi

echo "RBAC, Grafana, reglas, monitores y red de observabilidad validados."
