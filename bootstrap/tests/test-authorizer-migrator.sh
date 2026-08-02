#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
rendered="$(kubectl kustomize "${project_root}/platform/authorizer-migrator")"

yq eval -e '
  select(.kind == "Job" and .metadata.name == "reefops-authorizer-migrate-2d56e3d-r2") |
  .metadata.namespace == "reefops-data" and
  .spec.backoffLimit == 3 and
  .spec.activeDeadlineSeconds == 300 and
  .spec.template.spec.automountServiceAccountToken == false and
  .spec.template.spec.restartPolicy == "Never" and
  .spec.template.spec.securityContext.runAsUser == 65532 and
  .spec.template.spec.securityContext.runAsGroup == 65532 and
  (.spec.template.spec.containers[0].image ==
    "ghcr.io/reefops/reefops-authorizer-migrator@sha256:6ef5fe1f92a7b03b0905c09f3ba59dec6a156b6b6fb11bcf7f79410df0cb8490") and
  .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false and
  .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
  .spec.template.spec.containers[0].securityContext.runAsUser == 65532 and
  .spec.template.spec.containers[0].securityContext.runAsGroup == 65532 and
  .spec.template.spec.containers[0].env[0].valueFrom.secretKeyRef.name ==
    "authorizer-migrator-postgresql" and
  .spec.template.spec.containers[0].env[0].valueFrom.secretKeyRef.key == "uri"
' <<<"${rendered}" >/dev/null

for policy in \
  authorizer-migrator-default-deny \
  authorizer-migrator-dns-egress \
  authorizer-migrator-postgresql-egress \
  postgresql-authorizer-migrator-ingress; do
  yq eval -e "
    select(.kind == \"NetworkPolicy\" and .metadata.name == \"${policy}\") |
    .metadata.namespace == \"reefops-data\"
  " <<<"${rendered}" >/dev/null
done

secret="$(kubectl kustomize "${project_root}/platform/postgresql-secret")"
yq eval -e '
  select(.kind == "ExternalSecret" and
    .metadata.name == "authorizer-migrator-postgresql") |
  .spec.target.template.data.username == "reefops_authorizer_migrator" and
  (.spec.target.template.data.uri |
    test("^postgresql://reefops_authorizer_migrator:.*@reefops-postgresql-rw\\.reefops-data\\.svc:5432/reefops_authorizer_audit\\?sslmode=require$"))
' <<<"${secret}" >/dev/null

echo "Migrador Authorizer fijado, aislado y alimentado exclusivamente por ESO."
