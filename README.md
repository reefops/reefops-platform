# ReefOps Platform

Public, reusable Kubernetes platform components for ReefOps.

This repository contains bootstrap procedures, cluster infrastructure and
platform services. Environment-specific composition and deployed versions
belong in the private `reefops-gitops` repository.

All changes are declarative, reviewed through pull requests and reconciled by
Flux. Runtime secrets are owned by local OpenBao and are never stored here.
Validation scans both the current tree and Git history before publication.
Charts and container images used by the active platform are resolved through
immutable OCI digests; a semantic version is retained only as human-readable
provenance and test input.

OpenBao is the active platform stage. Its Helm release deliberately accepts an
unready sealed pod during first installation; consumers remain blocked until
initialization, unseal, policy configuration, Kubernetes-auth verification and
an encrypted external snapshot have succeeded. The local ceremony is described
in `docs/gestion-secretos.md` and is executed through the `openbao-*` tasks.
