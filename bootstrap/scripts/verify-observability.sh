#!/usr/bin/env bash
set -Eeuo pipefail

namespace="reefops-observability"
node_namespace="reefops-node-observability"
rule_name="reefops-observability-smoke-test"
operation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
correlation_id="${REEFOPS_CORRELATION_ID:-${operation_id}}"
causation_id="${REEFOPS_CAUSATION_ID:-${operation_id}}"
actor="$(id -un)"
delegated_actor="${REEFOPS_DELEGATED_ACTOR:-}"
started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
evidence_file="${REEFOPS_OBSERVABILITY_EVIDENCE_FILE:-${HOME}/.local/state/reefops/observability/operations.jsonl}"
evidence_lock="${evidence_file}.lock"
phase="preflight"
failure_phase=""
error_message=""
result="failure"
restoration="not-required"
local_revision=""
flux_revision=""
chart_digest=""
platform_manifest_sha256=""
image_digests='[]'
cluster_context=""
kubeconfig_user=""
authorization_checks='[]'
cluster_id=""
resource_uids='{}'
pvc_uids_before='[]'
pvc_uids_after='[]'
prometheus_pid=""
alertmanager_pid=""
grafana_pid=""
rule_created="false"
evidence_chain_valid="true"
evidence_lock_acquired="false"
synthetic_active="false"
synthetic_received="false"
synthetic_cleared="false"
prometheus_restarted="false"
alertmanager_restarted="false"
grafana_restarted="false"
prometheus_history_preserved="false"
alertmanager_state_preserved="false"
grafana_state_preserved="false"
silence_id=""
silence_deleted="false"
prometheus_history_before=""
grafana_state_before=""

for value_name in correlation_id causation_id; do
  value="${!value_name}"
  if [[ ! "${value}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "${value_name} debe ser un UUID." >&2
    exit 2
  fi
done

stop_forwards() {
  for pid in "${prometheus_pid}" "${alertmanager_pid}" "${grafana_pid}"; do
    if [[ -n "${pid}" ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  prometheus_pid=""
  alertmanager_pid=""
  grafana_pid=""
}

cleanup() {
  stop_forwards
  if [[ "${rule_created}" == "true" ]]; then
    if kubectl -n "${namespace}" delete prometheusrule "${rule_name}" \
      --ignore-not-found --wait=true >/dev/null 2>&1; then
      restoration="success"
    else
      restoration="failure"
    fi
    rule_created="false"
  fi
  if [[ -n "${silence_id}" && "${silence_deleted}" != "true" ]]; then
    restoration="failure"
    kubectl -n "${namespace}" port-forward \
      service/reefops-monitoring-alertmanager 19093:9093 \
      >/dev/null 2>&1 &
    alertmanager_pid=$!
    for _ in {1..20}; do
      if curl --fail --silent \
        -X DELETE "http://127.0.0.1:19093/api/v2/silence/${silence_id}" \
        >/dev/null 2>&1; then
        silence_state="$(
          curl --fail --silent \
            "http://127.0.0.1:19093/api/v2/silence/${silence_id}" |
            jq -r '.status.state'
        )"
      else
        silence_state="active"
      fi
      if [[ "${silence_state}" != "active" ]]; then
        silence_deleted="true"
        restoration="success"
        break
      fi
      sleep 1
    done
    stop_forwards
  fi
}

record_evidence() {
  local finished_at previous_hash base_record record_hash
  finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if [[ "${evidence_chain_valid}" != "true" ]]; then
    echo "No se añade evidencia a una cadena inválida." >&2
    return 1
  fi
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
      --arg environment_id "development" \
      --arg component "minimum-observability" \
      --arg cluster_id "${cluster_id}" \
      --arg local_revision "${local_revision}" \
      --arg flux_revision "${flux_revision}" \
      --arg chart_digest "${chart_digest}" \
      --arg platform_manifest_sha256 "${platform_manifest_sha256}" \
      --arg started_at "${started_at}" \
      --arg finished_at "${finished_at}" \
      --arg result "${result}" \
      --arg failure_phase "${failure_phase}" \
      --arg error "${error_message}" \
      --arg restoration "${restoration}" \
      --arg previous_record_sha256 "${previous_hash}" \
      --argjson image_digests "${image_digests}" \
      --argjson resource_uids "${resource_uids}" \
      --argjson pvc_uids_before "${pvc_uids_before}" \
      --argjson pvc_uids_after "${pvc_uids_after}" \
      --argjson synthetic_active "${synthetic_active}" \
      --argjson synthetic_received "${synthetic_received}" \
      --argjson synthetic_cleared "${synthetic_cleared}" \
      --argjson prometheus_restarted "${prometheus_restarted}" \
      --argjson alertmanager_restarted "${alertmanager_restarted}" \
      --argjson grafana_restarted "${grafana_restarted}" \
      --argjson authorization_checks "${authorization_checks}" \
      --argjson prometheus_history_preserved "${prometheus_history_preserved}" \
      --argjson alertmanager_state_preserved "${alertmanager_state_preserved}" \
      --argjson grafana_state_preserved "${grafana_state_preserved}" \
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
        environment_id: $environment_id,
        component: $component,
        cluster_id: $cluster_id,
        local_revision: $local_revision,
        flux_revision: $flux_revision,
        chart_digest: $chart_digest,
        platform_manifest_sha256: $platform_manifest_sha256,
        image_digests: $image_digests,
        resource_uids: $resource_uids,
        pvc_uids_before: $pvc_uids_before,
        pvc_uids_after: $pvc_uids_after,
        synthetic_alert: {
          name: "ReefOpsObservabilitySynthetic",
          active: $synthetic_active,
          received_by_alertmanager: $synthetic_received,
          cleared: $synthetic_cleared
        },
        restart_verification: {
          prometheus: $prometheus_restarted,
          alertmanager: $alertmanager_restarted,
          grafana: $grafana_restarted,
          pvc_identity_preserved: ($pvc_uids_before == $pvc_uids_after),
          prometheus_history_preserved: $prometheus_history_preserved,
          alertmanager_state_preserved: $alertmanager_state_preserved,
          grafana_state_preserved: $grafana_state_preserved
        },
        restoration: $restoration,
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

verify_evidence_chain() {
  local expected_previous="" line previous recorded_hash base_record computed_hash
  [[ ! -s "${evidence_file}" ]] && return
  while IFS= read -r line; do
    previous="$(jq -r '.previous_record_sha256 // empty' <<<"${line}")"
    recorded_hash="$(jq -r '.record_sha256 // empty' <<<"${line}")"
    if [[ "${previous}" != "${expected_previous}" ||
      ! "${recorded_hash}" =~ ^[a-f0-9]{64}$ ]]; then
      evidence_chain_valid="false"
      return 1
    fi
    base_record="$(jq -c 'del(.record_sha256)' <<<"${line}")"
    computed_hash="$(printf '%s' "${base_record}" |
      shasum -a 256 | awk '{print $1}')"
    if [[ "${computed_hash}" != "${recorded_hash}" ]]; then
      evidence_chain_valid="false"
      return 1
    fi
    expected_previous="${recorded_hash}"
  done <"${evidence_file}"
}

on_error() {
  failure_phase="${phase}"
  error_message="command failed: ${BASH_COMMAND}"
}

on_exit() {
  local status=$?
  trap - ERR EXIT
  cleanup
  if [[ "${restoration}" == "failure" ]]; then
    result="failure"
    failure_phase="restoration"
    error_message="synthetic state cleanup failed"
    status=8
  fi
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

for command in curl git jq kubectl shasum uuidgen yq; do
  command -v "${command}" >/dev/null
done
mkdir -p "$(dirname "${evidence_file}")"
chmod 700 "$(dirname "${evidence_file}")"
if ! mkdir "${evidence_lock}" 2>/dev/null; then
  echo "Ya existe una verificación de observabilidad en curso." >&2
  trap - ERR EXIT
  exit 2
fi
evidence_lock_acquired="true"
if ! verify_evidence_chain; then
  echo "La cadena de evidencia de observabilidad no es íntegra." >&2
  exit 2
fi

cluster_context="$(kubectl config current-context)"
if [[ "${cluster_context}" != "docker-desktop" ]]; then
  echo "El contexto Kubernetes no es docker-desktop." >&2
  exit 3
fi
kubeconfig_user="$(
  kubectl config view --minify \
    -o jsonpath='{.contexts[0].context.user}'
)"
authorization_checks="$(
  for check in \
    "create prometheusrules.monitoring.coreos.com ${namespace}" \
    "delete prometheusrules.monitoring.coreos.com ${namespace}" \
    "patch deployments.apps ${namespace}" \
    "patch statefulsets.apps ${namespace}"; do
    read -r verb resource checked_namespace <<<"${check}"
    allowed="$(
      kubectl auth can-i "${verb}" "${resource}" \
        --namespace "${checked_namespace}"
    )"
    jq -cn \
      --arg verb "${verb}" \
      --arg resource "${resource}" \
      --arg namespace "${checked_namespace}" \
      --arg allowed "${allowed}" \
      '{
        verb: $verb,
        resource: $resource,
        namespace: $namespace,
        allowed: ($allowed == "yes")
      }'
  done | jq -sc .
)"
if jq -e 'any(.[]; .allowed == false)' \
  <<<"${authorization_checks}" >/dev/null; then
  echo "La identidad Kubernetes no autoriza la aceptación completa." >&2
  exit 3
fi
cluster_id="$(
  kubectl get namespace kube-system \
    -o jsonpath='{.metadata.uid}'
)"
for checked_namespace in "${namespace}" "${node_namespace}"; do
  environment="$(
    kubectl get namespace "${checked_namespace}" \
      -o jsonpath='{.metadata.labels.reefops\.io/environment}'
  )"
  if [[ "${environment}" != "development" ]]; then
    echo "${checked_namespace} no pertenece a development." >&2
    exit 3
  fi
done

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
  reefops-observability-stack \
  reefops-observability-config; do
  applied_revision="$(
    kubectl -n flux-system get kustomization "${reconciliation}" \
      -o jsonpath='{.status.lastAppliedRevision}'
  )"
  if [[ "${applied_revision}" != "sha1:${local_revision}" ]]; then
    echo "${reconciliation} no aplica la revisión local." >&2
    exit 3
  fi
  ready="$(
    kubectl -n flux-system get kustomization "${reconciliation}" \
      -o json |
      jq -r '.status.conditions[]? |
        select(.type == "Ready") | .status'
  )"
  if [[ "${ready}" != "True" ]]; then
    echo "${reconciliation} no está Ready=True." >&2
    exit 3
  fi
done
chart_digest="$(
  yq eval '.spec.ref.digest' \
    platform/observability-stack/repository.yaml
)"
platform_manifest_sha256="$(
  {
    kubectl kustomize platform/observability-stack
    kubectl kustomize platform/observability-config
  } | shasum -a 256 | awk '{print $1}'
)"
image_digests="$(
  rg -o 'sha256:[a-f0-9]{64}' \
    platform/observability-stack/release.yaml \
    platform/observability-config/grafana.yaml |
    awk -F: '{print $NF}' |
    sort -u |
    jq -Rsc 'split("\n") | map(select(length > 0) | "sha256:" + .)'
)"
oci_revision="$(
  kubectl -n flux-system get ocirepository kube-prometheus-stack \
    -o jsonpath='{.status.artifact.revision}'
)"
if [[ "${oci_revision}" != *"${chart_digest}"* ]]; then
  echo "El chart desplegado no coincide con el digest declarado." >&2
  exit 3
fi

phase="readiness"
kubectl -n flux-system wait \
  --for=condition=Ready helmrelease/reefops-monitoring --timeout=10m
kubectl -n "${namespace}" rollout status deployment/grafana --timeout=5m
kubectl -n "${namespace}" rollout status \
  statefulset/prometheus-reefops-monitoring-prometheus --timeout=5m
kubectl -n "${namespace}" rollout status \
  statefulset/alertmanager-reefops-monitoring-alertmanager --timeout=5m
kubectl -n "${node_namespace}" rollout status \
  daemonset/reefops-monitoring-prometheus-node-exporter --timeout=5m

pvc_uids_before="$(
  kubectl -n "${namespace}" get pvc -o json |
    jq -c '[.items[] | {name: .metadata.name, uid: .metadata.uid}] |
      sort_by(.name)'
)"
if [[ "$(jq 'length' <<<"${pvc_uids_before}")" -lt 3 ]]; then
  echo "Faltan PVC de Prometheus, Alertmanager o Grafana." >&2
  exit 4
fi
if kubectl -n "${namespace}" get ingress \
  -o name 2>/dev/null | grep -q .; then
  echo "Observabilidad no debe crear Ingress en esta fase." >&2
  exit 4
fi
if kubectl -n "${namespace}" get service -o json |
  jq -e '.items[] | select(.spec.type != "ClusterIP")' >/dev/null; then
  echo "Observabilidad contiene un Service no interno." >&2
  exit 4
fi

start_forwards() {
  kubectl -n "${namespace}" port-forward \
    service/reefops-monitoring-prometheus 19090:9090 \
    >/dev/null 2>&1 &
  prometheus_pid=$!
  kubectl -n "${namespace}" port-forward \
    service/reefops-monitoring-alertmanager 19093:9093 \
    >/dev/null 2>&1 &
  alertmanager_pid=$!
  kubectl -n "${namespace}" port-forward service/grafana 13000:3000 \
    >/dev/null 2>&1 &
  grafana_pid=$!
  for _ in {1..60}; do
    if curl --fail --silent http://127.0.0.1:19090/-/ready >/dev/null &&
      curl --fail --silent http://127.0.0.1:19093/-/ready >/dev/null &&
      curl --fail --silent http://127.0.0.1:13000/api/health >/dev/null; then
      return
    fi
    sleep 1
  done
  echo "Las APIs de observabilidad no quedaron disponibles." >&2
  return 1
}

phase="synthetic-alert"
start_forwards
if [[ "$(
  curl --fail --silent --get \
    --data-urlencode 'query=count(up == 1)' \
    http://127.0.0.1:19090/api/v1/query |
    jq -r '.data.result[0].value[1] // "0"' |
    awk '{print int($1)}'
)" -lt 1 ]]; then
  echo "Prometheus no tiene targets preparados." >&2
  exit 5
fi
orphaned_prometheus="$(
  curl --fail --silent http://127.0.0.1:19090/api/v1/alerts |
    jq '[.data.alerts[]? |
      select(.labels.alertname == "ReefOpsObservabilitySynthetic")] |
      length'
)"
orphaned_alertmanager="$(
  curl --fail --silent \
    'http://127.0.0.1:19093/api/v2/alerts?active=true' |
    jq '[.[] |
      select(.labels.alertname == "ReefOpsObservabilitySynthetic")] |
      length'
)"
if [[ "${orphaned_prometheus}" -ne 0 ||
  "${orphaned_alertmanager}" -ne 0 ]]; then
  echo "Existe una alerta sintética huérfana; se aborta la aceptación." >&2
  exit 5
fi

kubectl apply -f - >/dev/null <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ${rule_name}
  namespace: ${namespace}
  labels:
    release: reefops-monitoring
    reefops.io/monitoring-instance: platform
  annotations:
    reefops.io/operation-id: ${operation_id}
    reefops.io/correlation-id: ${correlation_id}
    reefops.io/causation-id: ${causation_id}
spec:
  groups:
    - name: reefops.acceptance
      rules:
        - alert: ReefOpsObservabilitySynthetic
          expr: vector(1)
          for: 0m
          labels:
            severity: info
          annotations:
            summary: ReefOps observability acceptance signal
            reefops_operation_id: ${operation_id}
            reefops_correlation_id: ${correlation_id}
            reefops_causation_id: ${causation_id}
YAML
rule_created="true"

for _ in {1..60}; do
  prometheus_active="$(
    curl --fail --silent http://127.0.0.1:19090/api/v1/alerts |
      jq --arg operation_id "${operation_id}" \
        '[.data.alerts[]? |
          select(.labels.alertname == "ReefOpsObservabilitySynthetic" and
            .annotations.reefops_operation_id == $operation_id)] | length'
  )"
  alertmanager_active="$(
    curl --fail --silent \
      'http://127.0.0.1:19093/api/v2/alerts?active=true' |
      jq --arg operation_id "${operation_id}" \
        '[.[] |
          select(.labels.alertname == "ReefOpsObservabilitySynthetic" and
            .annotations.reefops_operation_id == $operation_id)] | length'
  )"
  if [[ "${prometheus_active}" -gt 0 && "${alertmanager_active}" -gt 0 ]]; then
    break
  fi
  sleep 2
done
if [[ "${prometheus_active:-0}" -lt 1 ||
  "${alertmanager_active:-0}" -lt 1 ]]; then
  echo "La alerta sintética no llegó a Prometheus y Alertmanager." >&2
  exit 5
fi
synthetic_active="true"
synthetic_received="true"

kubectl -n "${namespace}" delete prometheusrule "${rule_name}" --wait=true \
  >/dev/null
rule_created="false"
restoration="success"
for _ in {1..60}; do
  prometheus_active="$(
    curl --fail --silent http://127.0.0.1:19090/api/v1/alerts |
      jq --arg operation_id "${operation_id}" \
        '[.data.alerts[]? |
          select(.labels.alertname == "ReefOpsObservabilitySynthetic" and
            .annotations.reefops_operation_id == $operation_id)] | length'
  )"
  alertmanager_active="$(
    curl --fail --silent \
      'http://127.0.0.1:19093/api/v2/alerts?active=true' |
      jq --arg operation_id "${operation_id}" \
        '[.[] |
          select(.labels.alertname == "ReefOpsObservabilitySynthetic" and
            .annotations.reefops_operation_id == $operation_id)] | length'
  )"
  [[ "${prometheus_active}" -eq 0 &&
    "${alertmanager_active}" -eq 0 ]] && break
  sleep 2
done
if [[ "${prometheus_active}" -ne 0 ||
  "${alertmanager_active}" -ne 0 ]]; then
  echo "La alerta sintética no se resolvió en ambos sistemas." >&2
  exit 5
fi
synthetic_cleared="true"

phase="persistence-baseline"
history_end="$(( $(date +%s) - 30 ))"
history_start="$(( history_end - 120 ))"
prometheus_history_before="$(
  curl --fail --silent --get \
    --data-urlencode 'query=up' \
    --data-urlencode "start=${history_start}" \
    --data-urlencode "end=${history_end}" \
    --data-urlencode 'step=15' \
    http://127.0.0.1:19090/api/v1/query_range |
    jq -c '.data.result | sort_by(.metric.__name__, .metric.job,
      .metric.instance)'
)"
if [[ "$(jq 'length' <<<"${prometheus_history_before}")" -lt 1 ]]; then
  echo "No hay muestras históricas para probar persistencia." >&2
  exit 6
fi
grafana_state_before="$(
  {
    curl --fail --silent \
      http://127.0.0.1:13000/api/dashboards/uid/reefops-platform |
      jq -c '{dashboard: (.dashboard | {uid, title, version})}'
    curl --fail --silent \
      http://127.0.0.1:13000/api/datasources/uid/prometheus |
      jq -c '{datasource: {uid, type, url}}'
  } | jq -sc 'add'
)"
grafana_query_count="$(
  curl --fail --silent --get \
    --data-urlencode 'query=count(up == 1)' \
    http://127.0.0.1:13000/api/datasources/proxy/uid/prometheus/api/v1/query |
    jq -r '.data.result[0].value[1] // "0"' |
    awk '{print int($1)}'
)"
if [[ "${grafana_query_count}" -lt 1 ]]; then
  echo "Grafana no consulta correctamente su datasource Prometheus." >&2
  exit 6
fi
silence_payload="$(
  jq -cn \
    --arg starts_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg ends_at "$(date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg created_by "${actor}" \
    --arg comment "ReefOps acceptance ${operation_id}" \
    --arg operation_id "${operation_id}" \
    '{
      matchers: [{
        name: "reefops_acceptance_operation",
        value: $operation_id,
        isRegex: false,
        isEqual: true
      }],
      startsAt: $starts_at,
      endsAt: $ends_at,
      createdBy: $created_by,
      comment: $comment
    }'
)"
silence_id="$(
  curl --fail --silent \
    -H 'Content-Type: application/json' \
    -X POST \
    --data "${silence_payload}" \
    http://127.0.0.1:19093/api/v2/silences |
    jq -er '.silenceID'
)"
unset silence_payload

phase="restart-persistence"
stop_forwards
kubectl -n "${namespace}" rollout restart deployment/grafana \
  statefulset/prometheus-reefops-monitoring-prometheus \
  statefulset/alertmanager-reefops-monitoring-alertmanager >/dev/null
kubectl -n "${namespace}" rollout status deployment/grafana --timeout=5m
grafana_restarted="true"
kubectl -n "${namespace}" rollout status \
  statefulset/prometheus-reefops-monitoring-prometheus --timeout=5m
prometheus_restarted="true"
kubectl -n "${namespace}" rollout status \
  statefulset/alertmanager-reefops-monitoring-alertmanager --timeout=5m
alertmanager_restarted="true"

pvc_uids_after="$(
  kubectl -n "${namespace}" get pvc -o json |
    jq -c '[.items[] | {name: .metadata.name, uid: .metadata.uid}] |
      sort_by(.name)'
)"
if [[ "${pvc_uids_before}" != "${pvc_uids_after}" ]]; then
  echo "Cambió la identidad de los PVC durante el reinicio." >&2
  exit 6
fi
start_forwards
curl --fail --silent http://127.0.0.1:13000/api/health >/dev/null
curl --fail --silent http://127.0.0.1:19090/-/ready >/dev/null
curl --fail --silent http://127.0.0.1:19093/-/ready >/dev/null
prometheus_history_after="$(
  curl --fail --silent --get \
    --data-urlencode 'query=up' \
    --data-urlencode "start=${history_start}" \
    --data-urlencode "end=${history_end}" \
    --data-urlencode 'step=15' \
    http://127.0.0.1:19090/api/v1/query_range |
    jq -c '.data.result | sort_by(.metric.__name__, .metric.job,
      .metric.instance)'
)"
if [[ "${prometheus_history_before}" != "${prometheus_history_after}" ]]; then
  echo "Las muestras históricas de Prometheus no sobrevivieron al reinicio." >&2
  exit 6
fi
prometheus_history_preserved="true"

grafana_state_after="$(
  {
    curl --fail --silent \
      http://127.0.0.1:13000/api/dashboards/uid/reefops-platform |
      jq -c '{dashboard: (.dashboard | {uid, title, version})}'
    curl --fail --silent \
      http://127.0.0.1:13000/api/datasources/uid/prometheus |
      jq -c '{datasource: {uid, type, url}}'
  } | jq -sc 'add'
)"
if [[ "${grafana_state_before}" != "${grafana_state_after}" ]]; then
  echo "El estado aprovisionado de Grafana cambió tras el reinicio." >&2
  exit 6
fi
grafana_query_count="$(
  curl --fail --silent --get \
    --data-urlencode 'query=count(up == 1)' \
    http://127.0.0.1:13000/api/datasources/proxy/uid/prometheus/api/v1/query |
    jq -r '.data.result[0].value[1] // "0"' |
    awk '{print int($1)}'
)"
if [[ "${grafana_query_count}" -lt 1 ]]; then
  echo "Grafana perdió acceso a Prometheus tras el reinicio." >&2
  exit 6
fi
grafana_state_preserved="true"

silence_status="$(
  curl --fail --silent \
    "http://127.0.0.1:19093/api/v2/silence/${silence_id}" |
    jq -r '.status.state'
)"
if [[ "${silence_status}" != "active" ]]; then
  echo "El estado sintético de Alertmanager no sobrevivió al reinicio." >&2
  exit 6
fi
alertmanager_state_preserved="true"
curl --fail --silent \
  -X DELETE "http://127.0.0.1:19093/api/v2/silence/${silence_id}" \
  >/dev/null
for _ in {1..20}; do
  silence_status="$(
    curl --fail --silent \
      "http://127.0.0.1:19093/api/v2/silence/${silence_id}" |
      jq -r '.status.state'
  )"
  [[ "${silence_status}" != "active" ]] && {
    silence_deleted="true"
    break
  }
  sleep 1
done
if [[ "${silence_deleted}" != "true" ]]; then
  restoration="failure"
  echo "No se pudo retirar el silencio sintético." >&2
  exit 6
fi

resource_uids="$(
  kubectl -n "${namespace}" get \
    deployment/grafana \
    statefulset/prometheus-reefops-monitoring-prometheus \
    statefulset/alertmanager-reefops-monitoring-alertmanager \
    -o json |
    jq -c '[.items[] | {
      kind: .kind,
      name: .metadata.name,
      uid: .metadata.uid
    }]'
)"

phase="complete"
result="success"
echo "Observabilidad verificada con alerta, reinicio, persistencia y evidencia."
