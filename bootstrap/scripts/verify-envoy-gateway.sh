#!/usr/bin/env bash
set -Eeuo pipefail

namespace="reefops-gateway-system"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
actor="$(id -un)"
delegated_actor="${REEFOPS_DELEGATED_ACTOR:-}"
started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
evidence_file="${REEFOPS_ENVOY_GATEWAY_EVIDENCE_FILE:-${HOME}/.local/state/reefops/envoy-gateway/operations.jsonl}"
evidence_lock="${evidence_file}.lock"
phase="preflight"
failure_phase=""
error_message=""
result="failure"
local_revision=""
flux_revision=""
chart_digest=""
controller_image=""
platform_manifest_sha256=""
cluster_context=""
kubeconfig_user=""
cluster_id=""
resource_uids='{}'
reconciliations='{}'
checks='{}'
authorization_checks='[]'
prometheus_pid=""
evidence_chain_valid="true"
evidence_lock_acquired="false"

for value_name in correlation_id causation_id; do
  value="${!value_name}"
  if [[ ! "${value}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "${value_name} debe ser un UUID." >&2
    exit 2
  fi
done

stop_forward() {
  if [[ -n "${prometheus_pid}" ]]; then
    kill "${prometheus_pid}" >/dev/null 2>&1 || true
    wait "${prometheus_pid}" 2>/dev/null || true
    prometheus_pid=""
  fi
}

verify_evidence_chain() {
  local expected_previous="" line previous recorded_hash base_record computed_hash
  [[ ! -s "${evidence_file}" ]] && return
  while IFS= read -r line; do
    previous="$(jq -r '.previous_record_sha256 // empty' <<<"${line}")"
    recorded_hash="$(jq -r '.record_sha256 // empty' <<<"${line}")"
    base_record="$(jq -c 'del(.record_sha256)' <<<"${line}")"
    computed_hash="$(printf '%s' "${base_record}" |
      shasum -a 256 | awk '{print $1}')"
    if [[ "${previous}" != "${expected_previous}" ||
      "${computed_hash}" != "${recorded_hash}" ]]; then
      evidence_chain_valid="false"
      return 1
    fi
    expected_previous="${recorded_hash}"
  done <"${evidence_file}"
}

record_evidence() {
  local finished_at previous_hash base_record record_hash
  [[ "${evidence_chain_valid}" == "true" ]] || return 1
  finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "$(dirname "${evidence_file}")"
  chmod 700 "$(dirname "${evidence_file}")"
  previous_hash=""
  if [[ -s "${evidence_file}" ]]; then
    previous_hash="$(tail -n 1 "${evidence_file}" |
      jq -r '.record_sha256 // empty')"
  fi
  base_record="$(
    jq -cn \
      --arg operation_id "${operation_id}" \
      --arg correlation_id "${correlation_id}" \
      --arg causation_id "${causation_id}" \
      --arg actor "${actor}" \
      --arg delegated_actor "${delegated_actor}" \
      --arg kubeconfig_context "${cluster_context}" \
      --arg kubeconfig_user "${kubeconfig_user}" \
      --arg cluster_id "${cluster_id}" \
      --arg local_revision "${local_revision}" \
      --arg flux_revision "${flux_revision}" \
      --arg chart_digest "${chart_digest}" \
      --arg controller_image "${controller_image}" \
      --arg platform_manifest_sha256 "${platform_manifest_sha256}" \
      --arg started_at "${started_at}" \
      --arg finished_at "${finished_at}" \
      --arg result "${result}" \
      --arg failure_phase "${failure_phase}" \
      --arg error "${error_message}" \
      --arg previous_record_sha256 "${previous_hash}" \
      --argjson reconciliations "${reconciliations}" \
      --argjson resource_uids "${resource_uids}" \
      --argjson checks "${checks}" \
      --argjson authorization_checks "${authorization_checks}" \
      '{
        operation_id: $operation_id,
        correlation_id: $correlation_id,
        causation_id: $causation_id,
        actor: $actor,
        delegated_actor:
          (if $delegated_actor == "" then null else $delegated_actor end),
        authentication: {
          kubeconfig_context: $kubeconfig_context,
          kubeconfig_user: $kubeconfig_user
        },
        authorization: {
          mechanism: "kubectl-auth-can-i",
          checks: $authorization_checks
        },
        environment_id: "development",
        component: "envoy-gateway-inert-foundation",
        cluster_id: $cluster_id,
        local_revision: $local_revision,
        flux_revision: $flux_revision,
        reconciliations: $reconciliations,
        chart_digest: $chart_digest,
        controller_image: $controller_image,
        platform_manifest_sha256: $platform_manifest_sha256,
        resource_uids: $resource_uids,
        checks: $checks,
        restoration: "not-required",
        started_at: $started_at,
        finished_at: $finished_at,
        result: $result,
        failure_phase: (if $failure_phase == "" then null else $failure_phase end),
        error: (if $error == "" then null else $error end),
        previous_record_sha256:
          (if $previous_record_sha256 == "" then null
           else $previous_record_sha256 end)
      }'
  )"
  record_hash="$(printf '%s' "${base_record}" |
    shasum -a 256 | awk '{print $1}')"
  jq -c --arg record_sha256 "${record_hash}" \
    '. + {record_sha256: $record_sha256}' <<<"${base_record}" \
    >>"${evidence_file}"
  chmod 600 "${evidence_file}"
}

on_error() {
  failure_phase="${phase}"
  error_message="command failed: ${BASH_COMMAND}"
}

on_exit() {
  local status=$?
  trap - ERR EXIT
  stop_forward
  if [[ "${result}" != "success" && -z "${failure_phase}" ]]; then
    failure_phase="${phase}"
  fi
  if ! record_evidence; then
    echo "No se pudo persistir la evidencia obligatoria." >&2
    status=7
  fi
  if [[ "${evidence_lock_acquired}" == "true" ]]; then
    rmdir "${evidence_lock}" >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
trap on_error ERR
trap on_exit EXIT

for command in curl git jq kubectl rg shasum uuidgen yq; do
  command -v "${command}" >/dev/null
done
mkdir -p "$(dirname "${evidence_file}")"
chmod 700 "$(dirname "${evidence_file}")"
if ! mkdir "${evidence_lock}" 2>/dev/null; then
  echo "Ya existe una verificación de Envoy Gateway en curso." >&2
  trap - ERR EXIT
  exit 2
fi
evidence_lock_acquired="true"
if ! verify_evidence_chain; then
  echo "La cadena de evidencia de Envoy Gateway no es íntegra." >&2
  exit 2
fi

cluster_context="$(kubectl config current-context)"
if [[ "${cluster_context}" != "docker-desktop" ]]; then
  echo "El contexto Kubernetes no es docker-desktop." >&2
  exit 3
fi
kubeconfig_user="$(
  kubectl config view --minify -o jsonpath='{.contexts[0].context.user}'
)"
cluster_id="$(
  kubectl get namespace kube-system -o jsonpath='{.metadata.uid}'
)"
authorization_checks="$(
  for check in \
    "list gatewayclasses.gateway.networking.k8s.io cluster" \
    "list gateways.gateway.networking.k8s.io all" \
    "list httproutes.gateway.networking.k8s.io all" \
    "list grpcroutes.gateway.networking.k8s.io all" \
    "list listenersets.gateway.networking.k8s.io all" \
    "list tcproutes.gateway.networking.k8s.io all" \
    "list tlsroutes.gateway.networking.k8s.io all" \
    "list udproutes.gateway.networking.k8s.io all" \
    "list envoyproxies.gateway.envoyproxy.io all" \
    "list ingresses.networking.k8s.io all" \
    "list services all" \
    "list pods all" \
    "list deployments.apps all" \
    "list daemonsets.apps all" \
    "list statefulsets.apps all" \
    "list jobs.batch all"; do
    read -r verb resource scope <<<"${check}"
    if [[ "${scope}" == "cluster" ]]; then
      allowed="$(kubectl auth can-i "${verb}" "${resource}" --all-namespaces)"
    else
      allowed="$(kubectl auth can-i "${verb}" "${resource}" --all-namespaces)"
    fi
    jq -cn \
      --arg verb "${verb}" \
      --arg resource "${resource}" \
      --arg scope "${scope}" \
      --arg allowed "${allowed}" \
      '{
        verb: $verb,
        resource: $resource,
        scope: $scope,
        allowed: ($allowed == "yes")
      }'
  done | jq -sc .
)"
if jq -e 'any(.[]; .allowed == false)' \
  <<<"${authorization_checks}" >/dev/null; then
  echo "La identidad Kubernetes no puede probar todas las ausencias." >&2
  exit 3
fi
if [[ "$(
  kubectl get namespace "${namespace}" \
    -o jsonpath='{.metadata.labels.reefops\.io/environment}'
)" != "development" ]] ||
  [[ "$(
    kubectl -n "${namespace}" get configmap reefops-environment \
      -o jsonpath='{.data.environment_id}'
  )" != "development" ]]; then
  echo "El namespace de Envoy Gateway no pertenece a development." >&2
  exit 3
fi

if [[ -n "$(git status --porcelain)" ||
  "$(git branch --show-current)" != "main" ]]; then
  echo "La verificación exige main limpio." >&2
  exit 3
fi
local_revision="$(git rev-parse HEAD)"
flux_revision="$(
  kubectl -n flux-system get gitrepository reefops-platform \
    -o jsonpath='{.status.artifact.revision}'
)"
if [[ "${flux_revision}" != "sha1:${local_revision}" ]]; then
  echo "La revisión local no coincide exactamente con Flux." >&2
  exit 3
fi

for reconciliation in \
  reefops-development-environment \
  reefops-envoy-gateway-stack \
  reefops-envoy-gateway-config; do
  applied_revision="$(
    kubectl -n flux-system get kustomization "${reconciliation}" \
      -o jsonpath='{.status.lastAppliedRevision}'
  )"
  ready="$(
    kubectl -n flux-system get kustomization "${reconciliation}" -o json |
      jq -r '.status.conditions[]? |
        select(.type == "Ready") | .status'
  )"
  if [[ "${applied_revision}" != "sha1:${local_revision}" ||
    "${ready}" != "True" ]]; then
    echo "${reconciliation} no aplica la revisión exacta o no está Ready." >&2
    exit 3
  fi
  reconciliations="$(
    jq -c \
      --arg name "${reconciliation}" \
      --arg revision "${applied_revision}" \
      --arg ready "${ready}" \
      '. + {($name): {revision: $revision, ready: ($ready == "True")}}' \
      <<<"${reconciliations}"
  )"
done

chart_digest="$(
  yq eval '.spec.ref.digest' platform/envoy-gateway-stack/repository.yaml
)"
controller_image="$(
  yq eval \
    '.spec.values.global.images.envoyGateway.image' \
    platform/envoy-gateway-stack/release.yaml
)"
platform_manifest_sha256="$(
  {
    kubectl kustomize platform/envoy-gateway-stack
    kubectl kustomize platform/envoy-gateway-config
  } | shasum -a 256 | awk '{print $1}'
)"
oci_revision="$(
  kubectl -n flux-system get ocirepository envoy-gateway \
    -o jsonpath='{.status.artifact.revision}'
)"
if [[ "${oci_revision}" != "${chart_digest}" ]]; then
  echo "El chart desplegado no coincide con el digest declarado." >&2
  exit 3
fi

phase="readiness"
kubectl -n "${namespace}" wait \
  --for=condition=Ready helmrelease/reefops-envoy-gateway --timeout=10m
kubectl -n "${namespace}" rollout status deployment/envoy-gateway --timeout=5m

helm_release="$(
  kubectl -n "${namespace}" get helmrelease reefops-envoy-gateway -o json
)"
if ! jq -e \
  --arg chart_digest "${chart_digest}" '
  .status.observedGeneration == .metadata.generation and
  .status.history[0].status == "deployed" and
  .status.history[0].ociDigest == $chart_digest and
  .status.lastAttemptedRevision == .status.history[0].chartVersion
  ' <<<"${helm_release}" >/dev/null; then
  echo "El HelmRelease no ha observado y desplegado el digest actual." >&2
  exit 4
fi

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
  if [[ "$(
    kubectl get crd "${crd}" -o json |
      jq -r '.status.conditions[]? |
        select(.type == "Established") | .status'
  )" != "True" ]]; then
    echo "La CRD ${crd} no está Established." >&2
    exit 4
  fi
done

actual_image="$(
  kubectl -n "${namespace}" get deployment envoy-gateway \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
)"
if [[ "${actual_image}" != "${controller_image}" ||
  ! "${controller_image}" =~ @sha256:[a-f0-9]{64}$ ]]; then
  echo "La imagen efectiva del controlador no coincide con el digest." >&2
  exit 4
fi

phase="negative-exposure"
for resource in \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  grpcroutes.gateway.networking.k8s.io \
  listenersets.gateway.networking.k8s.io \
  tcproutes.gateway.networking.k8s.io \
  tlsroutes.gateway.networking.k8s.io \
  udproutes.gateway.networking.k8s.io \
  envoyproxies.gateway.envoyproxy.io \
  ingresses.networking.k8s.io; do
  resource_list="$(kubectl get "${resource}" -A -o json)"
  if [[ "$(jq '.items | length' <<<"${resource_list}")" -ne 0 ]]; then
    echo "La fundación inerte contiene ${resource}." >&2
    exit 4
  fi
done

services_json="$(kubectl get service -A -o json)"
if jq -e '.items[] |
  select(.spec.type == "LoadBalancer" or .spec.type == "NodePort" or
    ((.spec.externalIPs // []) | length > 0) or
    (.metadata.labels["gateway.envoyproxy.io/owning-gateway-name"] != null) or
    (.metadata.labels["gateway.envoyproxy.io/owning-gateway-namespace"] != null)
  )' \
  <<<"${services_json}" >/dev/null; then
  echo "Existe un Service LoadBalancer, NodePort o con externalIPs." >&2
  exit 4
fi

controller_service="$(
  kubectl -n "${namespace}" get service envoy-gateway -o json
)"
if ! jq -e '
  .spec.type == "ClusterIP" and
  ((.spec.externalIPs // []) | length == 0)
  ' <<<"${controller_service}" >/dev/null; then
  echo "El Service del controlador no es estrictamente interno." >&2
  exit 4
fi

namespace_workloads="$(
  kubectl -n "${namespace}" get \
    deployment,daemonset,statefulset,job,cronjob -o json
)"
if ! jq -e '
  ([.items[] | select(.kind == "Deployment") | .metadata.name] ==
    ["envoy-gateway"]) and
  ([.items[] | select(.kind == "DaemonSet" or .kind == "StatefulSet" or
    .kind == "CronJob")] | length == 0) and
  ([.items[] | select(.kind == "Job" and
    (.metadata.name | startswith(
      "reefops-envoy-gateway-gateway-helm-certgen") | not))] | length == 0)
  ' <<<"${namespace_workloads}" >/dev/null; then
  echo "Existe un workload inesperado en el namespace del controlador." >&2
  exit 4
fi

pods_json="$(kubectl get pods -A -o json)"
if jq -e '
  .items[] |
  select(
    (.metadata.labels["gateway.envoyproxy.io/owning-gateway-name"] != null) or
    (.metadata.labels["gateway.envoyproxy.io/owning-gateway-namespace"] != null)
  )
  ' <<<"${pods_json}" >/dev/null; then
  echo "Existe un pod gestionado por un Gateway antes de la segunda puerta." >&2
  exit 4
fi
if jq -e \
  --arg namespace "${namespace}" '
  .items[] |
  select(.metadata.namespace == $namespace) |
  select(
    (.metadata.labels["control-plane"] != "envoy-gateway") and
    (.metadata.labels.app != "certgen")
  )
  ' <<<"${pods_json}" >/dev/null; then
  echo "Existe un pod inesperado en el namespace de Envoy Gateway." >&2
  exit 4
fi
if jq -e '
  .items[] |
  select(.metadata.namespace == "reefops-gateway-system") |
  select(.spec.hostNetwork == true or
    any(.spec.containers[]?.ports[]?; .hostPort != null and .hostPort > 0))
  ' <<<"${pods_json}" >/dev/null; then
  echo "Existe un pod con hostNetwork o hostPort." >&2
  exit 4
fi

phase="metrics"
kubectl -n reefops-observability port-forward \
  service/reefops-monitoring-prometheus 19090:9090 >/dev/null 2>&1 &
prometheus_pid=$!
metrics_ready="false"
for _ in {1..180}; do
  if curl --fail --silent \
    http://127.0.0.1:19090/api/v1/targets?state=active |
    jq -e '.data.activeTargets[] |
      select(.scrapePool |
        contains("serviceMonitor/reefops-observability/envoy-gateway")) |
      select(.health == "up")' >/dev/null 2>&1; then
    metrics_ready="true"
    break
  fi
  sleep 1
done
stop_forward
if [[ "${metrics_ready}" != "true" ]]; then
  echo "Prometheus no descubre las métricas de Envoy Gateway." >&2
  exit 4
fi

resource_uids="$(
  jq -cn \
    --arg deployment "$(
      kubectl -n "${namespace}" get deployment envoy-gateway \
        -o jsonpath='{.metadata.uid}'
    )" \
    --arg helmrelease "$(
      kubectl -n "${namespace}" get helmrelease reefops-envoy-gateway \
        -o jsonpath='{.metadata.uid}'
    )" \
    --arg service_monitor "$(
      kubectl -n reefops-observability get servicemonitor envoy-gateway \
        -o jsonpath='{.metadata.uid}'
    )" \
    '{
      deployment: $deployment,
      helmrelease: $helmrelease,
      service_monitor: $service_monitor
    }'
)"
checks="$(
  jq -cn '{
    crds_established: true,
    controller_ready: true,
    controller_digest_pinned: true,
    metrics_discovered: true,
    gateways_absent: true,
    routes_absent: true,
    ingress_absent: true,
    envoy_data_plane_absent: true,
    exposed_services_absent: true
  }'
)"

phase="complete"
result="success"
echo "Fundación inerte de Envoy Gateway verificada sin entrada expuesta."
