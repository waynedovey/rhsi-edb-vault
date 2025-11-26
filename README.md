# RHSi Postgres Skupper Link via Vault + External Secrets

This repository demonstrates how to establish a **Skupper v2** link between a
**primary** and **standby** OpenShift cluster using:

- A short‑lived **AccessGrant** on the primary site (`site-a`)
- **HashiCorp Vault** (KV v2) as the secure store for the grant code / URL / CA
- **External Secrets Operator** (ESO) on the standby site (`site-b`)
- A one‑shot **Job** on `site-b` that turns the Vault secret into a Skupper
  **AccessToken**, which the Skupper controller then redeems to create the link

The worked example uses a simple **PostgreSQL primary / standby** pair connected
via Skupper.

---

## 1. Prerequisites

You should already have:

- Two OpenShift clusters:
  - `site-a` (primary)
  - `site-b` (standby)
- A namespace on both clusters (examples below use `rhsi`)
- Skupper v2 operator and network observer deployed on both clusters
- External Secrets Operator (ESO) deployed on `site-b`
- A Vault instance that you can reach with the `vault` CLI

The examples assume the following environment variables:

```bash
export CONTEXT_SITE_A=site-a
export CONTEXT_SITE_B=site-b
export NS_RHSI=rhsi
```

Adjust these as needed for your environment.

---

## 2. Deploy base components via ACM / GitOps

From this repo, apply the ACM / Argo CD resources that deploy:

- The `rhsi` namespace on each managed cluster
- Skupper sites (`rhsi-primary`, `rhsi-standby`)
- The Postgres primary and standby deployments
- ESO and Skupper network observer

```bash
oc apply -f hub/
```

You can verify that Skupper sites and Postgres pods are up:

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" get site,listener,connector,pods
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get site,listener,connector,pods
```

At this point you should see:

- A **Skupper site** and **Postgres primary** pod on `site-a`
- A **Skupper site** and **Postgres standby** pod on `site-b`

---

## 3. Configure Vault for `site-b`

All of the following `vault` commands are executed from wherever you have
`vault` CLI access to your Vault server.

### 3.1 Enable KV v2 at `rhsi/`

```bash
vault secrets enable -path=rhsi kv-v2
```

This will hold the Skupper grant data under `rhsi/data/site-b/link-token`.

### 3.2 Configure Kubernetes auth for `site-b`

We use a dedicated `vault-auth` ServiceAccount on **site-b** as the token
reviewer for Vault. This ServiceAccount is only used by Vault to call the
Kubernetes TokenReview API.

1. Create the `vault-auth` ServiceAccount and bind it to the
   `system:auth-delegator` ClusterRole:

   ```bash
   oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" create sa vault-auth || true

   oc --context "${CONTEXT_SITE_B}" create clusterrolebinding vault-auth-delegator-site-b \
     --clusterrole=system:auth-delegator \
     --serviceaccount="${NS_RHSI}:vault-auth" 2>/dev/null || true
   ```

2. Create a token Secret for `vault-auth`:

   ```bash
   cat <<'EOF' | oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
     name: vault-auth-token
     annotations:
       kubernetes.io/service-account.name: vault-auth
   type: kubernetes.io/service-account-token
   EOF
   ```

3. Extract the reviewer JWT and the cluster CA from the `vault-auth-token`
   Secret, and capture the Kubernetes API URL:

   ```bash
   export VAULT_REVIEWER_JWT=$(
     oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret vault-auth-token \
       -o jsonpath='{.data.token}' | base64 -d
   )

   oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" \
     get secret vault-auth-token \
     -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/site-b-ca.crt

   export KUBE_HOST=$(
     oc --context "${CONTEXT_SITE_B}" config view --minify \
       -o jsonpath='{.clusters[0].cluster.server}'
   )
   ```

4. Configure the Kubernetes auth backend in Vault, using the reviewer JWT and
   the CA file:

   ```bash
   vault auth enable -path=kubernetes-site-b kubernetes || true

   vault write auth/kubernetes-site-b/config \
     token_reviewer_jwt="$VAULT_REVIEWER_JWT" \
     kubernetes_host="$KUBE_HOST" \
     kubernetes_ca_cert=@/tmp/site-b-ca.crt \
     disable_iss_validation=true
   ```

### 3.3 Policy and role for `rhsi-vault-reader`

Create a policy that allows read access to the `site-b` link-token path:

```bash
vault policy write rhsi-site-b - << 'EOF'
path "rhsi/data/site-b/*" {
  capabilities = ["read"]
}
EOF
```

Create a Kubernetes auth role that binds the policy to the
`rhsi-vault-reader` ServiceAccount in the `rhsi` namespace:

```bash
vault write auth/kubernetes-site-b/role/rhsi-site-b \
  bound_service_account_names="rhsi-vault-reader" \
  bound_service_account_namespaces="${NS_RHSI}" \
  token_policies="rhsi-site-b" \
  token_ttl="1h" \
  token_max_ttl="24h"
```

> The `token_ttl` here is aligned with the `expirationWindow` of the Skupper
> AccessGrant we’ll create in the next section.
---

## 4. External Secrets configuration on `site-b`

The manifests under `rhsi/standby/` create the ESO integration (deployed via Argo CD):

- `SecretStore` `vault-rhsi` (points at the Vault server and `rhsi` KV)
- `ExternalSecret` `rhsi-link-token` (reads `site-b/link-token` from Vault)
- The `rhsi-vault-reader` `ServiceAccount` (used by ESO)
- A one‑shot `Job` `create-access-token-from-vault` (creates the Skupper
  `AccessToken` from the synced Secret)


```bash
```

You can confirm the `SecretStore` and `ExternalSecret` exist:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secretstore vault-rhsi
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get externalsecret rhsi-link-token
```

Initially, the `ExternalSecret` will report an error until the Vault secret
is populated in the next steps.

---

## 5. Create the Skupper AccessGrant on `site-a`

The AccessGrant is created on the **primary** site (`site-a`) and is
responsible for issuing Skupper link credentials.

Apply the AccessGrant manifest:

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" apply -f rhsi/site-a/rhsi-standby-grant.yaml
```

The manifest should look like this:

```yaml
apiVersion: skupper.io/v2alpha1
kind: AccessGrant
metadata:
  name: rhsi-standby-grant
  namespace: rhsi
spec:
  expirationWindow: 1h
  # Maximum number of redemptions allowed for this grant
  redemptionsAllowed: 100
  securedAccess:
    name: skupper-grant-server
```

Wait for the AccessGrant to become ready:

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" wait   --for=condition=Ready   --timeout=120s   accessgrant rhsi-standby-grant

oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" get accessgrant rhsi-standby-grant
```

You should see `STATUS: Ready` and the `EXPIRATION` time in the future.

---

## 6. Push the AccessGrant data into Vault

Read the grant code / URL / CA from the AccessGrant status on `site-a` and
write them into Vault under `rhsi/data/site-b/link-token`.

First, capture the fields:

```bash
export GRANT_NS="${NS_RHSI}"
export GRANT_NAME=rhsi-standby-grant

export GRANT_CODE=$(
  oc --context "${CONTEXT_SITE_A}" -n "${GRANT_NS}"     get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.code}'
)

export GRANT_URL=$(
  oc --context "${CONTEXT_SITE_A}" -n "${GRANT_NS}"     get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.url}'
)

oc --context "${CONTEXT_SITE_A}" -n "${GRANT_NS}"   get accessgrant "${GRANT_NAME}" -o jsonpath='{.status.ca}'   > /tmp/skupper-grant-server-ca.pem
```

Then write them into Vault:

```bash
vault kv put rhsi/site-b/link-token   code="$GRANT_CODE"   url="$GRANT_URL"   ca=@/tmp/skupper-grant-server-ca.pem
```

You can confirm the data in Vault:

```bash
vault kv get rhsi/site-b/link-token
```

---

## 7. Let ESO sync the link token to `site-b`

On `site-b`, ESO will read `rhsi/data/site-b/link-token` from Vault and
materialise it as a Secret `rhsi-link-token` in the `rhsi` namespace.

To force an immediate refresh, delete any existing Secret and annotate the
`ExternalSecret`:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secret rhsi-link-token --ignore-not-found

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" annotate externalsecret rhsi-link-token   reconcile.external-secrets.io/requestedAt="$(date -Iseconds)" --overwrite
```

Wait for the Secret to appear and inspect it:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret rhsi-link-token -o yaml

# Decode and verify the fields (optional)
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}"   get secret rhsi-link-token -o jsonpath='{.data.code}' | base64 -d; echo

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}"   get secret rhsi-link-token -o jsonpath='{.data.url}' | base64 -d; echo
```

The decoded `code` and `url` should match the AccessGrant on `site-a`.

---

## 8. Create the Skupper AccessToken from Vault on `site-b`

Now that `rhsi-link-token` exists on `site-b`, run the Job that creates the
Skupper `AccessToken` object from that Secret.

```bash
```

Wait for the Job to complete:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" wait   --for=condition=Complete   --timeout=60s   job/create-access-token-from-vault

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" logs job/create-access-token-from-vault
```

You should see log output similar to:

```text
Waiting for Secret rhsi-link-token to exist...
Secret rhsi-link-token found.
Reading AccessToken fields from Secret rhsi-link-token...
Creating AccessToken standby-from-vault...
accesstoken.skupper.io/standby-from-vault created
AccessToken standby-from-vault created/updated.
```

Check the AccessToken:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get accesstoken standby-from-vault -o yaml
```

---

## 9. Verify the Skupper link

Skupper should automatically redeem the AccessToken against the AccessGrant
on `site-a` and establish a link.

Check the link resource on `site-b`:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get link
```

Example output:

```text
NAME                 STATUS   REMOTE SITE    MESSAGE
standby-from-vault   Ready    rhsi-primary   OK
```

You can also use the Skupper CLI:

```bash
skupper --context "${CONTEXT_SITE_B}" --namespace "${NS_RHSI}" link status
```

You should see `STATUS: Ready` and `MESSAGE: OK`.

---

## 10. End-to-end Postgres test

Finally, confirm that the standby site can reach the Postgres primary over
the Skupper link.

From `site-b`:

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
  1 | site-b-via-skupper | 2025-11-26 08:05:10.609326+00
(1 row)
```

At this point the Skupper link is operational and traffic from `site-b`
to `postgres-primary` is flowing over the Skupper network.

---

## 11. Rotating the link credentials

When you want to rotate the Skupper link credentials:

1. **Create a new AccessGrant** on `site-a` (you can reuse the same name;
   Skupper will generate a new code/URL/CA):

   ```bash
   oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" apply -f rhsi/site-a/rhsi-standby-grant.yaml

   oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" wait      --for=condition=Ready      --timeout=120s      accessgrant rhsi-standby-grant
   ```

2. **Update Vault** with the new grant values (repeat section 6):

   ```bash
   # Re-run the GRANT_CODE / GRANT_URL / CA extraction
   # then:
   vault kv put rhsi/site-b/link-token      code="$GRANT_CODE"      url="$GRANT_URL"      ca=@/tmp/skupper-grant-server-ca.pem
   ```

3. **Force ESO to refresh** `rhsi-link-token` (repeat section 7).

4. **Re-run the Job** on `site-b` (repeat section 8):

   ```bash
   oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete accesstoken standby-from-vault --ignore-not-found
   oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete job create-access-token-from-vault --ignore-not-found

   ```

5. Verify the Skupper link is still `Ready` (section 9).

This gives you a repeatable, Vault‑backed rotation procedure without having
to manually juggle Skupper tokens on the standby cluster.

---

## 12. Cleanup / Lab reset

If you want to tear everything down and re-test from scratch, you can use the
following as a guide. **Double-check names and contexts before running in a
shared environment.**

### 12.1 Remove Skupper objects on `site-b`

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete accesstoken standby-from-vault --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete skupperlink --all --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete servicebinding skupper-network --ignore-not-found 2>/dev/null || true
```

### 12.2 Remove ESO integration on `site-b`

These resources are normally managed by Argo CD in this lab, but if you
applied them manually you can remove them with:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete externalsecret rhsi-link-token --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secretstore vault-rhsi --ignore-not-found
```

If Argo CD manages them, just disable or delete the `rhsi-standby-site-b`
Application instead and let Argo handle the cleanup.

### 12.3 Optional: remove Vault data and auth for this lab

From the shell where `VAULT_ADDR` / `VAULT_TOKEN` are set:

```bash
# Delete the Skupper link-token data for site-b
vault kv delete rhsi/site-b/link-token || true

# Remove the kubernetes auth role and method for site-b (if this lab is dedicated)
vault delete auth/kubernetes-site-b/role/rhsi-site-b || true
# vault auth disable kubernetes-site-b || true
```

### 12.4 Optional: remove helper ServiceAccounts on `site-b`

If you want a completely clean cluster:

```bash
# Remove the Vault reviewer SA and its token
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete secret vault-auth-token --ignore-not-found
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete sa vault-auth --ignore-not-found
oc --context "${CONTEXT_SITE_B}" delete clusterrolebinding vault-auth-delegator-site-b --ignore-not-found

# (Only if you no longer need ESO to read from Vault)
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete sa rhsi-vault-reader --ignore-not-found || true
```

Use this section as a template and adapt it to your own naming conventions /
GitOps layout for a full end-to-end reset.
