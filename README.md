# rhsi

End-to-end example for:

* Red Hat Service Interconnect (RHSI, Skupper v2 API)
* OpenShift GitOps (Argo CD) + RHACM ApplicationSet
* HashiCorp Vault + External Secrets Operator for Red Hat OpenShift
* PostgreSQL primary/standby logical replication across two OpenShift clusters

The goal is a **fully automated** RHSI link using:

* GitOps to deploy all Kubernetes/RHSI resources.
* Vault to hold the **AccessToken** fields (code/url/ca).
* External Secrets Operator (ESO) to project Vault data onto the standby cluster.
* A small Job on the standby to create the `AccessToken` CR from that Secret.

No manual `skupper token` or `skupper link` steps are required.

## 1. Topology

* **Hub cluster**
  * RHACM + OpenShift GitOps (`openshift-gitops`).
* **site-a**
  * RHSI operator.
  * `rhsi-primary` Site, AccessGrant, Postgres primary.
* **site-b**
  * RHSI operator.
  * External Secrets Operator for Red Hat OpenShift.
  * `rhsi-standby` Site, SecretStore, ExternalSecret, AccessToken Job, Postgres standby.

## 2. Repo layout (key parts)

```text
hub/
  05-managedclustersetbinding-rhsi-clusters.yaml
  10-placement-rhsi-primary.yaml
  11-placement-rhsi-standby.yaml
  12-placement-rhsi-operator.yaml
  13-placement-rhsi-network-observer-operator.yaml
  14-placement-rhsi-external-secrets-operator.yaml
  20-applicationset-rhsi-primary.yaml
  21-applicationset-rhsi-standby.yaml
  22-applicationset-rhsi-operator.yaml
  23-applicationset-rhsi-network-observer-operator.yaml
  24-applicationset-rhsi-external-secrets-operator.yaml

external-secrets-operator/
  00-namespace-external-secrets-operator.yaml
  10-operatorgroup.yaml
  20-subscription.yaml

rhsi/
  primary/
    00-namespace-rhsi.yaml
    10-site.yaml
    15-accessgrant-standby.yaml
    20-postgres-primary-secret.yaml
    30-postgres-primary-deployment.yaml
    40-postgres-primary-service.yaml
    50-connector-postgres.yaml
    60-networkobserver.yaml
  standby/
    00-namespace-rhsi.yaml
    05-serviceaccount-vault-reader.yaml
    10-site.yaml
    20-postgres-standby-secret.yaml
    30-postgres-standby-deployment.yaml
    40-postgres-standby-service.yaml
    50-listener-postgres.yaml
    60-networkobserver.yaml
    70-vault-secretstore.yaml
    71-externalsecret-link-token.yaml
    80-job-create-access-token.yaml

scripts/
  publish-access-token-to-vault.sh
```

## 3. Prereqs

* Hub cluster with RHACM and OpenShift GitOps.
* Managed clusters registered in ACM as `site-a` and `site-b`.
* HashiCorp Vault reachable from clusters and CI.
* KV v2 enabled at `rhsi` in Vault.
* RHSI operator installed on both app clusters.
* External Secrets Operator for Red Hat OpenShift available in `redhat-operators` catalog.

## 4. Hub: labels, placements, ApplicationSets

On the hub:

```bash
oc label managedcluster site-a rhsi-role=primary --overwrite
oc label managedcluster site-b rhsi-role=standby --overwrite

oc apply -f hub/
```

This drives:

* RHSI operator install.
* Network observer operator (optional).
* Primary manifests to `site-a`.
* Standby manifests to `site-b`.
* External Secrets Operator for Red Hat OpenShift to `site-b`.

## 5. Primary (site-a): Site, AccessGrant, Postgres

Once `rhsi-primary` ApplicationSet syncs to `site-a`:

```bash
oc config use-context site-a
oc -n rhsi get site,accessgrant
```

Wait for `AccessGrant rhsi-primary-to-standby` to be Ready:

```bash
oc -n rhsi wait accessgrant/rhsi-primary-to-standby       --for=condition=Ready --timeout=300s
```

This AccessGrant’s `status.code`, `status.url`, `status.ca` will be used to create tokens.

## 6. Vault + publish script (automation point)

1. On Vault:

   ```bash
   export VAULT_ADDR="https://vault-vault.apps.acm.sandbox2745.opentlc.com"
   vault login    # your auth
   vault secrets enable -path=rhsi kv-v2 || true
   ```

   Create a policy allowing write to `rhsi/data/site-b/link-token` and issue a token with that policy.

2. In CI/CD (or an admin shell), run the helper script:

   ```bash
   export KUBECONFIG=/path/to/site-a/kubeconfig
   export VAULT_ADDR="https://vault-vault.apps.acm.sandbox2745.opentlc.com"
   export VAULT_TOKEN=<token-with-rhsi-policy>

   chmod +x scripts/publish-access-token-to-vault.sh
   ./scripts/publish-access-token-to-vault.sh
   ```

   This writes `code`, `url`, `ca` into Vault KV v2 at `rhsi/site-b/link-token`.

You can hook this script into any GitOps pipeline so it runs automatically after the AccessGrant is ready.

## 7. Standby (site-b): ESO, SecretStore, AccessToken Job

1. External Secrets Operator for Red Hat OpenShift

   Deployed to `site-b` via:

   * `external-secrets-operator/` manifests.
   * `hub/14-placement-rhsi-external-secrets-operator.yaml`
   * `hub/24-applicationset-rhsi-external-secrets-operator.yaml`

   Check:

   ```bash
   oc config use-context site-b
   oc get csv -n external-secrets-operator
   ```

2. Vault SecretStore and ExternalSecret

   On `site-b`, GitOps applies:

   * `rhsi/standby/05-serviceaccount-vault-reader.yaml`
   * `rhsi/standby/70-vault-secretstore.yaml` – points at Vault (`rhsi` KV).
   * `rhsi/standby/71-externalsecret-link-token.yaml` – pulls `site-b/link-token` into `Secret rhsi-link-token`.

   You must configure Vault Kubernetes auth role `rhsi-site-b` to trust this cluster/SA.

3. AccessToken Job

   `rhsi/standby/80-job-create-access-token.yaml` runs a Job that:

   * Reads `code`, `url`, `ca` from `Secret rhsi-link-token`.
   * Creates an `AccessToken` CR `standby-from-vault`.
   * RHSI operator redeems it and creates a `Link` automatically.

   Verify:

   ```bash
   oc -n rhsi get accesstoken
   oc -n rhsi get link
   ```

4. Postgres standby

   The rest of `rhsi/standby` deploys the standby DB and `Listener` for the primary service.

## 8. Verify & rotate

* Sites and links:

  ```bash
  oc config use-context site-a
  oc -n rhsi get site,link

  oc config use-context site-b
  oc -n rhsi get site,link
  ```

* Rotate AccessToken:

  * Re-issue/rotate AccessGrant on `site-a` if needed.
  * Re-run `publish-access-token-to-vault.sh` in automation to update Vault.
  * ESO refreshes `rhsi-link-token`, Job can be re-run or converted to a CronJob.

No manual `skupper link` or static secrets in Git are required; all link material is either:

* GitOps-managed CRs (Site, AccessGrant, AccessToken), or
* Stored in Vault and projected via External Secrets Operator.
