#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

kubectl kustomize "${project_root}/platform/postgresql-recovery-drill" \
  >"${temp_dir}/drill.yaml"

# shellcheck disable=SC2016
if ! yq eval -e '
  select(.kind == "Cluster" and
    .metadata.name == "reefops-postgresql-recovery-drill") |
  .metadata.namespace == "reefops-data" and
  .metadata.labels."reefops.io/lifecycle" == "ephemeral" and
  .spec.instances == 1 and
  .spec.enableSuperuserAccess == false and
  .spec.storage.storageClass == "reefops-hostpath-delete" and
  .spec.storage.size == "5Gi" and
  .spec.bootstrap.recovery.source == "origin" and
  .spec.bootstrap.recovery.recoveryTarget.backupID ==
    "${REEFOPS_POSTGRESQL_RECOVERY_BACKUP_ID}" and
  .spec.bootstrap.recovery.recoveryTarget.targetName ==
    "${REEFOPS_POSTGRESQL_RECOVERY_TARGET}" and
  (.spec.plugins == null or (.spec.plugins | length) == 0) and
  (.spec.externalClusters | length) == 1 and
  .spec.externalClusters[0].name == "origin" and
  .spec.externalClusters[0].plugin.name ==
    "barman-cloud.cloudnative-pg.io" and
  .spec.externalClusters[0].plugin.parameters.barmanObjectName ==
    "reefops-postgresql-recovery-source" and
  .spec.externalClusters[0].plugin.parameters.serverName ==
    "reefops-postgresql"
  ' "${temp_dir}/drill.yaml" >/dev/null; then
  echo "El Cluster de simulacro no conserva aislamiento y PITR por plugin." >&2
  exit 1
fi

if ! yq eval -e '
  select(.kind == "ObjectStore" and
    .metadata.name == "reefops-postgresql-recovery-source") |
  .spec.configuration.destinationPath ==
    "s3://reefops-postgresql-backup/" and
  .spec.configuration.endpointURL ==
    "http://reefops-seaweedfs-s3.reefops-data.svc:8333" and
  .spec.configuration.s3Credentials.accessKeyId.name ==
    "postgresql-barman-s3" and
  .spec.configuration.s3Credentials.secretAccessKey.name ==
    "postgresql-barman-s3" and
  .spec.instanceSidecarConfiguration.resources.requests.cpu == "25m" and
  .spec.instanceSidecarConfiguration.resources.limits.memory == "512Mi"
  ' "${temp_dir}/drill.yaml" >/dev/null; then
  echo "El origen PITR no reutiliza el backup Barman acotado." >&2
  exit 1
fi

policy_count="$(
  yq eval '
    select(.kind == "NetworkPolicy" and
      (.spec.podSelector.matchLabels."cnpg.io/cluster" ==
        "reefops-postgresql-recovery-drill")) |
    .metadata.name
  ' "${temp_dir}/drill.yaml" |
    sed '/^---$/d' | awk 'NF {count++} END {print count+0}'
)"
[[ "${policy_count}" -eq 6 ]] || {
  echo "El simulacro no tiene exactamente seis políticas de aislamiento." >&2
  exit 1
}

if yq eval '
  select(.kind == "Service" or .kind == "Ingress" or
    .kind == "Gateway" or .kind == "HTTPRoute") |
  .metadata.name
  ' "${temp_dir}/drill.yaml" | sed '/^---$/d' | grep -q .; then
  echo "La raíz de recuperación declara exposición norte-sur." >&2
  exit 1
fi

echo "Raíz PITR aislada, efímera y sin archivado propio validada."
