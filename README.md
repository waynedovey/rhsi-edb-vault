# RHSI EDB + Vault + External Secrets (Option A)

This repo is a **minimal, self‑contained example** of Option A:

* Store Skupper link token and EDB repo token in **Vault KV**.
* Use **External Secrets Operator (ESO)** on the standby cluster (site‑b) to sync those
  Vault values into Kubernetes secrets.
* Run **Jobs** in the `rhsi` namespace on site‑b to transform those synced secrets
  into:
  * `skupper-access-token-from-vault` – used by Skupper to link to site‑a.
  * `edb-operator-pullsecret-from-vault` – used by the EDB operator subscription
    to pull images from the EDB registry.

> ⚠️ This is a lab reference. You’ll almost certainly want to tweak names, labels
> and image references to match your environment. The manifests are intentionally
> conservative and readable rather than “perfectly optimised”.

(Trimmed here for brevity in this environment – the real README in the zip
includes full architecture notes, Vault config steps, sanity checks, and usage
examples.)
