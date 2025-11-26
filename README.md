# RHSI EDB + Vault + Skupper AccessGrant Automation

This repo demonstrates how to automatically manage **Skupper link tokens** between
a **primary (site-a)** and **standby (site-b)** OpenShift cluster using:

- **Skupper AccessGrant / AccessToken**
- **HashiCorp Vault** (KV v2)
- **External Secrets Operator (ESO)** on site-b
- A **Job** on site-b to convert Vault data into a Skupper `AccessToken`

The end result is:

- On **site-a**, the Skupper **AccessGrant** details (code / URL / CA) for site-b
  are stored under a **Vault KV path**.
- On **site-b**, ESO reads that Vault KV entry and creates a **Kubernetes Secret**
  (`rhsi-link-token`).
- A Job on **site-b** converts that Secret into a Skupper **AccessToken** resource
  (`standby-from-vault`), which backs a **Skupper Link**.
- The link becomes **Ready**, and Postgres replication works across Skupper.

---

## 1. Prerequisites

You will need:

- Two OpenShift clusters:
  - **site-a** (primary)
  - **site-b** (standby)
- A common namespace on both clusters, e.g.:

  ```bash
  export NS_RHSI="rhsi"
  ```

- Working `oc`, `kubectl`, `skupper` and `vault` CLIs.
- External Secrets Operator installed on **site-b**.
- HashiCorp Vault reachable from **site-b** (the cluster where ESO runs).

Recommended shell variables:

```bash
# kubecontexts
export CONTEXT_SITE_A="site-a"
export CONTEXT_SITE_B="site-b"

# namespace
export NS_RHSI="rhsi"

# Vault
export VAULT_ADDR="https://vault-vault.apps.acm.sandbox2745.opentlc.com"
export VAULT_TOKEN="root"   # or an appropriately scoped token
```

> Adjust the values above to match your environment.

---

## 2. Vault Kubernetes Auth (site-b)

We use **Kubernetes auth** for ESO to authenticate to Vault from **site-b**,
rather than a static token.

### 2.1. Configure Vault Kubernetes auth

In Vault (once, from your admin shell), configure the `kubernetes-site-b` auth
mount and role (example only, adapt as required):

```bash
vault auth enable -path=kubernetes-site-b kubernetes || true

vault write auth/kubernetes-site-b/config   token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token   kubernetes_host="https://kubernetes.default.svc:443"   kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vault write auth/kubernetes-site-b/role/rhsi-site-b   bound_service_account_names="rhsi-vault-reader"   bound_service_account_namespaces="rhsi"   policies="rhsi-site-b"   token_ttl="1h"   token_max_ttl="24h"
```

Verify the Vault role:

```bash
vault read auth/kubernetes-site-b/role/rhsi-site-b
```

You should see:

- `bound_service_account_names` includes `rhsi-vault-reader`
- `bound_service_account_namespaces` includes `rhsi`
- `token_policies` includes `rhsi-site-b`

### 2.2. ServiceAccount on site-b

On the **site-b** cluster in the `rhsi` namespace, create the
`rhsi-vault-reader` ServiceAccount and bind it with a suitable Role/ClusterRole
(as defined in your repo manifests). For example:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get sa rhsi-vault-reader
```

Make sure this ServiceAccount name matches the one in the Vault role above.

### 2.3. CA Secret for Vault (`vault-ca`)

On **site-b**, create a Secret containing the CA used by Vault’s TLS endpoint.

Example (using the `router-certs-default` cert from `openshift-ingress`):

```bash
# Export the OpenShift router cert for Vault (site-b)
oc --context "${CONTEXT_SITE_B}" -n openshift-ingress   get secret router-certs-default   -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/vault-ca.pem

# Recreate the vault-ca Secret in rhsi
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secret vault-ca --ignore-not-found

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" create secret generic vault-ca   --from-file=caCert=/tmp/vault-ca.pem
```

You should see:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret vault-ca -o yaml
```

with:

```yaml
data:
  caCert: <base64-encoded PEM>
```

---

## 3. SecretStore for Vault on site-b

Create a `SecretStore` on **site-b** that uses Kubernetes auth and the `vault-ca`
Secret.

Example YAML (make sure this matches your repo manifest):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-rhsi
  namespace: rhsi
  labels:
    app.kubernetes.io/instance: rhsi-standby-site-b
spec:
  provider:
    vault:
      server: https://vault-vault.apps.acm.sandbox2745.opentlc.com
      path: rhsi
      version: v2
      caProvider:
        name: vault-ca
        key: caCert
        type: Secret
      auth:
        kubernetes:
          mountPath: kubernetes-site-b
          role: rhsi-site-b
          serviceAccountRef:
            name: rhsi-vault-reader
```

Apply it:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f <PATH-TO>/vault-secretstore-site-b.yaml
```

Verify the SecretStore:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" describe secretstore vault-rhsi
```

Expected:

- `Status: True`
- `Reason: Valid`
- `Message: store validated`

If you previously used **token-based auth** (`vault-token` Secret), that can
now be removed from the README and from your manifests – it is no longer needed.

---

## 4. Vault KV entry for Skupper AccessGrant

On **site-a**, the Skupper Grant Server issues an AccessGrant for site-b. A
separate Job/CronJob (in this repo) populates Vault with:

- `code`
- `url`
- `ca`

under the KV path: `rhsi/site-b/link-token` (Vault KV v2).

Verify from your Vault shell:

```bash
vault kv get rhsi/site-b/link-token
```

Example output:

```text
==== Data ====
Key     Value
---     -----
ca      -----BEGIN CERTIFICATE-----
        MIIDKjCCAhKgAwIBAgIRAIBt1BRPBhO+oChmZprsM5cwDQYJKoZIhvcNAQELBQAw
        ...
        -----END CERTIFICATE-----
code    pvzEkIzVHTFHhPFhU7COJjKc
url     https://skupper-grant-server-https-openshift-operators.apps.site-a.sandbox2745.opentlc.com:443/8365410c-39f1-40bd-a2f4-75ba9536c730
```

---

## 5. ExternalSecret on site-b (`rhsi-link-token`)

On **site-b**, use ESO to pull the `link-token` data from Vault into a
Kubernetes Secret.

Example ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: rhsi-link-token
  namespace: rhsi
  labels:
    app.kubernetes.io/instance: rhsi-standby-site-b
spec:
  refreshInterval: 5m
  secretStoreRef:
    kind: SecretStore
    name: vault-rhsi
  dataFrom:
    - extract:
        key: site-b/link-token
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
  target:
    name: rhsi-link-token
    creationPolicy: Owner
    deletionPolicy: Retain
```

Apply it:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f <PATH-TO>/externalsecret-rhsi-link-token.yaml
```

Optionally force a reconcile:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" annotate externalsecret rhsi-link-token   reconcile.external-secrets.io/requestedAt="$(date -Iseconds)" --overwrite
```

Check the Secret content from the cluster side:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token   -o jsonpath='{.data.code}' | base64 -d; echo

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token   -o jsonpath='{.data.url}' | base64 -d; echo

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token   -o jsonpath='{.data.ca}' | base64 -d | head
```

These values should **match** what you see in Vault at `rhsi/site-b/link-token`.

---

## 6. Create Skupper AccessToken from Vault data (site-b)

On **site-b**, a Job converts the `rhsi-link-token` Secret into a Skupper
`AccessToken` resource called `standby-from-vault`.

Example usage:

```bash
# Clean up any previous Job run
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete job create-access-token-from-vault --ignore-not-found

# Apply the Job manifest
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f <PATH-TO>/create-access-token-from-vault.yaml

# Wait for job completion
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" wait   --for=condition=Complete   --timeout=120s   job/create-access-token-from-vault

# Check logs
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" logs job/create-access-token-from-vault
```

Example log output:

```text
Waiting for Secret rhsi-link-token to exist...
Secret rhsi-link-token found.
Reading AccessToken fields from Secret rhsi-link-token...
Creating AccessToken standby-from-vault...
accesstoken.skupper.io/standby-from-vault unchanged
AccessToken standby-from-vault created/updated.
```

You can then inspect the AccessToken:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get accesstoken standby-from-vault -o yaml
```

Expected fields (truncated):

```yaml
apiVersion: skupper.io/v2alpha1
kind: AccessToken
metadata:
  name: standby-from-vault
  namespace: rhsi
spec:
  ca: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  code: pvzEkIzVHTFHhPFhU7COJjKc
  url: https://skupper-grant-server-https-openshift-operators.apps.site-a.sandbox2745.opentlc.com:443/8365410c-39f1-40bd-a2f4-75ba9536c730
status:
  status: Ready
  redeemed: true
  conditions:
    - type: Redeemed
      status: "True"
      reason: Ready
      message: OK
```

---

## 7. Verify Skupper link and Postgres

### 7.1. Skupper link status

Check the Skupper link on **site-b**:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get link

skupper --context "${CONTEXT_SITE_B}" --namespace "${NS_RHSI}" link status
```

Expected:

```text
NAME                 STATUS   REMOTE SITE    MESSAGE
standby-from-vault   Ready    rhsi-primary   OK

NAME                  STATUS  COST  MESSAGE
standby-from-vault    Ready   0     OK
```

### 7.2. Postgres test

From the `postgres-standby` deployment on **site-b**, connect to the primary
via Skupper and run a simple test:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" exec -it deploy/postgres-standby -- bash

export PGPASSWORD='supersecret'

psql   -h postgres-primary   -p 5432   -U appuser   -d postgres << 'SQL'
CREATE TABLE IF NOT EXISTS skupper_test (
  id         serial PRIMARY KEY,
  site       text,
  created_at timestamptz DEFAULT now()
);

INSERT INTO skupper_test (site)
VALUES ('site-b-via-skupper');

SELECT * FROM skupper_test
ORDER BY id DESC
LIMIT 5;
SQL
```

Example output:

```text
CREATE TABLE
INSERT 0 1
 id |        site        |          created_at
----+--------------------+-------------------------------
  1 | site-b-via-skupper | 2025-11-26 23:44:08.860355+00
(1 row)
```

This confirms:

- The Skupper link is working end-to-end.
- Postgres standby on **site-b** can connect to the primary via Skupper.
- The AccessToken derived from Vault (`standby-from-vault`) is valid.

---

## 8. Clean-up and rotation notes

- The **Vault KV entry** can be rotated by re-running the AccessGrant Job/CronJob
  on **site-a** that refreshes `rhsi/site-b/link-token`.
- ESO will pick up the new values and update `rhsi-link-token` on **site-b**.
- Re-running the `create-access-token-from-vault` Job will update the
  `AccessToken` `standby-from-vault` and refresh the link.

To clean up everything on **site-b**:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete accesstoken standby-from-vault --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete externalsecret rhsi-link-token --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secretstore vault-rhsi --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secret vault-ca --ignore-not-found
```

> Note: do **not** delete the Vault KV data if you still want the link to be
> automatically recreated in the future.

---

## 9. What changed from earlier versions?

Compared to earlier iterations of this lab:

- **Removed** use of a static `vault-token` Secret for ESO.
- **Switched** to **Kubernetes auth** for Vault using `rhsi-vault-reader` and
  the `kubernetes-site-b` auth mount.
- **Clarified** the CA setup via the `vault-ca` Secret (`caCert` key).
- **Documented** the end-to-end verification flow for:
  - `rhsi-link-token` Secret
  - `standby-from-vault` AccessToken
  - Skupper link status
  - Postgres connectivity via Skupper.

This README reflects the **known-good** configuration from the latest working
run.
