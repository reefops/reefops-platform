# ReefOps GitOps

Private desired state for ReefOps clusters.

Flux reads this repository. Changes arrive through reviewed pull requests;
GitHub Actions never deploys directly to a local cluster. OpenBao is the
runtime secret authority. Only SOPS-encrypted bootstrap material may be stored
here, and private keys remain offline.
