# rhsi-edb-vault

End-to-end lab for demonstrating Red Hat Service Interconnect (Skupper), EDB Postgres, and HashiCorp Vault with the OpenShift External Secrets Operator.  

The scenario:

- **site-a** – primary application cluster (Postgres primary, Skupper listener).
- **site-b** – standby application cluster (Postgres standby, Skupper connector).
- **hub** – ACM / Argo CD / Vault cluster.

Skupper creates a secure Layer 7 service network between **site-a** and **site-b**.  
The **AccessGrant** for that link is **stored in Vault**, synced into **site-b** via ESO, and consumed by a Job that creates an **AccessToken** and **Link**.

This README captures the working flow, including the fixes you just validated.

---

## 1. Prerequisites

You’ll need:

- `oc` CLI configured with contexts:
  - `hub` (or `acm`) – hub cluster
  - `site-a` – primary app cluster
  - `site-b` – standby app cluster
- `skupper` CLI ≥ 2.1.1 (matches operator version deployed by the repo)
- `vault` CLI with access to the Vault server on the hub
- Argo CD / ACM up and managing the app clusters
- Logged in to all clusters with cluster-admin privileges for the lab namespaces

Conventions used below:

```bash
# kube contexts
CONTEXT_HUB=hub
CONTEXT_SITE_A=site-a
CONTEXT_SITE_B=site-b

# application namespace on app clusters
NS_RHSI=rhsi
```

---

## 2. Deploy GitOps and application components

From the root of this repo on your workstation:

```bash
oc apply -f hub/
```

This creates:

- A `ManagedClusterSetBinding` and `Placement`s for:
  - `rhsi-primary` (site-a)
  - `rhsi-standby` (site-b)
  - `rhsi-operator`
  - `rhsi-network-observer-operator`
  - `rhsi-external-secrets-operator`
- A `GitOpsCluster` pointing ACM to the Argo CD instance

Argo CD then deploys, per cluster:

- Skupper operator + Skupper `Site` objects
- EDB Postgres primary (site-a) and standby (site-b)
- Network Observer
- External Secrets Operator integration (SecretStore + ExternalSecret)
- ServiceAccount and Job for the Vault/AccessToken integration

You can verify the namespace exists and basic components are running, for example on **site-a**:

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" get site,listener,connector,pods
```

and on **site-b**:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get site,listener,connector,accesstoken,link,pods
```

---

## 3. Configure Vault for site-b

Vault runs on the **hub** cluster and is exposed via a route. In this lab we assume:

```bash
export VAULT_ADDR="https://vault-vault.apps.acm.sandbox2745.opentlc.com"
export VAULT_TOKEN="root"   # lab-only; in production, use a proper token workflow
```

### 3.1 Enable the KV v2 engine (once)

If not already enabled:

```bash
vault secrets enable -path=rhsi kv-v2
```

You can confirm:

```bash
vault secrets list
```

You should see a mount at `rhsi/` of type `kv`.

### 3.2 Configure Kubernetes auth for site-b

The repo (via Argo CD) creates a ServiceAccount `rhsi-vault-reader` in the `rhsi` namespace on **site-b** which will be used by the External Secrets Operator to access Vault.

First sanity-check that the ServiceAccount exists:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get sa rhsi-vault-reader
```

Now configure a Kubernetes auth mount in Vault at path `kubernetes-site-b`:

```bash
# 1) Fetch the site-b cluster CA
oc --context "${CONTEXT_SITE_B}" -n kube-public \
  get configmap kube-root-ca.crt \
  -o jsonpath='{.data.ca\.crt}' > /tmp/site-b-ca.crt

# 2) Create a short-lived reviewer JWT for the SA
export REVIEWER_JWT=$(
  oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" \
    create token rhsi-vault-reader
)

# 3) Enable the auth method if not already present
vault auth enable -path=kubernetes-site-b kubernetes || true

# 4) Point the auth method at the site-b API server
export KUBE_HOST=$(
  oc --context "${CONTEXT_SITE_B}" config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}'
)
export KUBE_CA_CRT=$(cat /tmp/site-b-ca.crt)

vault write auth/kubernetes-site-b/config \
  token_reviewer_jwt="$REVIEWER_JWT" \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA_CRT"
```

Create a **read-only** policy for the `site-b/link-token` secret:

```bash
vault policy write rhsi-site-b - << 'EOF'
path "rhsi/data/site-b/*" {
  capabilities = ["read"]
}
EOF
```

Create a role that binds the ServiceAccount to that policy:

```bash
vault write auth/kubernetes-site-b/role/rhsi-site-b \
  bound_service_account_names="rhsi-vault-reader" \
  bound_service_account_namespaces="${NS_RHSI}" \
  token_policies="rhsi-site-b" \
  ttl="1h"
```

> At this point, the External Secrets Operator on **site-b** can authenticate to Vault using the `rhsi-vault-reader` ServiceAccount and read secrets under `rhsi/data/site-b/*`.

---

## 4. ESO wiring for the Skupper link token (site-b)

These objects are deployed to **site-b** by Argo CD from the `rhsi/standby` manifests. You don’t normally have to create them by hand, but they’re documented here for clarity.

### 4.1 SecretStore `vault-rhsi`

The `SecretStore` tells ESO how to talk to Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-rhsi
  namespace: rhsi
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

### 4.2 ExternalSecret `rhsi-link-token`

The `ExternalSecret` maps the Vault secret into a Kubernetes `Secret` called `rhsi-link-token`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: rhsi-link-token
  namespace: rhsi
spec:
  dataFrom:
  - extract:
      key: site-b/link-token         # <== maps to Vault path rhsi/data/site-b/link-token
  refreshInterval: 5m
  secretStoreRef:
    kind: SecretStore
    name: vault-rhsi
  target:
    name: rhsi-link-token
    creationPolicy: Owner
    deletionPolicy: Retain
```

When everything is configured correctly, you should see on **site-b**:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secretstore vault-rhsi -o yaml
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get externalsecret rhsi-link-token -o yaml
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token -o yaml
```

`SecretStore` and `ExternalSecret` should be **Ready**, and `rhsi-link-token` should contain three keys: `code`, `url`, and `ca`.

---

## 5. Skupper sites and Postgres

Argo CD deploys Skupper to both clusters and configures:

- **site-a / rhsi**
  - `Site` named `rhsi-primary`
  - Postgres primary Deployment `postgres-primary`
  - A Skupper `Listener` exposing Postgres
- **site-b / rhsi**
  - `Site` named `rhsi-standby`
  - Postgres standby Deployment `postgres-standby`
  - A Skupper `Connector` that will target the `postgres` routing key

Sanity check Skupper on **site-a**:

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" get site,listener,connector,pods
skupper --context "${CONTEXT_SITE_A}" --namespace "${NS_RHSI}" version
```

On **site-b**:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get site,listener,connector,accesstoken,link,pods
skupper --context "${CONTEXT_SITE_B}" --namespace "${NS_RHSI}" version
```

---

## 6. Create the Skupper AccessGrant on site-a (fixed API)

The grant that remote sites redeem is represented by a Skupper `AccessGrant` custom resource.  

> **Important API detail:** The field is `spec.redemptionsAllowed`, not `uses`. Using the wrong field name is what led to 404 “No such access granted” earlier.

Apply the AccessGrant on **site-a**:

```yaml
# rhsi/site-a/rhsi-standby-grant.yaml
apiVersion: skupper.io/v2alpha1
kind: AccessGrant
metadata:
  name: rhsi-standby-grant
  namespace: rhsi
spec:
  redemptionsAllowed: 5
  expirationWindow: 1h
```

Apply and wait for it to become Ready:

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" apply -f rhsi/site-a/rhsi-standby-grant.yaml

oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" wait \
  --for=condition=Ready \
  --timeout=120s \
  accessgrant rhsi-standby-grant
```

Inspect the populated status (this is what we will later copy into Vault):

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" get accessgrant rhsi-standby-grant \
  -o jsonpath=$'{.status.status}{"\n"}{.status.message}{"\n"}{.status.redemptions}{"\n"}{.spec.redemptionsAllowed}{"\n"}{.status.expirationTime}{"\n"}'

oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" get accessgrant rhsi-standby-grant \
  -o jsonpath=$'{.status.code}{"\n"}{.status.url}{"\n"}{.status.ca}{"\n"}'
```

You should see something like:

```text
Ready
OK

5
2025-11-26T07:06:00Z

qQWQwLcrhluUq8ROJ8Vggee8
https://skupper-grant-server-https-openshift-operators.apps.site-a.sandbox2745.opentlc.com:443/2ffd9811-fc91-4dce-b7c9-ab211622bbfa
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
```

---

## 7. Store the Skupper grant in Vault (site-b link-token)

This step replaces the placeholder “<grant-code-from-site-a>” style instructions and uses the **live** values from the `AccessGrant` you just created.

From your workstation:

```bash
export CONTEXT_SITE_A=site-a
export GRANT_NS="${NS_RHSI}"
export GRANT_NAME=rhsi-standby-grant

# Read the grant's code and URL from .status.*
export GRANT_CODE=$(
  oc --context "${CONTEXT_SITE_A}" -n "${GRANT_NS}" \
    get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.code}'
)

export GRANT_URL=$(
  oc --context "${CONTEXT_SITE_A}" -n "${GRANT_NS}" \
    get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.url}'
)

# Save the grant CA to a local file
oc --context "${CONTEXT_SITE_A}" -n "${GRANT_NS}" \
  get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.ca}' \
  > /tmp/skupper-grant-server-ca.pem

echo "CODE=$GRANT_CODE"
echo "URL=$GRANT_URL"
head -5 /tmp/skupper-grant-server-ca.pem
```

If those look sane (non-empty CODE/URL and a proper PEM header), write them into Vault using the kv v2 helper:

```bash
vault kv put rhsi/site-b/link-token \
  code="$GRANT_CODE" \
  url="$GRANT_URL" \
  ca=@/tmp/skupper-grant-server-ca.pem
```

You can verify:

```bash
vault kv get rhsi/site-b/link-token
```

Expected output:

```text
==== Data ====
Key   Value
---   -----
code  qQWQwLcrhluUq8ROJ8Vggee8
url   https://skupper-grant-server-https-openshift-operators.apps.site-a.sandbox2745.opentlc.com:443/2ffd9811-fc91-4dce-b7c9-ab211622bbfa
ca    -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
```

At this point, Vault holds the current Skupper AccessGrant details for **site-b**.

---

## 8. Sync the grant from Vault into site-b

Now let the External Secrets Operator on **site-b** sync those values into a Kubernetes Secret.

Force a refresh of the `ExternalSecret` and inspect the resulting Secret:

```bash
# Delete any existing target Secret to prove it's recreated
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secret rhsi-link-token --ignore-not-found

# Nudge ESO to reconcile immediately
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" annotate externalsecret rhsi-link-token \
  reconcile.external-secrets.io/requestedAt="$(date -Iseconds)" --overwrite

# Wait a few seconds, then check:
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token -o yaml

# View decoded fields:
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token -o jsonpath='{.data.code}' | base64 -d; echo
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token -o jsonpath='{.data.url}'  | base64 -d; echo
```

You should see the same `code` and `url` that you saw in Vault/AccessGrant.

---

## 9. Create the AccessToken and Skupper Link on site-b

The repo includes a Job manifest that reads the `rhsi-link-token` Secret and creates an `AccessToken` CR named `standby-from-vault`:

```yaml
# rhsi/standby/80-job-create-access-token.yaml (excerpt)
apiVersion: batch/v1
kind: Job
metadata:
  name: create-access-token-from-vault
  namespace: rhsi
spec:
  template:
    spec:
      serviceAccountName: rhsi-operator
      containers:
      - name: create-access-token
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["/bin/sh","-c"]
        args:
        - |
          #!/bin/sh
          set -eu
          echo "Waiting for Secret rhsi-link-token to exist..."
          # ... wait loop ...
          echo "Reading AccessToken fields from Secret rhsi-link-token..."
          CODE=$(oc get secret rhsi-link-token -n rhsi -o jsonpath='{.data.code}' | base64 -d)
          URL=$(oc get secret rhsi-link-token  -n rhsi -o jsonpath='{.data.url}' | base64 -d)
          CA=$(oc get secret rhsi-link-token   -n rhsi -o jsonpath='{.data.ca}'  | base64 -d)
          cat <<EOF | oc apply -f -
          apiVersion: skupper.io/v2alpha1
          kind: AccessToken
          metadata:
            name: standby-from-vault
            namespace: rhsi
          spec:
            code: ${CODE}
            url: ${URL}
            ca: |
          ${CA}
          EOF
      restartPolicy: OnFailure
```

Run the Job on **site-b**:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete accesstoken standby-from-vault --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete job create-access-token-from-vault --ignore-not-found

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f rhsi/standby/80-job-create-access-token.yaml

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get job create-access-token-from-vault
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" logs job/create-access-token-from-vault
```

Example logs:

```text
Waiting for Secret rhsi-link-token to exist...
Secret rhsi-link-token found.
Reading AccessToken fields from Secret rhsi-link-token...
Creating AccessToken standby-from-vault...
accesstoken.skupper.io/standby-from-vault created
AccessToken standby-from-vault created/updated.
```

Check the resulting `AccessToken`:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get accesstoken standby-from-vault -o yaml
```

Working state:

- `.status.status: Ready`
- `.status.redeemed: true`
- `.status.message: OK`

For example:

```yaml
status:
  status: Ready
  message: OK
  redeemed: true
  conditions:
  - type: Redeemed
    status: "True"
    reason: Ready
    message: OK
```

And you should now see a Skupper `Link`:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get link
```

Example:

```text
NAME                 STATUS   REMOTE SITE    MESSAGE
standby-from-vault   Ready    rhsi-primary   OK
```

You can also confirm from the Skupper CLI:

```bash
skupper --context "${CONTEXT_SITE_B}" --namespace "${NS_RHSI}" link status
```

---

## 10. End-to-end Postgres sanity check over Skupper

From **site-b**, exec into the Postgres standby pod and connect to the primary via the Skupper-exposed service name `postgres-primary`:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" exec -it deploy/postgres-standby -- bash

export PGPASSWORD='supersecret'
psql \
  -h postgres-primary \
  -p 5432 \
  -U appuser \
  -d postgres << 'SQL'
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

Sample output:

```text
INSERT 0 1
 id |        site        |          created_at
----+--------------------+-------------------------------
  1 | site-b-via-skupper | 2025-11-26 06:19:38.087877+00
(1 row)
```

At this point you have:

- Skupper sites up and linked (`Link` Ready)
- AccessGrant created on **site-a** and stored in Vault
- External Secrets Operator syncing Vault → `rhsi-link-token` Secret on **site-b**
- Job creating an `AccessToken` and Skupper `Link` from that Secret
- Postgres traffic successfully flowing from **site-b** to **site-a** via Skupper

---

## 11. Common pitfalls & fixes

A few issues you hit and how to avoid them:

### 11.1 404: “No such access granted”

If the `AccessToken` status shows:

```text
Controller got failed response: 404 (Not Found) No such access granted
```

Check:

1. The AccessGrant uses **`spec.redemptionsAllowed`**, not a non-existent field like `uses`.
2. You are using the **current** `status.code` and `status.url` from the AccessGrant when seeding Vault.
3. You haven’t outlived the `expirationWindow`.

A reliable recovery sequence:

```bash
# On site-a
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" delete accessgrant rhsi-standby-grant --ignore-not-found
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" apply -f rhsi/site-a/rhsi-standby-grant.yaml
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" wait --for=condition=Ready --timeout=120s accessgrant rhsi-standby-grant

# Re-extract code/url/ca and re-write Vault
# (repeat the commands in section 7)

# On site-b
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secret rhsi-link-token --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" annotate externalsecret rhsi-link-token \
  reconcile.external-secrets.io/requestedAt="$(date -Iseconds)" --overwrite

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete accesstoken standby-from-vault --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete job create-access-token-from-vault --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f rhsi/standby/80-job-create-access-token.yaml
```

### 11.2 “unsupported protocol scheme \"\"”

If the AccessToken controller reports:

```text
Controller got error: Post "": unsupported protocol scheme ""
```

It means the `url` field in the `AccessToken` spec was empty. This usually happens when:

- Vault’s `site-b/link-token` secret has empty values, or
- The ExternalSecret was synced before you correctly populated Vault.

Fix by:

1. Ensuring `vault kv get rhsi/site-b/link-token` has non-empty `code` and `url`.
2. Deleting and forcing refresh of `rhsi-link-token` on **site-b**.
3. Re-running the AccessToken Job.

---

This README now reflects the **working** configuration and the exact sequence that led to a successful Skupper link and Postgres connectivity via Vault + External Secrets Operator.
