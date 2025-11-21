# rhsi-edb-vault

End-to-end example for:

* Red Hat Service Interconnect (RHSI, Skupper v2 API)
* OpenShift GitOps (Argo CD) + RHACM ApplicationSet **cluster decision** generator
* PostgreSQL primary/standby logical replication across two OpenShift clusters
* **Token‑based RHSI links via HashiCorp Vault**, using the Skupper v2 **AccessGrant / AccessToken** model

This repo shows how to:

* Declare **Sites**, **AccessGrants**, and Postgres objects with GitOps.
* Store the **sensitive link credential (AccessToken)** in Vault, not in Git.
* Use **External Secrets Operator** on the standby site to pull AccessToken fields from Vault.
* Create an `AccessToken` CR and let the RHSI operator redeem it into a `Link` between clusters.

> The previous TLS / SealedSecret method has been removed from the workflow.  
> This repo now demonstrates **Vault + AccessToken** only.

---

## 1. High‑level architecture

Components:

* **Hub cluster**
  * Runs **RHACM** and **OpenShift GitOps** (Argo CD).
  * Optionally runs **Vault** (in this example: `vault-vault.apps.acm.sandbox2745.opentlc.com`).

* **Site‑a cluster** (primary DB)
  * Managed by ACM (`ManagedCluster` name: `site-a`).
  * RHSI operator installed.
  * GitOps deploys:
    * `Site` `rhsi-primary` (`linkAccess: default`)
    * `AccessGrant rhsi-primary-to-standby`
    * PostgreSQL primary + service
    * Network observer (optional)

* **Site‑b cluster** (standby DB)
  * Managed by ACM (`ManagedCluster` name: `site-b`).
  * RHSI operator installed.
  * **External Secrets Operator** installed.
  * GitOps deploys:
    * `Site` `rhsi-standby`
    * ServiceAccount `rhsi-vault-reader`
    * `SecretStore` pointing at Vault
    * `ExternalSecret` that pulls AccessToken fields from Vault into `Secret rhsi-link-token`
    * A `Job` that turns that Secret into an `AccessToken` CR
    * Standby PostgreSQL deployment + service

RHSI linking flow:

1. `AccessGrant rhsi-primary-to-standby` is created on **site-a** via GitOps.
2. A script (`scripts/publish-access-token-to-vault.sh`) reads the grant’s **status** (`code`, `url`, `ca`) and writes them to **Vault**.
3. On **site-b**, External Secrets Operator:
   * Authenticates to Vault via **Kubernetes auth**.
   * Reads `code`, `url`, `ca` from Vault KV.
   * Projects them into `Secret rhsi-link-token` in namespace `rhsi`.
4. A `Job` on **site-b** reads `rhsi-link-token` and creates an `AccessToken` CR.
5. RHSI/Skupper operator redeems the `AccessToken` and creates a `Link` between `site-b` and `site-a`.
6. PostgreSQL standby connects to the primary over the RHSI tunnel.

---

## 2. Repo layout

```text
rhsi-edb-vault-main/
  README.md
  hub/
    05-managedclustersetbinding-rhsi-clusters.yaml
    10-placement-rhsi-primary.yaml
    11-placement-rhsi-standby.yaml
    12-placement-rhsi-operator.yaml
    13-placement-rhsi-network-observer-operator.yaml
    20-applicationset-rhsi-primary.yaml
    21-applicationset-rhsi-standby.yaml
    22-applicationset-rhsi-operator.yaml
    23-applicationset-rhsi-network-observer-operator.yaml
  rhsi-operator/
    subscription.yaml
  rhsi-network-observer-operator/
    subscription.yaml
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

---

## 3. Prerequisites

1. **Clusters and tools**
   * One **hub** OpenShift cluster with:
     * RHACM installed.
     * OpenShift GitOps (Argo CD) installed.
   * Two **managed clusters**:
     * `site-a` – will host the **primary DB**.
     * `site-b` – will host the **standby DB**.
   * `oc` or `kubectl` CLI.

2. **RHSI operator on app clusters**
   * RHSI / Red Hat Service Interconnect operator installed on:
     * `site-a`
     * `site-b`
   * You can use the `rhsi-operator/subscription.yaml` as an example on each application cluster.

3. **Vault**
   * HashiCorp Vault reachable from **site-b** and from wherever you run the script.
   * A KV v2 secrets engine mounted at `rhsi` (we’ll create this below).
   * Vault route in this example:
     * `https://vault-vault.apps.acm.sandbox2745.opentlc.com`

4. **External Secrets Operator (ESO) on site‑b**
   * Install ESO on the **site-b** cluster, for example:

     ```bash
     helm repo add external-secrets https://charts.external-secrets.io
     helm repo update

     helm upgrade --install external-secrets external-secrets/external-secrets            -n external-secrets --create-namespace
     ```

---

## 4. Deploy the GitOps pieces

> Run these steps with a kubeconfig/context pointing at the **hub** cluster.

1. **Apply hub resources**

   ```bash
   # From the repo root
   oc apply -f hub/
   ```

   This will:

   * Bind the `rhsi-clusters` ManagedClusterSet.
   * Create Placements for primary vs standby vs operator.
   * Create ApplicationSets that target `site-a` and `site-b` using cluster decisions.

2. **Verify Argo CD apps**

   In the OpenShift GitOps UI on the hub:

   * Check that the `rhsi-primary` and `rhsi-standby` apps are **Synced** and **Healthy** on their respective clusters.
   * Check that the RHSI operator subscription is applied to both clusters.

---

## 5. Primary site (site‑a) – Site & AccessGrant

Once the `rhsi-primary` ApplicationSet is synced to **site-a**, it creates:

* Namespace `rhsi`
* `Site` `rhsi-primary` (with `spec.linkAccess: default`)
* `AccessGrant` `rhsi-primary-to-standby`
* PostgreSQL primary deployment & service
* Network observer (optional)

You can confirm on **site-a**:

```bash
# Switch context to site-a
oc config use-context site-a

oc -n rhsi get site
oc -n rhsi get accessgrant
```

Wait until the AccessGrant is **Ready**:

```bash
oc -n rhsi wait accessgrant/rhsi-primary-to-standby       --for=condition=Ready --timeout=300s
```

The AccessGrant’s `status` will contain `code`, `url`, and `ca` which we’ll push into Vault.

---

## 6. Configure Vault

> These commands assume you can reach Vault (e.g. from the hub cluster) and that you have admin rights.

1. **Log into Vault and point VAULT_ADDR**

   ```bash
   export VAULT_ADDR="https://vault-vault.apps.acm.sandbox2745.opentlc.com"
   vault login        # however you normally authenticate
   ```

2. **Enable a KV v2 mount at `rhsi`**

   ```bash
   vault secrets enable -path=rhsi kv-v2
   ```

3. **Prepare Kubernetes auth for site‑b**

   On **site-b**, the manifest `rhsi/standby/05-serviceaccount-vault-reader.yaml` creates:

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: rhsi-vault-reader
     namespace: rhsi
   ```

   Apply the standby manifests (if you haven’t already via Argo) and then grab the SA token and CA:

   ```bash
   # Switch context to site-b
   oc config use-context site-b

   SA_NS="rhsi"
   SA_NAME="rhsi-vault-reader"
   SECRET_NAME=$(oc -n "${SA_NS}" get sa "${SA_NAME}" -o jsonpath='{.secrets[0].name}')
   SA_JWT=$(oc -n "${SA_NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.token}' | base64 -d)
   SA_CA_CRT=$(oc -n "${SA_NS}" get secret "${SECRET_NAME}" -o jsonpath='{.data.ca\.crt}' | base64 -d)
   KUBE_HOST=$(oc whoami --show-server)
   ```

   Back on a shell that has the `vault` CLI:

   ```bash
   vault auth enable kubernetes || true

   vault write auth/kubernetes/config          token_reviewer_jwt="$SA_JWT"          kubernetes_host="$KUBE_HOST"          kubernetes_ca_cert="$SA_CA_CRT"
   ```

4. **Create Vault policy for site‑b**

   ```bash
   cat << 'EOF' | vault policy write rhsi-site-b -
   path "rhsi/data/site-b/link-token" {
     capabilities = ["read"]
   }
   EOF
   ```

5. **Create Vault Kubernetes role for site‑b**

   ```bash
   vault write auth/kubernetes/role/rhsi-site-b          bound_service_account_names="rhsi-vault-reader"          bound_service_account_namespaces="rhsi"          policies="rhsi-site-b"          ttl="1h"
   ```

   This allows pods running as `rhsi-vault-reader` on **site-b** to read the KV entry `rhsi/data/site-b/link-token`.

---

## 7. Publish AccessToken fields into Vault (from site‑a)

The script `scripts/publish-access-token-to-vault.sh` reads the **AccessGrant** status on **site-a** and writes the token data to Vault.

Script contents (for reference):

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-rhsi}"
GRANT_NAME="${GRANT_NAME:-rhsi-primary-to-standby}"
VAULT_ADDR="${VAULT_ADDR:-https://vault-vault.apps.acm.sandbox2745.opentlc.com}"
VAULT_PATH="${VAULT_PATH:-rhsi/site-b/link-token}"  # KV v2 path (no /data prefix)

: "${VAULT_TOKEN:?VAULT_TOKEN must be set or 'vault login' used}"

echo "Waiting for AccessGrant ${GRANT_NAME} in namespace ${NAMESPACE}..."
kubectl -n "${NAMESPACE}" wait accessgrant/"${GRANT_NAME}"       --for=condition=Ready --timeout=300s

CODE=$(kubectl -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.code}')
URL=$(kubectl -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.url}')
CA=$(kubectl -n "${NAMESPACE}" get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.ca}')

if [[ -z "${CODE}" || -z "${URL}" || -z "${CA}" ]]; then
  echo "ERROR: AccessGrant status is missing code/url/ca"
  exit 1
fi

echo "Writing AccessToken fields to Vault at path: ${VAULT_PATH}"
vault kv put "${VAULT_PATH}"       code="${CODE}"       url="${URL}"       ca="${CA}"

echo "Done."
```

To run it:

```bash
# Use a kubeconfig that targets site-a (where the AccessGrant lives)
export KUBECONFIG=/path/to/site-a-kubeconfig

# Ensure Vault env is set and logged in
export VAULT_ADDR="https://vault-vault.apps.acm.sandbox2745.opentlc.com"
export VAULT_TOKEN=<your-vault-token>

# From the repo root
chmod +x scripts/publish-access-token-to-vault.sh
./scripts/publish-access-token-to-vault.sh
```

After running, you should see in Vault (via UI or CLI) a secret at:

* `rhsi/data/site-b/link-token`

with JSON fields:

* `code`
* `url`
* `ca`

---

## 8. Standby site (site‑b) – Vault → ExternalSecret → AccessToken

With the `rhsi-standby` ApplicationSet synced to **site-b**, the following manifests are applied under `rhsi/standby/`:

### 8.1 SecretStore – `70-vault-secretstore.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-rhsi
  namespace: rhsi
spec:
  provider:
    vault:
      server: "https://vault-vault.apps.acm.sandbox2745.opentlc.com"
      path: "rhsi"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "rhsi-site-b"
          serviceAccountRef:
            name: rhsi-vault-reader
```

This tells ESO how to talk to Vault and which Kubernetes auth role to use.

### 8.2 ExternalSecret – `71-externalsecret-link-token.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: rhsi-link-token
  namespace: rhsi
spec:
  refreshInterval: 5m
  secretStoreRef:
    kind: SecretStore
    name: vault-rhsi
  target:
    name: rhsi-link-token
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: "site-b/link-token"
```

ESO will read from `rhsi/data/site-b/link-token` and create a `Secret`:

```bash
oc config use-context site-b
oc -n rhsi get secret rhsi-link-token -o yaml
```

You should see `data.code`, `data.url`, and `data.ca` populated (base64 encoded).

### 8.3 Job to create AccessToken – `80-job-create-access-token.yaml`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: create-access-token-from-vault
  namespace: rhsi
spec:
  template:
    metadata:
      name: create-access-token-from-vault
    spec:
      serviceAccountName: rhsi-vault-reader
      restartPolicy: Never
      containers:
        - name: create-access-token
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command:
            - /bin/bash
            - -c
            - |
              set -euo pipefail

              microdnf install -y kubernetes-client

              CODE=$(kubectl -n rhsi get secret rhsi-link-token -o jsonpath='{.data.code}' | base64 -d)
              URL=$(kubectl -n rhsi get secret rhsi-link-token -o jsonpath='{.data.url}' | base64 -d)
              CA=$(kubectl -n rhsi get secret rhsi-link-token -o jsonpath='{.data.ca}' | base64 -d)

              cat << EOF | kubectl apply -f -
              apiVersion: skupper.io/v2alpha1
              kind: AccessToken
              metadata:
                name: standby-from-vault
                namespace: rhsi
              spec:
                code: "${CODE}"
                url: "${URL}"
                ca: |
  ${CA}
              EOF
```

Once Argo applies this Job on **site-b**, run:

```bash
oc -n rhsi get jobs
oc -n rhsi logs job/create-access-token-from-vault
```

When the Job completes successfully, you should see:

```bash
oc -n rhsi get accesstoken
oc -n rhsi get link
```

* The `AccessToken` CR (`standby-from-vault`) should exist.
* A `Link` resource should be present and **Ready**, representing the connection from **site-b** to **site-a**.

---

## 9. Verify RHSI link and PostgreSQL replication

1. **Check RHSI Site status**

   On both clusters:

   ```bash
   # site-a
   oc config use-context site-a
   oc -n rhsi get site,link

   # site-b
   oc config use-context site-b
   oc -n rhsi get site,link
   ```

2. **Test basic connectivity**

   On **site-b**, run a test pod and reach a service that lives only on **site-a** (for example, the Postgres service on the primary).

   ```bash
   oc -n rhsi run curl-test          --image=registry.access.redhat.com/ubi9/ubi-minimal:latest          -it --rm --restart=Never --          bash -c 'microdnf install -y curl && curl -v rhsi-postgres-primary:5432 || true'
   ```

   You should see a successful TCP connection, proving that RHSI is tunneling traffic across clusters.

3. **Verify PostgreSQL replication**

   * Connect to the **primary** database on `site-a`, create a test table and insert data.
   * Connect to the **standby** database on `site-b` and verify that the data appears there according to your replication config.

   The manifests in `rhsi/primary/` and `rhsi/standby/` include a minimal EDB/Postgres primary/standby example you can adapt to your environment.

---

## 10. Rotation & cleanup

* **Rotate the AccessToken:**
  * Delete or update the `AccessGrant` on **site-a** if needed.
  * Re-run `scripts/publish-access-token-to-vault.sh` to push a new `code/url/ca` into Vault.
  * Delete and re-run the `create-access-token-from-vault` Job on **site-b**, or turn it into a `CronJob` for periodic refresh.

* **Cleanup:**
  * Delete the Argo applications or ApplicationSets from the hub to remove all the RHSI / Postgres resources.
  * Optionally clean up the Vault KV entry `rhsi/site-b/link-token` if you no longer need this link.

---

This repository is now a concrete, GitOps‑friendly example of **RHSI + Skupper v2 + Vault‑backed AccessTokens**, with a simple PostgreSQL replication demo on top.
