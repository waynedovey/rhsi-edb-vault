# RHSi EDB Postgres Skupper Link via Vault + External Secrets

> **Note:** This repo uses **EDB CloudNativePG** as the canonical
> PostgreSQL implementation. All data‑plane examples should be treated
> as EDB‑backed, and the manifests under `rhsi/site-a/db-edb` and
> `rhsi/site-b/db-edb` are the source of truth.

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

1. Grab the cluster CA for `site-b`:

   ```bash
   oc --context "${CONTEXT_SITE_B}" -n kube-public      get configmap kube-root-ca.crt      -o jsonpath='{.data.ca\.crt}' > /tmp/site-b-ca.crt
   ```

2. Create a token for the `rhsi-vault-reader` service account on `site-b`:

   ```bash
   export REVIEWER_JWT=$(
     oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}"        create token rhsi-vault-reader
   )
   ```

3. Enable a Kubernetes auth mount for `site-b`:

   ```bash
   vault auth enable -path=kubernetes-site-b kubernetes
   ```

4. Capture the `site-b` API server URL and CA:

   ```bash
   export KUBE_HOST=$(
     oc --context "${CONTEXT_SITE_B}" config view --minify        -o jsonpath='{.clusters[0].cluster.server}'
   )

   export KUBE_CA_CRT=$(cat /tmp/site-b-ca.crt)
   ```

5. Configure the Kubernetes auth backend:

   ```bash
   vault write auth/kubernetes-site-b/config      token_reviewer_jwt="$REVIEWER_JWT"      kubernetes_host="$KUBE_HOST"      kubernetes_ca_cert="$KUBE_CA_CRT"
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
`rhsi-vault-reader` service account in the `rhsi` namespace:

```bash
vault write auth/kubernetes-site-b/role/rhsi-site-b   bound_service_account_names="rhsi-vault-reader"   bound_service_account_namespaces="${NS_RHSI}"   token_policies="rhsi-site-b"   ttl="1h"
```

> The `ttl` here is aligned with the `expirationWindow` of the Skupper
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

## 10. End-to-end EDB connectivity test over Skupper

Finally, confirm that the standby site (`site-b`) can reach the EDB primary
(`edb-site-a`) over the Skupper link.

From `site-b`, first obtain the EDB superuser password (for example, from
the `edb-site-b-superuser` secret):

```bash
oc --context "${CONTEXT_SITE_B}" -n db \
  get secret edb-site-b-superuser \
  -o jsonpath='{.data.password}' | base64 -d

# Copy the value and export it into your shell:
export PGPASSWORD='<copied password>'
```

Then launch a one-shot client pod on `site-b` in the `db` namespace:

```bash
oc --context "${CONTEXT_SITE_B}" -n db run edb-skupper-test \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  -it --rm --restart=Never -- \
  bash
```

Inside the pod:

```bash
microdnf install -y postgresql

psql \
  -h edb-site-a.rhsi.svc.cluster.local \
  -p 5432 \
  -U postgres \
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
to the EDB cluster on `site-a` (`edb-site-a`) is flowing over the
Skupper network.

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

## 11. EDB CloudNativePG two-way replication over Skupper (EDB-only path)

This repo now includes an **EDB CloudNativePG** example using **PostgreSQL 16**
with **two-way logical replication** between the primary site (`site-a`) and
the standby site (`site-b`), bridged by Skupper.

### 11.1. Prerequisites

- EDB Postgres AI / CloudNativePG operator installed on both clusters
  (for example via OperatorHub or EDB-provided manifests). This installs the
  `postgresql.k8s.enterprisedb.io` CRDs (`Cluster`, `Publication`,
  `Subscription`, etc.).
- Skupper v2 sites already configured between `site-a` and `site-b` as per the
  earlier sections (`rhsi/site-a/site.yaml`, `rhsi/site-b/site.yaml`).
- A `db` namespace on both clusters:
  - `rhsi/site-a/db-primary/namespace-db.yaml`
  - `rhsi/site-b/db-standby/namespace-db.yaml`

### 11.2. Store the EDB Repos 2 token in Vault

Store your **EDB Repos 2** subscription token in Vault under the existing
`rhsi` KV v2 engine:

```bash
export VAULT_ADDR="https://vault-vault.apps.acm.sandbox2745.opentlc.com"
export VAULT_TOKEN="<your_vault_admin_token>"

vault kv put rhsi/edb-repos2 \
  token="<YOUR_EDB_REPOS2_TOKEN>"
```

An `ExternalSecret` in `rhsi/standby/76-externalsecret-edb-repos2-token.yaml`
projects this Vault entry into the `rhsi` namespace as a secret named
`edb-repos2-token`. You can then use that secret as input for a Job or script
that creates a `docker-registry` imagePullSecret for `docker.enterprisedb.com`
(as required by the EDB images).

> The actual token value must never be committed to Git. Only the Vault path
> and secret name appear in this repo.

### 11.3. Deploy the EDB clusters

On **site-a**:

```bash
CONTEXT_SITE_A=site-a
NS_DB=db

oc --context "${CONTEXT_SITE_A}" apply -f rhsi/site-a/db-primary/namespace-db.yaml
oc --context "${CONTEXT_SITE_A}" -n "${NS_DB}" apply -f rhsi/site-a/db-edb/
```

On **site-b**:

```bash
CONTEXT_SITE_B=site-b
NS_DB=db

oc --context "${CONTEXT_SITE_B}" apply -f rhsi/site-b/db-standby/namespace-db.yaml
oc --context "${CONTEXT_SITE_B}" -n "${NS_DB}" apply -f rhsi/site-b/db-edb/
```

These manifests create:

- A single-instance **EDB CloudNativePG** cluster on each site
  (`edb-site-a` and `edb-site-b` in namespace `db`)
- Superuser credentials in `edb-site-a-superuser` and `edb-site-b-superuser`
- Optional init Jobs that create demo tables `site_a_data` and `site_b_data`

> Adjust the `storageClass` and passwords in
> `rhsi/site-a/db-edb/20-edb-site-a-cluster.yaml` and
> `rhsi/site-b/db-edb/20-edb-site-b-cluster.yaml` before applying.

If you see errors like:

> `no matches for kind "Cluster" in version "postgresql.k8s.enterprisedb.io/v1"`

that means the **EDB / CloudNativePG operator CRDs are not installed yet**.
Install the operator first, then re-apply the `db-edb` manifests.

### 11.4. Skupper wiring for the EDB clusters

The Skupper **Connector** and **Listener** manifests are under:

- `rhsi/site-a/60-edb-site-a-connector.yaml`
- `rhsi/site-a/61-edb-site-b-listener.yaml`
- `rhsi/site-b/60-edb-site-b-connector.yaml`
- `rhsi/site-b/61-edb-site-a-listener.yaml`

These create:

- A Connector on `site-a` that exposes the `edb-site-a` cluster to the Skupper
  network with routing key `edb-site-a`, selecting pods with
  `cnpg.io/cluster=edb-site-a` in namespace `db`.
- A Listener on `site-b` that makes `edb-site-a` reachable as
  `edb-site-a.rhsi.svc.cluster.local:5432`.
- Similarly in the other direction for `edb-site-b`.

The `externalClusters` section in the EDB `Cluster` CRs uses these hostnames:

- On `site-a` (`edb-site-a`), the remote `site-b` cluster is reached at
  `edb-site-b.rhsi.svc.cluster.local`.
- On `site-b` (`edb-site-b`), the remote `site-a` cluster is reached at
  `edb-site-a.rhsi.svc.cluster.local`.

### 11.5. Two-way logical replication

Two-way logical replication is configured via the `Publication` and
`Subscription` resources:

- `rhsi/site-a/db-edb/40-edb-site-a-publication.yaml`
- `rhsi/site-a/db-edb/50-edb-site-a-subscription-from-b.yaml`
- `rhsi/site-b/db-edb/40-edb-site-b-publication.yaml`
- `rhsi/site-b/db-edb/50-edb-site-b-subscription-from-a.yaml`

Each site:

- Publishes changes from its local `postgres` database
  (`site_a_pub` on `edb-site-a`, `site_b_pub` on `edb-site-b`)
- Subscribes to the other site's publication using the `externalClusters`
  entries (`site-a` and `site-b`)

This yields **two-way logical replication** between the two EDB clusters over
the Skupper link.

For a real deployment you will usually:

- Restrict publications to specific tables/schemas instead of `allTables`
- Avoid write conflicts by ensuring that each site owns different tables or
  key ranges, or move to **EDB Postgres Distributed** if you need full
  multi-master with conflict resolution.

### 11.6. Smoke test

Once the clusters, Skupper resources, and `Publication` / `Subscription`
objects are all in `Ready` state, you can test replication.

Example: write on **site-a**, read on **site-b**:

```bash
# Insert on site-a
oc --context "${CONTEXT_SITE_A}" -n db exec -it deploy/edb-site-a-rw -- \
  bash -c 'psql -U postgres -d postgres -c "INSERT INTO site_a_data (payload) VALUES (''from-site-a'');"'

# Read from site-b
oc --context "${CONTEXT_SITE_B}" -n db exec -it deploy/edb-site-b-rw -- \
  bash -c 'psql -U postgres -d postgres -c "SELECT * FROM site_a_data ORDER BY id DESC LIMIT 5;"'
```

And the reverse for `site_b_data`:

```bash
# Insert on site-b
oc --context "${CONTEXT_SITE_B}" -n db exec -it deploy/edb-site-b-rw -- \
  bash -c 'psql -U postgres -d postgres -c "INSERT INTO site_b_data (payload) VALUES (''from-site-b'');"'

# Read from site-a
oc --context "${CONTEXT_SITE_A}" -n db exec -it deploy/edb-site-a-rw -- \
  bash -c 'psql -U postgres -d postgres -c "SELECT * FROM site_b_data ORDER BY id DESC LIMIT 5;"'
```

If you see rows flowing in both directions, your EDB two-way replication over
Skupper is working.
