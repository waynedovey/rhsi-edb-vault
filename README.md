# rhsi-edb-vault

Skupper-based connectivity between a **primary** PostgreSQL/EDB instance and a **standby** instance running on a second OpenShift cluster, with the Skupper `AccessToken` bootstrap information stored centrally in **HashiCorp Vault** and surfaced into the standby cluster via **External Secrets Operator (ESO)**.

The flow is:

1. Primary cluster (`site-a`) exposes Postgres via Skupper `listener`.
2. An `AccessGrant` on the primary cluster issues a one‑time grant (code + URL + CA).
3. That grant is written into Vault under `rhsi/site-b/link-token`.
4. On the standby cluster (`site-b`):
   - ESO reads the grant from Vault into a `Secret` (`rhsi-link-token`).
   - A `Job` converts that Secret into a Skupper `AccessToken` CR.
   - The Skupper controller redeems the token and creates a `Link`.
5. The Skupper `connector` on the primary cluster matches the `listener` on the standby, and the Postgres endpoint is reachable across clusters.

---

## 1. Repository layout

```text
rhsi-edb-vault-main/
├─ hub/                                # Argo CD ApplicationSets for all components
│  ├─ 00-namespace-argocd.yaml         # (example) Argo CD namespace/bootstrap
│  ├─ 20-applicationset-rhsi-operator.yaml
│  ├─ 21-applicationset-rhsi.yaml      # primary + standby Skupper/Postgres config
│  ├─ 22-applicationset-rhsi-network-observer.yaml
│  └─ 24-applicationset-rhsi-external-secrets-operator.yaml
├─ rhsi/                               # Workload Kustomizations (applied via Argo)
│  ├─ primary/                         # site-a: Skupper site, Postgres primary, connector
│  └─ standby/                         # site-b: Skupper site, ESO + Vault wiring, listener
├─ rhsi-operator/                      # Skupper operator subscription/CRDs
├─ rhsi-network-observer-operator/     # Skupper Network Observer operator + instance
├─ rhsi-external-secrets-operator/     # External Secrets Operator subscription/CRDs
└─ README.md
```

> **Naming convention**
>
> - **Primary cluster** context: `site-a`
> - **Standby cluster** context: `site-b`
> - **Hub / Argo CD / Vault cluster** context: `hub`
> - Application namespace on both clusters: `rhsi`

Adjust the kubeconfig context names as needed for your environment.

---

## 2. Prerequisites

- Two OpenShift clusters with contexts:
  - `site-a` – primary EDB/Postgres
  - `site-b` – standby EDB/Postgres
- One “hub” OpenShift cluster running:
  - Argo CD
  - HashiCorp Vault (Classic UI/API endpoint), reachable as `https://vault-vault.apps.<hub-domain>`
- CLI tools:
  - `oc`
  - `skupper`
  - `vault`
  - `jq`
  - `openssl`
- A Vault admin token (you can use `root` in a lab, but a dedicated admin policy is recommended in real environments).

Set the following environment variables for convenience:

```bash
export HUB_CONTEXT=hub
export PRIMARY_CONTEXT=site-a
export STANDBY_CONTEXT=site-b
export VAULT_ADDR="https://vault-vault.apps.<hub-domain>"
export VAULT_TOKEN="<your-admin-or-root-token>"
```

---

## 3. Deploy operators and workloads via Argo CD

All operators and workloads are managed from the **hub** cluster via Argo CD ApplicationSets in `hub/`.

From your workstation:

```bash
# Apply all Argo CD objects on the hub cluster
oc --context "${HUB_CONTEXT}" apply -k hub/
```

This will:

1. Create/ensure the `rhsi` namespace on **site-a** and **site-b**.
2. Deploy **Skupper operator** to the application clusters.
3. Deploy **Skupper Network Observer** (optional) to the application clusters.
4. Deploy **External Secrets Operator** (ESO) to the application clusters.
5. Deploy the **primary** Skupper+Postgres stack on `site-a` from `rhsi/primary/`.
6. Deploy the **standby** stack on `site-b` from `rhsi/standby/`, including:
   - The Skupper site.
   - The Vault CA `Secret` (`vault-ca`).
   - The `SecretStore` for Vault (`vault-rhsi`).
   - The `ExternalSecret` (`rhsi-link-token`).
   - The `Job` `create-access-token-from-vault`.

You can verify that the resources have reconciled using:

```bash
oc --context "${PRIMARY_CONTEXT}" -n rhsi get pods,deploy,skupperSites,accessgrants,accesstokens
oc --context "${STANDBY_CONTEXT}" -n rhsi get pods,deploy,skupperSites,externalsecrets.secretstore,secretstores,accesstokens
```

At this point the Skupper sites should exist, but there will be no Skupper **Link** yet on the standby side.

---

## 4. Configure the Vault KV secrets engine

The standby cluster’s `SecretStore` expects a KV v2 mount at path `rhsi/`.

### 4.1 Enable KV v2 at `rhsi/` (if it does not exist yet)

```bash
vault secrets list | grep '^rhsi/' ||   vault secrets enable -path=rhsi -version=2 kv
```

You should see:

```bash
vault secrets list | grep '^rhsi/'
rhsi/    kv    kv_...    n/a
```

---

## 5. Configure Kubernetes auth for the standby cluster

ESO on the standby cluster uses **Vault Kubernetes auth** at mount path `auth/kubernetes-site-b`.

### 5.1 Enable the auth method (once only)

```bash
vault auth list | grep 'kubernetes-site-b' ||   vault auth enable -path=kubernetes-site-b kubernetes
```

### 5.2 Configure the Kubernetes auth backend

Grab the **service account token**, **API server URL**, and **cluster CA** from the standby cluster:

```bash
export REVIEWER_JWT=$(
  oc --context "${STANDBY_CONTEXT}" -n rhsi create token rhsi-vault-reader
)

export KUBE_HOST=$(
  oc --context "${STANDBY_CONTEXT}" config view --minify -o jsonpath='{.clusters[0].cluster.server}'
)

export KUBE_CA_CRT=$(
  oc --context "${STANDBY_CONTEXT}" -n kube-public     get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}'
)
```

Write the Vault auth config:

```bash
vault write auth/kubernetes-site-b/config   token_reviewer_jwt="$REVIEWER_JWT"   kubernetes_host="$KUBE_HOST"   kubernetes_ca_cert="$KUBE_CA_CRT"
```

### 5.3 Create a policy and role for the standby cluster

Create a Vault policy `rhsi-site-b` that allows ESO to read the link token:

```hcl
# file: rhsi-site-b.hcl
path "rhsi/data/site-b/link-token" {
  capabilities = ["read"]
}
```

Load the policy:

```bash
vault policy write rhsi-site-b rhsi-site-b.hcl
```

Create the role bound to the `rhsi-vault-reader` service account in the `rhsi` namespace:

```bash
vault write auth/kubernetes-site-b/role/rhsi-site-b   bound_service_account_names="rhsi-vault-reader"   bound_service_account_namespaces="rhsi"   token_policies="rhsi-site-b"   ttl="1h"
```

You can test the role from your workstation:

```bash
LOGIN_JWT=$(oc --context "${STANDBY_CONTEXT}" -n rhsi create token rhsi-vault-reader)

vault write auth/kubernetes-site-b/login   role="rhsi-site-b"   jwt="$LOGIN_JWT"
```

This should return a short‑lived `hvs.` token and list the `rhsi-site-b` policy.

At this point, the `SecretStore` on `site-b` should become **Ready**:

```bash
oc --context "${STANDBY_CONTEXT}" -n rhsi describe secretstore vault-rhsi
```

Look for:

```text
Status:
  Capabilities:  ReadWrite
  Conditions:
    Type:     Ready
    Status:   True
```

---

## 6. Create an AccessGrant on the primary cluster

On the **primary** cluster (`site-a`), apply the `AccessGrant`:

```bash
cat <<EOF | oc --context "${PRIMARY_CONTEXT}" -n rhsi apply -f -
apiVersion: skupper.io/v2alpha1
kind: AccessGrant
metadata:
  name: rhsi-standby-grant
spec:
  expirationWindow: 1h
  redemptionsAllowed: 1
EOF
```

Check its status:

```bash
oc --context "${PRIMARY_CONTEXT}" -n rhsi get accessgrant rhsi-standby-grant
oc --context "${PRIMARY_CONTEXT}" -n rhsi get accessgrant rhsi-standby-grant -o yaml
```

You should see fields under `.status`:

- `.status.code`
- `.status.url`
- `.status.ca`
- `.status.expirationTime`
- `.status.redemptionsAllowed`

Extract these into temporary files:

```bash
oc --context "${PRIMARY_CONTEXT}" -n rhsi   get accessgrant rhsi-standby-grant   -o jsonpath='{.status.code}' > /tmp/grant-code

oc --context "${PRIMARY_CONTEXT}" -n rhsi   get accessgrant rhsi-standby-grant   -o jsonpath='{.status.url}' > /tmp/grant-url

oc --context "${PRIMARY_CONTEXT}" -n rhsi   get accessgrant rhsi-standby-grant   -o jsonpath='{.status.ca}'  > /tmp/grant-ca.pem

cat /tmp/grant-code
cat /tmp/grant-url
openssl x509 -in /tmp/grant-ca.pem -noout -subject -issuer
```

---

## 7. Export the AccessGrant into Vault (site-b link token)

Now write the grant data into Vault under the key `rhsi/site-b/link-token` using KV v2 semantics.

First, load environment variables:

```bash
export CODE="$(cat /tmp/grant-code)"
export URL="$(cat /tmp/grant-url)"
```

Create a JSON payload containing the grant `code`, `url`, and `ca`:

```bash
CA_JSON=$(python3 - <<'EOF'
import json, os, pathlib
pem = pathlib.Path("/tmp/grant-ca.pem").read_text()
code = os.environ["CODE"]
url  = os.environ["URL"]
print(json.dumps({"data": {"code": code, "url": url, "ca": pem}}))
EOF
)
```

Write it into Vault:

```bash
curl   --silent   --show-error   --header "X-Vault-Token: $VAULT_TOKEN"   --header "Content-Type: application/json"   --request POST   --data "$CA_JSON"   "$VAULT_ADDR/v1/rhsi/data/site-b/link-token"
```

You can verify:

```bash
curl   --silent   --show-error   --header "X-Vault-Token: $VAULT_TOKEN"   "$VAULT_ADDR/v1/rhsi/data/site-b/link-token" | jq '.data.data'
```

You should see:

```json
{
  "ca":  "-----BEGIN CERTIFICATE----- ...",
  "code": "G4ihP5o7BRUpETPxeSKMhhiE",
  "url":  "https://skupper-grant-server-https-openshift-operators.apps.site-a.../5527d57f-bfa4-4ade-808d-cd9b3ccb0558"
}
```

---

## 8. Allow ESO to refresh `rhsi-link-token`

The standby cluster’s `ExternalSecret` is defined in:

- `rhsi/standby/75-externalsecret-rhsi-link-token.yaml`

It reads from:

```yaml
spec:
  dataFrom:
    - extract:
        key: site-b/link-token
  secretStoreRef:
    name: vault-rhsi
  target:
    name: rhsi-link-token
```

After you write the data into Vault, you can either wait for the ESO refresh interval (5 minutes) or force an immediate reconciliation by annotating the `ExternalSecret`:

```bash
oc --context "${STANDBY_CONTEXT}" -n rhsi annotate externalsecret rhsi-link-token   reconciled-at="$(date +%s)" --overwrite
```

Verify the Secret:

```bash
oc --context "${STANDBY_CONTEXT}" -n rhsi get secret rhsi-link-token -o yaml

# Decode the code and URL
oc --context "${STANDBY_CONTEXT}" -n rhsi get secret rhsi-link-token   -o jsonpath='{.data.code}' | base64 -d; echo

oc --context "${STANDBY_CONTEXT}" -n rhsi get secret rhsi-link-token   -o jsonpath='{.data.url}' | base64 -d; echo
```

You should see the same `code` and `url` as the `AccessGrant` on site-a.

---

## 9. Create the AccessToken from Vault on the standby cluster

The job manifest at `rhsi/standby/80-job-create-access-token.yaml` defines a `Job` named `create-access-token-from-vault` that:

1. Waits for the `rhsi-link-token` Secret.
2. Reads `ca`, `code`, and `url` from the Secret.
3. Creates or updates the Skupper `AccessToken` named `standby-from-vault` in the `rhsi` namespace.

If Argo CD has already synced the standby Kustomization, the Job will exist and may already have run once. You can re‑run it at any time:

```bash
oc --context "${STANDBY_CONTEXT}" -n rhsi delete job create-access-token-from-vault --ignore-not-found
oc --context "${STANDBY_CONTEXT}" -n rhsi logs -f job/create-access-token-from-vault
```

When it completes, you should see:

```text
Waiting for Secret rhsi-link-token to exist...
Secret rhsi-link-token found.
Reading AccessToken fields from Secret rhsi-link-token...
Creating AccessToken standby-from-vault...
accesstoken.skupper.io/standby-from-vault created
AccessToken standby-from-vault created/updated.
```

Check the `AccessToken`:

```bash
oc --context "${STANDBY_CONTEXT}" -n rhsi get accesstoken standby-from-vault -o yaml
```

Expected status:

```yaml
status:
  status: Ready
  redeemed: true
  message: OK
  conditions:
    - type: Redeemed
      status: "True"
      reason: Ready
      message: OK
```

---

## 10. Verify Skupper link and endpoint status

Finally, verify from the Skupper CLI:

```bash
# On standby (site-b)
skupper --context "${STANDBY_CONTEXT}" -n rhsi link status
skupper --context "${STANDBY_CONTEXT}" -n rhsi listener status

# On primary (site-a)
skupper --context "${PRIMARY_CONTEXT}" -n rhsi connector status
```

You should see:

- A **Link** named `standby-from-vault` in `Ready` state on the standby cluster.
- A `listener` called `postgres-primary` in `Ready` state on the standby cluster.
- A `connector` called `postgres` in `Ready` state on the primary cluster.
- Both `listener` and `connector` showing `HAS MATCHING CONNECTOR/LISTENER: true` and `MESSAGE: OK`.

Example:

```text
$ skupper --context site-b -n rhsi link status
NAME                 STATUS   COST   MESSAGE
standby-from-vault   Ready    0      OK

$ skupper --context site-b -n rhsi listener status
NAME               STATUS   ROUTING-KEY  HOST              PORT  MATCHING-CONNECTOR  MESSAGE
postgres-primary   Ready    postgres     postgres-primary  5432  true                OK

$ skupper --context site-a -n rhsi connector status
NAME       STATUS   ROUTING-KEY  SELECTOR              HOST  PORT  HAS MATCHING LISTENER  MESSAGE
postgres   Ready    postgres     app=postgres-primary        5432  true                   OK
```

At this point the standby cluster can reach the primary Postgres endpoint across the Skupper link.

---

## 11. Rotating the AccessGrant / AccessToken

To rotate the link:

1. **Delete** the existing `AccessGrant` on the primary, then create a new one:

   ```bash
   oc --context "${PRIMARY_CONTEXT}" -n rhsi delete accessgrant rhsi-standby-grant --ignore-not-found
   # Re‑create using the manifest from section 6
   ```

2. Repeat **section 6** and **section 7** to export the new grant into Vault.
3. Force ESO to refresh the `rhsi-link-token` Secret (section 8).
4. Re‑run the Job on the standby cluster (section 9).

Skupper will redeem the new token, and the link will return to `Ready`.

---

## 12. Troubleshooting

### 12.1 `SecretStore "vault-rhsi" is not ready`

Symptoms in `ExternalSecret` status:

```text
error processing spec.dataFrom[0].extract, err: SecretStore "vault-rhsi" is not ready
```

And in the `SecretStore` events:

```text
unable to log in to auth method: unable to log in with Kubernetes auth:
Error making API request.
URL: PUT https://vault-vault.../v1/auth/kubernetes-site-b/login
Code: 403. Errors: ["permission denied"]
```

Check:

1. `auth/kubernetes-site-b/config` has the **correct** `token_reviewer_jwt`, `kubernetes_host`, and `kubernetes_ca_cert` for the **standby** cluster (`site-b`).
2. The `rhsi-site-b` policy allows `read` on `rhsi/data/site-b/link-token`.
3. The Vault role `rhsi-site-b` is bound to:
   - `bound_service_account_names = ["rhsi-vault-reader"]`
   - `bound_service_account_namespaces = ["rhsi"]`
4. The `rhsi-vault-reader` ServiceAccount exists in the `rhsi` namespace on `site-b`.

After fixing, annotate the `SecretStore` to trigger a fast retry:

```bash
oc --context "${STANDBY_CONTEXT}" -n rhsi annotate secretstore vault-rhsi   reconciled-at="$(date +%s)" --overwrite
```

### 12.2 `AccessToken` stuck with `404 (Not Found) No such claim`

If the `AccessToken` shows:

```yaml
status:
  status: Error
  message: 'Controller got failed response: 404 (Not Found) No such claim'
```

This means the grant has **expired** or has already been **redeemed** (and `redemptionsAllowed` was `1`).

Fix:

1. Delete the old `AccessGrant` on `site-a`.
2. Create a new `AccessGrant` as in section 6.
3. Export the new grant into Vault (section 7).
4. Refresh the `ExternalSecret` (section 8).
5. Re‑run the Job (section 9).

---

## 13. Cleaning up

To remove all Skupper/Vault plumbing:

```bash
# Disable Argo CD sync (or delete the ApplicationSets) on the hub cluster
oc --context "${HUB_CONTEXT}" delete -k hub/

# (Optional) Remove the KV data and auth role/policies
vault delete rhsi/data/site-b/link-token
vault delete auth/kubernetes-site-b/role/rhsi-site-b
vault policy delete rhsi-site-b
# vault secrets disable rhsi   # only if nothing else uses this mount
```

This leaves Vault itself intact but removes the Skupper/Vault wiring used for the cross‑cluster Postgres link.
