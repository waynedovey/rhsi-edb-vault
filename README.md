# RHSI EDB Vault + Skupper AccessGrant Automation

This repo demonstrates how to:
- Store a **Skupper AccessGrant** (code / URL / CA) in **HashiCorp Vault** on the ACM / site‑a cluster.
- Sync that grant into the **site‑b** OpenShift cluster using **External Secrets Operator (ESO)**.
- Materialise it as a **Skupper AccessToken** and **Link** on site‑b for Postgres replication.

The final, working design uses **Vault Kubernetes auth** from site‑b and **does not rely on any long‑lived Vault token** in Kubernetes.

---

## 1. High‑Level Flow

Site‑a (primary) → Vault → Site‑b (standby):

1. **Skupper AccessGrant on site‑a** is created for the `rhsi` site (primary).
2. A script / job on site‑a writes the grant fields into Vault KV v2 at:

   ```text
   rhsi/site-b/link-token
   ```

   with keys:
   - `code` – AccessGrant code
   - `url`  – AccessGrant URL
   - `ca`   – PEM CA for the Skupper grant server

3. On **site‑b**:
   - **External Secrets Operator** uses **Kubernetes auth** to log into Vault via a `SecretStore`.
   - An **ExternalSecret** (`rhsi-link-token`) pulls `code`, `url`, and `ca` from Vault.
   - A **Job** (`create-access-token-from-vault`) reads `rhsi-link-token` and creates / updates a **Skupper AccessToken** (`standby-from-vault`).
   - Skupper uses this AccessToken to create a **Link** to the primary (`rhsi-primary`).

4. Postgres replication over Skupper is validated with a simple `skupper_test` table.

---

## 2. Prerequisites

- Two OpenShift clusters:
  - **site‑a**: ACM hub + Vault + Skupper (primary) + Postgres primary.
  - **site‑b**: Skupper (standby) + Postgres standby.
- `oc` / `kubectl` configured with contexts:
  - `CONTEXT_SITE_A`
  - `CONTEXT_SITE_B`
- Namespace for this demo on both clusters:

  ```bash
  export NS_RHSI="rhsi"
  ```

- Vault is exposed via OpenShift Route, for example:

  ```text
  https://vault-vault.apps.acm.sandbox2745.opentlc.com
  ```

---

## 3. Vault Setup (ACM / Site‑a)

> You only do this once per site‑b cluster.

### 3.1 Enable Kubernetes auth for site‑b

Run these **inside a Vault pod** (so that `/var/run/secrets/...` exists). Example:

```bash
oc --context "${CONTEXT_SITE_A}" -n vault exec -it deploy/vault -- sh
```

Inside the pod:

```bash
vault auth enable -path=kubernetes-site-b kubernetes || true

vault write auth/kubernetes-site-b/config   token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token   kubernetes_host="https://kubernetes.default.svc:443"   kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vault write auth/kubernetes-site-b/role/rhsi-site-b   bound_service_account_names="rhsi-vault-reader"   bound_service_account_namespaces="rhsi"   policies="rhsi-site-b"   token_ttl="1h"   token_max_ttl="24h"
```

> **Important:** The above must *not* be run on your laptop with `@/var/run/...` – that path only exists inside a pod.

### 3.2 Vault policy for site‑b

Create or update a policy `rhsi-site-b` that allows ESO to read the Skupper link token:

```hcl
# policy: rhsi-site-b
path "rhsi/data/site-b/*" {
  capabilities = ["read", "list"]
}
```

Attach this policy to the `rhsi-site-b` Kubernetes auth role (done above).

### 3.3 Populate the Skupper link token into Vault

Your AccessGrant → Vault pipeline (script / job) should end up with a secret like this:

```bash
vault kv get rhsi/site-b/link-token
```

Example output:

```text
==== Data ====
Key   Value
---   -----
ca    -----BEGIN CERTIFICATE-----
      MIIDKjCCAhKgAwIBAgIRAIBt1BRPBhO+oChmZprsM5cw...
      -----END CERTIFICATE-----
code  pvzEkIzVHTFHhPFhU7COJjKc
url   https://skupper-grant-server-https-openshift-operators.apps.site-a.sandbox2745.opentlc.com:443/8365410c-39f1-40bd-a2f4-75ba9536c730
```

As long as this path exists and is readable by policy `rhsi-site-b`, ESO on site‑b can pull it.

---

## 4. Site‑b Setup: Namespace, SA and RBAC

On **site‑b**:

```bash
oc --context "${CONTEXT_SITE_B}" create ns "${NS_RHSI}" || true
```

Apply the service account and RBAC that ESO will impersonate when calling Vault, for example:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f rhsi/standby/rhsi-vault-reader.yaml
```

Typical `rhsi-vault-reader` definition:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rhsi-vault-reader
  namespace: rhsi
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rhsi-vault-reader
  namespace: rhsi
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: rhsi-vault-reader
  namespace: rhsi
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: rhsi-vault-reader
subjects:
  - kind: ServiceAccount
    name: rhsi-vault-reader
    namespace: rhsi
```

> ESO itself runs in its own namespace (`external-secrets`) and uses this ServiceAccount via `SecretStore.spec.provider.vault.auth.kubernetes.serviceAccountRef`.

---

## 5. Site‑b: Trust the Vault Route CA

The SecretStore expects a secret called `vault-ca` in the `rhsi` namespace with key `caCert` containing the CA that signed the Vault route.

On **site‑b**:

```bash
# Extract the router certificate used by the Vault route
oc --context "${CONTEXT_SITE_B}" -n openshift-ingress   get secret router-certs-default   -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/vault-ca.pem

# (Re)create the CA secret in rhsi
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secret vault-ca --ignore-not-found

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" create secret generic vault-ca   --from-file=caCert=/tmp/vault-ca.pem
```

Verify:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret vault-ca -o yaml
```

---

## 6. Site‑b: SecretStore and ExternalSecret

### 6.1 SecretStore pointing to Vault

`rhsi/standby/vault-secretstore-site-b.yaml`:

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
        type: Secret
        name: vault-ca
        key: caCert
      auth:
        kubernetes:
          mountPath: kubernetes-site-b
          role: rhsi-site-b
          serviceAccountRef:
            name: rhsi-vault-reader
```

Apply and verify:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f rhsi/standby/vault-secretstore-site-b.yaml

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" describe secretstore vault-rhsi
```

You should see:

```text
Status:
  Capabilities: ReadWrite
  Conditions:
    Type:     Ready
    Status:   True
    Reason:   Valid
    Message:  store validated
```

If you see 403 errors like `unable to log in with Kubernetes auth`, re‑check:
- Vault role `rhsi-site-b` (bound SA and namespace)
- `mountPath` (`kubernetes-site-b`)
- Policy `rhsi-site-b` permissions on `rhsi/data/site-b/*`
- `vault-ca` secret contents

### 6.2 ExternalSecret pulling the link token

`rhsi/standby/rhsi-link-token.yaml`:

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
    name: vault-rhsi
    kind: SecretStore
  dataFrom:
    - extract:
        key: site-b/link-token
  target:
    name: rhsi-link-token
    creationPolicy: Owner
    deletionPolicy: Retain
```

Apply and verify:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f rhsi/standby/rhsi-link-token.yaml

# Wait for the secret to be created / updated
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token -o yaml

# Decode to validate
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token   -o jsonpath='{.data.code}' | base64 -d; echo

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token   -o jsonpath='{.data.url}' | base64 -d; echo

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token   -o jsonpath='{.data.ca}' | base64 -d | head
```

Example output:

```text
pvzEkIzVHTFHhPFhU7COJjKc
https://skupper-grant-server-https-openshift-operators.apps.site-a.sandbox2745.opentlc.com:443/8365410c-39f1-40bd-a2f4-75ba9536c730
-----BEGIN CERTIFICATE-----
MIIDKjCCAhKgAwIBAgIRAIBt1BRPBhO+oChmZprsM5cw...
```

At this point ESO is successfully pulling the grant from Vault.

---

## 7. Site‑b: Create AccessToken from rhsi‑link‑token

We use a **Job** that:
- Waits for the `rhsi-link-token` Secret to exist.
- Reads `code`, `url`, `ca` from the Secret.
- Creates or updates a Skupper `AccessToken` named `standby-from-vault`.

Manifest: `rhsi/standby/create-access-token-from-vault.yaml` (simplified):

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: create-access-token-from-vault
  namespace: rhsi
spec:
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: skupper-service-account
      containers:
        - name: create-access-token-from-vault
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -euo pipefail

              echo "Waiting for Secret rhsi-link-token to exist..."
              while ! kubectl get secret rhsi-link-token >/dev/null 2>&1; do
                sleep 5
              done

              echo "Secret rhsi-link-token found."
              CODE=$(kubectl get secret rhsi-link-token -o jsonpath='{.data.code}' | base64 -d)
              URL=$(kubectl get secret rhsi-link-token -o jsonpath='{.data.url}' | base64 -d)
              CA=$(kubectl get secret rhsi-link-token  -o jsonpath='{.data.ca}'  | base64 -d)

              echo "Creating AccessToken standby-from-vault..."
              cat <<EOF | kubectl apply -f -
              apiVersion: skupper.io/v2alpha1
              kind: AccessToken
              metadata:
                name: standby-from-vault
                namespace: rhsi
              spec:
                code: ${CODE}
                url: ${URL}
                ca: |
              $(echo "${CA}" | sed 's/^/    /')
              EOF

              echo "AccessToken standby-from-vault created/updated."
```

Run the job on **site‑b**:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete job create-access-token-from-vault --ignore-not-found

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f rhsi/standby/create-access-token-from-vault.yaml

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" wait   --for=condition=Complete   --timeout=120s   job/create-access-token-from-vault

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" logs job/create-access-token-from-vault
```

Example log:

```text
Waiting for Secret rhsi-link-token to exist...
Secret rhsi-link-token found.
Reading AccessToken fields from Secret rhsi-link-token...
Creating AccessToken standby-from-vault...
accesstoken.skupper.io/standby-from-vault unchanged
AccessToken standby-from-vault created/updated.
```

Verify the AccessToken and Link:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get accesstoken standby-from-vault -o yaml

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get link

skupper --context "${CONTEXT_SITE_B}" --namespace "${NS_RHSI}" link status
```

Example:

```text
NAME                 STATUS   REMOTE SITE    MESSAGE
standby-from-vault   Ready    rhsi-primary   OK

NAME                  STATUS  COST  MESSAGE
standby-from-vault    Ready   0     OK
```

> **Rotation:** whenever the grant in Vault changes (new `code` / `url` / `ca`), rerun the `create-access-token-from-vault` Job, or convert it to a `CronJob` for automatic periodic rotation.

---

## 8. Postgres Replication Sanity Test

From the **standby** pod on site‑b:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" exec -it deploy/postgres-standby -- bash
```

Inside the pod:

```bash
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
- Skupper link is working between site‑b and site‑a.
- Postgres standby can reach the primary via Skupper.
- The AccessGrant → Vault → ESO → AccessToken pipeline is functioning end‑to‑end.

---

## 9. Notes and Gotchas

- **No long‑lived Vault token:** the design intentionally uses Kubernetes auth instead of a static `vault-token` Secret.
- **Run Vault config inside a pod:** commands referencing `@/var/run/secrets/...` must be executed inside a Vault pod, not from your laptop.
- **SecretStore readiness:** if `SecretStore` is not `Ready`, check ESO logs in the `external-secrets` namespace and Vault audit logs.
- **TLS issues:** if you see certificate errors, re‑create the `vault-ca` secret using the correct router or custom CA used by the Vault route.
- **Rotation:** use a `CronJob` wrapper around the `create-access-token-from-vault` logic if you want fully hands‑off token rotation.
