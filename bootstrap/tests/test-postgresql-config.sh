#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

for root in postgresql-secret postgresql-cluster postgresql-config; do
  kubectl kustomize "${project_root}/platform/${root}" >"${temp_dir}/${root}.yaml"
done

if ! yq eval -e '
  select(.kind == "SecretStore" and .metadata.name == "openbao-postgresql") |
  .spec.provider.vault.path == "platform" and
  .spec.provider.vault.version == "v2" and
  .spec.provider.vault.auth.kubernetes.role ==
    "reefops-postgresql-external-secrets" and
  .spec.provider.vault.auth.kubernetes.serviceAccountRef.name ==
    "external-secrets-postgresql-openbao"
  ' "${temp_dir}/postgresql-secret.yaml" >/dev/null ||
  ! yq eval -e '
  select(.kind == "ExternalSecret" and
    .metadata.name == "postgresql-barman-s3") |
  .spec.target.creationPolicy == "Owner" and
  .spec.target.deletionPolicy == "Delete" and
  (.spec.data | length) == 2 and
  .spec.data[0].remoteRef.key == "postgresql/barman-s3" and
  .spec.data[1].remoteRef.key == "postgresql/barman-s3"
  ' "${temp_dir}/postgresql-secret.yaml" >/dev/null; then
  echo "La entrega de credenciales PostgreSQL no está acotada." >&2
  exit 1
fi

if ! yq eval -e '
  select(.kind == "Cluster" and .metadata.name == "reefops-postgresql") |
  .metadata.namespace == "reefops-data" and
  .spec.instances == 1 and
  (.spec.imageName |
    test("^ghcr.io/cloudnative-pg/postgis:18-3-standard-trixie@sha256:[a-f0-9]{64}$")) and
  .spec.enableSuperuserAccess == false and
  .spec.storage.size == "20Gi" and
  .spec.storage.storageClass == "reefops-hostpath-retain" and
  .spec.inheritedMetadata.annotations."helm.sh/resource-policy" == "keep" and
  .spec.inheritedMetadata.labels."reefops.io/s3-client" == "true" and
  (.spec.plugins | length) == 1 and
  .spec.plugins[0].name == "barman-cloud.cloudnative-pg.io" and
  .spec.plugins[0].isWALArchiver == true
  ' "${temp_dir}/postgresql-cluster.yaml" >/dev/null; then
  echo "El Cluster PostgreSQL incumple topología, imagen o persistencia." >&2
  exit 1
fi

if ! yq eval -e '
  select(.kind == "ObjectStore" and
    .metadata.name == "reefops-postgresql-backup") |
  .spec.retentionPolicy == "7d" and
  .spec.configuration.destinationPath ==
    "s3://reefops-postgresql-backup/" and
  .spec.configuration.endpointURL ==
    "http://reefops-seaweedfs-s3.reefops-data.svc:8333" and
  .spec.configuration.s3Credentials.accessKeyId.name ==
    "postgresql-barman-s3" and
  .spec.configuration.s3Credentials.secretAccessKey.name ==
    "postgresql-barman-s3" and
  .spec.instanceSidecarConfiguration.resources.requests.cpu == "25m" and
  .spec.instanceSidecarConfiguration.resources.requests.memory == "64Mi" and
  .spec.instanceSidecarConfiguration.resources.limits.cpu == "500m" and
  .spec.instanceSidecarConfiguration.resources.limits.memory == "512Mi"
  ' "${temp_dir}/postgresql-cluster.yaml" >/dev/null ||
  ! yq eval -e '
  select(.kind == "ScheduledBackup" and
    .metadata.name == "reefops-postgresql-daily") |
  .spec.method == "plugin" and
  .spec.pluginConfiguration.name == "barman-cloud.cloudnative-pg.io" and
  .spec.backupOwnerReference == "self"
  ' "${temp_dir}/postgresql-cluster.yaml" >/dev/null; then
  echo "Backup continuo o programado no usa CNPG-I de forma correcta." >&2
  exit 1
fi

policy_count="$(
  yq eval 'select(.kind == "NetworkPolicy") | .metadata.name' \
    "${temp_dir}/postgresql-config.yaml" |
    sed '/^---$/d' | awk 'NF {count++} END {print count+0}'
)"
[[ "${policy_count}" -eq 7 ]] || {
  echo "Faltan políticas de red PostgreSQL." >&2
  exit 1
}
pod_monitor_count="$(
  yq eval '
    select(.kind == "PodMonitor" and
      .metadata.labels.release == "reefops-monitoring") |
    .metadata.name
  ' "${temp_dir}/postgresql-config.yaml" |
    sed '/^---$/d' | awk 'NF {count++} END {print count+0}'
)"
[[ "${pod_monitor_count}" -eq 2 ]] || {
  echo "La observabilidad PostgreSQL no contiene los dos PodMonitors seleccionables." >&2
  exit 1
}
if yq eval '
  select(.kind == "Cluster" and .spec.monitoring.enablePodMonitor == true) |
  .metadata.name
  ' "${temp_dir}/postgresql-cluster.yaml" |
  sed '/^---$/d' | grep -q .; then
  echo "El ciclo de vida PostgreSQL no debe depender de CRDs de observabilidad." >&2
  exit 1
fi
exposed_services="$(
  yq eval '
    select(.kind == "Service" and
      (.spec.type == "LoadBalancer" or .spec.type == "NodePort")) |
    .metadata.name
  ' "${temp_dir}/postgresql-cluster.yaml" | sed '/^---$/d'
)"
if [[ -n "${exposed_services}" ]]; then
  echo "PostgreSQL no debe tener exposición norte-sur." >&2
  exit 1
fi

# shellcheck disable=SC2016
for contract in \
  'kv put -cas=0' \
  '"@${secret_file}"' \
  'validate_evidence_chain'; do
  grep -F "${contract}" \
    "${project_root}/bootstrap/scripts/bootstrap-postgresql-backup-credentials.sh" \
    >/dev/null || {
      echo "El bootstrap PostgreSQL no materializa: ${contract}" >&2
      exit 1
    }
done
if grep -E 'capabilities.*(create|update|delete|list|sudo)' \
  "${project_root}/bootstrap/openbao/policies/postgresql-external-secrets.hcl" \
  >/dev/null; then
  echo "La política ESO PostgreSQL excede lectura exacta." >&2
  exit 1
fi

echo "Secretos, Cluster, backup, red y observabilidad PostgreSQL validados."
