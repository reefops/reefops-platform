# ReefOps Platform

Reusable Kubernetes platform components for ReefOps.

This repository contains bootstrap procedures, cluster infrastructure and
platform services. Environment-specific composition and deployed versions
belong in the private `reefops-gitops` repository.

All changes are declarative, reviewed through pull requests and reconciled by
Flux. Runtime secrets are owned by local OpenBao and are never stored here.
