# RHSI EDB + Vault + Skupper Demo

This repo shows a reference implementation of:

- EDB Postgres (Cloud Native PostgreSQL operator) running on two OpenShift clusters:
  - **Site A** – primary EDB cluster
  - **Site B** – standby EDB cluster
- **Skupper** providing secure L3 connectivity between the sites.
- **HashiCorp Vault** as the source of truth for:
  - Skupper link token (`site-b/link-token`)
  - EDB repos token (`edb-repos2`)
- **External Secrets Operator (ESO)** pulling secrets from Vault into `Secret`s.
- Simple **Jobs** that materialise those secrets into the final K8s `Secret`s consumed by:
  - Skupper link (`skupper-access-token-from-vault`)
  - EDB operator pull secret (`edb-operator-pullsecret-from-vault`)

This README documents **Option A** (Vault + External Secrets + one-shot Jobs). It assumes you already have working OpenShift clusters and ACM.

---

## 0. Repo layout

```text
.
├── README.md
├── hub/
│   ├── 05-managedclustersetbinding-rhsi-clusters.yaml
│   ├── 10-placement-rhsi-primary.yaml
│   ├── 11-placement-rhsi-standby.yaml
│   ├── 12-placement-rhsi-operator.yaml
│   ├── 13-placement-rhsi-network-observer-operator.yaml
│   ├── 14-placement-rhsi-external-secrets-operator.yaml
│   ├── 20-applicationset-rhsi-primary.yaml
│   ├── 21-applicationset-rhsi-standby.yaml
│   ├── 22-applicationset-rhsi-operator.yaml
│   ├── 23-applicationset-rhsi-network-observer-operator.yaml
│   └── 24-applicationset-rhsi-external-secrets-operator.yaml
├── rhsi/
│   ├── edb-operator/
│   ├── primary/
│   ├── site-a/
│   ├── site-b/
│   └── standby/
├── rhsi-external-secrets-operator/
├── rhsi-network-observer-operator/
└── rhsi-operator/
```

The interesting Vault/ESO bits live in **`rhsi/standby`**:

- `05-serviceaccount-rhsi-vault-reader.yaml`
- `06-rbac-access-token-job.yaml`
- `07-rbac-edb-operator-pullsecret.yaml`
- `65-secret-vault-ca.yaml`
- `70-secretstore-vault-rhsi.yaml`
- `75-externalsecret-rhsi-link-token.yaml`
- `76-externalsecret-edb-repos2-token.yaml`
- `80-job-create-access-token.yaml`
- `81-job-create-edb-operator-pullsecret.yaml`

---

## 1. Prerequisites & environment variables

You should have three kubecontexts:

- `CONTEXT_HUB` – ACM / GitOps hub cluster
- `CONTEXT_SITE_A` – primary site
- `CONTEXT_SITE_B` – standby site

And the RHSI namespace:

```bash
export CONTEXT_HUB=hub
export CONTEXT_SITE_A=site-a
export CONTEXT_SITE_B=site-b

export NS_RHSI=rhsi
```

Vault connectivity (adjust to your environment):

```bash
export VAULT_ADDR="https://vault-vault.apps.acm.sandbox2745.opentlc.com"
export VAULT_TOKEN="root"   # or a real admin token in a real env
```

You should already have:

- Skupper operator and Network Observer installed (via ACM / GitOps or `oc apply`).
- ESO installed from `rhsi-external-secrets-operator/`.

---

## 2. Hub: ACM placements & ApplicationSets

From the hub cluster:

```bash
cd /path/to/rhsi-edb-vault

oc --context "${CONTEXT_HUB}" apply -f hub/
```

This:

- Binds the desired clusters into a `ManagedClusterSet` (`rhsi-clusters`).
- Creates placements for:
  - `rhsi-primary`
  - `rhsi-standby`
  - `rhsi-operator`
  - `rhsi-network-observer-operator`
  - `rhsi-external-secrets-operator`
- Creates ArgoCD `ApplicationSet`s that point at this repo and sync:
  - `rhsi/primary` to the primary site
  - `rhsi/standby` to the standby site
  - operator subscriptions / network observer / ESO to the right clusters

You can also apply the site manifests manually (see next sections) if you are not using GitOps.

---

## 3. Site A (primary): namespace, Skupper & EDB cluster

If you want to bootstrap Site A manually (instead of via ACM):

```bash
# Namespace & base site objects
oc --context "${CONTEXT_SITE_A}" apply -f rhsi/primary/
oc --context "${CONTEXT_SITE_A}" apply -f rhsi/site-a/
oc --context "${CONTEXT_SITE_A}" apply -f rhsi/edb-operator/

# Network observer (if not already applied by hub)
oc --context "${CONTEXT_SITE_A}" apply -f rhsi/primary/60-networkobserver.yaml
```

This should give you:

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" get pods
# Expect:
# - skupper-router-xxxxx   2/2 Running
# - networkobserver-xxxxx  3/3 Running
# - (later) EDB operator pods & primary DB pods
```

Once the EDB operator is running, your **primary EDB cluster** for Site A will be created from `rhsi/site-a/db-edb/20-edb-site-a-cluster.yaml`.

---

## 4. Site B (standby): namespace, Skupper & EDB cluster

Similarly for Site B (if not using GitOps):

```bash
oc --context "${CONTEXT_SITE_B}" apply -f rhsi/standby/
oc --context "${CONTEXT_SITE_B}" apply -f rhsi/site-b/
oc --context "${CONTEXT_SITE_B}" apply -f rhsi/edb-operator/
```

After this you should see at least:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get pods
# Expect:
# - skupper-router-xxxxx   2/2 Running
# - networkobserver-xxxxx  3/3 Running
# - (later) EDB operator pods & standby DB pods
# - Jobs for Vault secrets (may initially Error until Vault is configured)
```

At this point, the **Vault / ESO configuration is likely NOT working yet** – that’s what Option A fixes.

---

## 5. Vault configuration for Site B (Option A)

These steps configure Vault’s Kubernetes auth for **Site B** and create the secrets ESO will read.

> All commands below are run where `vault` CLI is configured and `VAULT_ADDR`/`VAULT_TOKEN` are set.

### 5.1 Create a reviewer ServiceAccount on Site B

```bash
oc --context "${CONTEXT_SITE_B}" -n rhsi create sa vault-auth-reviewer || true

oc --context "${CONTEXT_SITE_B}" create clusterrolebinding vault-auth-reviewer   --clusterrole=system:auth-delegator   --serviceaccount=rhsi:vault-auth-reviewer || true
```

Extract its token and CA cert:

```bash
SA_SECRET=$(
  oc --context "${CONTEXT_SITE_B}" -n rhsi get sa vault-auth-reviewer     -o jsonpath='{.secrets[0].name}'
)

oc --context "${CONTEXT_SITE_B}" -n rhsi get secret "$SA_SECRET"   -o jsonpath='{.data.token}' | base64 -d > /tmp/site-b-reviewer-jwt

oc --context "${CONTEXT_SITE_B}" -n rhsi get secret "$SA_SECRET"   -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/site-b-ca.crt

oc --context "${CONTEXT_SITE_B}" whoami --show-server
# e.g. https://api.site-b.sandbox2745.opentlc.com:6443
```

### 5.2 Configure Kubernetes auth method in Vault

Mount path already exists in your case:

```bash
vault auth enable -path=kubernetes-site-b kubernetes || true
# If it errors with "path is already in use", that's fine.
```

Configure it:

```bash
vault write auth/kubernetes-site-b/config   token_reviewer_jwt=@/tmp/site-b-reviewer-jwt   kubernetes_host="$(oc --context "${CONTEXT_SITE_B}" whoami --show-server)"   kubernetes_ca_cert=@/tmp/site-b-ca.crt
```

Create a policy for the RHSI workload:

```bash
cat <<'EOF' | vault policy write rhsi-site-b -
path "rhsi/data/site-b/link-token" {
  capabilities = ["read"]
}

path "rhsi/data/edb-repos2" {
  capabilities = ["read"]
}
EOF

vault policy read rhsi-site-b
```

Create the role:

```bash
vault write auth/kubernetes-site-b/role/rhsi-site-b   bound_service_account_names="rhsi-vault-reader"   bound_service_account_namespaces="rhsi"   policies="rhsi-site-b"   ttl="1h"
```

### 5.3 Create the actual Vault secrets

`site-b/link-token` holds the Skupper AccessGrant data:

```bash
vault kv put rhsi/site-b/link-token   ca=@<path-to-ca.pem>   code="<access_grant_code_from_site_a>"   url="<grant_server_url_from_site_a>"
```

`edb-repos2` holds the EDB repos token:

```bash
vault kv put rhsi/edb-repos2   token="<edb_repos_token>"
```

Verify:

```bash
vault kv get rhsi/site-b/link-token
vault kv get rhsi/edb-repos2
```

---

## 6. External Secrets Operator on Site B

The following manifests in `rhsi/standby/` configure ESO:

- `65-secret-vault-ca.yaml` – CA for Vault TLS, referenced by the SecretStore.
- `70-secretstore-vault-rhsi.yaml` – SecretStore that uses:
  - provider: Vault
  - server: `https://vault-vault.apps.acm.sandbox2745.opentlc.com`
  - path: `rhsi`
  - auth:
    - mountPath: `kubernetes-site-b`
    - role: `rhsi-site-b`
    - serviceAccountRef: `rhsi-vault-reader`
- `75-externalsecret-rhsi-link-token.yaml` – pulls `site-b/link-token`.
- `76-externalsecret-edb-repos2-token.yaml` – pulls `edb-repos2`.

Re-apply them:

```bash
oc --context "${CONTEXT_SITE_B}" apply -f rhsi/standby/
```

Check status:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secretstore,externalsecret

# You want:
# secretstore/vault-rhsi   STATUS: Ready, CAPABILITIES: ReadWrite, READY: True
# externalsecret/rhsi-link-token    STATUS: SecretSynced, READY: True
# externalsecret/edb-repos2-token   STATUS: SecretSynced, READY: True
```

If the SecretStore shows `InvalidProviderConfig` and `permission denied (403)`, it usually means:

- The **policy** doesn’t include the right paths, or
- The **role** doesn’t reference the correct SA / namespace / policy.

Once the SecretStore is Ready, confirm the synced secrets:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret   rhsi-link-token   edb-repos2-token
```

You should at least see:

- `rhsi-link-token` – type `Opaque`, `DATA: 3` (e.g. `ca`, `code`, `url`)
- `edb-repos2-token` – type `Opaque`, `DATA: 1` (`token`)

---

## 7. Jobs that create the final K8s secrets (Option A)

The manifests:

- `80-job-create-access-token.yaml`
- `81-job-create-edb-operator-pullsecret.yaml`

define **one-shot Jobs** that:

- Read from `rhsi-link-token` / `edb-repos2-token`.
- Generate the final `Secret`s that Skupper and the EDB operator actually use:

  - `skupper-access-token-from-vault`
  - `edb-operator-pullsecret-from-vault`

Apply / re-apply them (already included in §4 when you did `apply -f rhsi/standby/`).

Check Jobs and pods:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get job

# Example:
# NAME                                      COMPLETIONS   AGE
# create-access-token-from-vault            1/1           ...
# create-edb-operator-pullsecret-from-vault 1/1           ...

oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get pods | egrep 'access-token|pullsecret' || true
```

If they are `Error`, grab logs:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" logs job/create-access-token-from-vault
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" logs job/create-edb-operator-pullsecret-from-vault
```

Once the Vault / ESO permissions are correct, re-running the Jobs should succeed:

```bash
# Delete old failed Jobs
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete job create-access-token-from-vault || true
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" delete job create-edb-operator-pullsecret-from-vault || true

# Recreate from manifests
oc --context "${CONTEXT_SITE_B}" apply -f rhsi/standby/80-job-create-access-token.yaml
oc --context "${CONTEXT_SITE_B}" apply -f rhsi/standby/81-job-create-edb-operator-pullsecret.yaml
```

After a short while:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret   skupper-access-token-from-vault   edb-operator-pullsecret-from-vault
```

Both should exist.

> **Note:** Option A deliberately uses **Jobs**, not CronJobs, to keep behaviour explicit and easy to debug. For automated rotation see §10.

---

## 8. Wiring the EDB operator to use the pull secret

Make sure the EDB operator subscription / CSV is using the `edb-operator-pullsecret-from-vault` secret.

Typically this is done via:

- An `imagePullSecrets` entry on the operator `ServiceAccount`, or
- A reference in your `Subscription` / OperatorGroup namespace secret, depending on how your operator is installed.

The details are operator-specific and are handled by the manifest in `rhsi/edb-operator/10-subscription-cloud-native-postgresql.yaml`. Adjust that file if you change the pullsecret name.

---

## 9. Sanity checks

Once everything is wired up, run through these.

### 9.1 Vault / ESO

```bash
# Site B SecretStore + ExternalSecrets
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secretstore,externalsecret

# Synced secrets from Vault
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret   rhsi-link-token   edb-repos2-token

# Final "from Vault" secrets used by Skupper / EDB operator
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get secret   skupper-access-token-from-vault   edb-operator-pullsecret-from-vault
```

You want:

- `vault-rhsi` – Ready: True
- `rhsi-link-token`, `edb-repos2-token` – exist and populated
- `skupper-access-token-from-vault`, `edb-operator-pullsecret-from-vault` – exist

### 9.2 Skupper link working

On both sites:

```bash
oc --context "${CONTEXT_SITE_A}" -n "${NS_RHSI}" get sites,connectors
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}" get sites,connectors
```

Network observer should show connectivity between sites.

### 9.3 EDB replication check

From **Site B** standby pod:

```bash
oc --context "${CONTEXT_SITE_B}" -n "${NS_RHSI}"   exec -it deploy/postgres-standby -- bash

export PGPASSWORD='supersecret'   # adjust to your demo password

psql   -h postgres-primary   -p 5432   -U appuser   -d postgres

-- create table if missing
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
```

You should see rows inserted from Site B via Skupper.

---

## 10. (Optional) Automating rotation

Current **Option A** uses **Jobs** that you manually re-run after rotating secrets in Vault.

If you want **automatic rotation**, you can:

1. Change `kind: Job` → `kind: CronJob` in:

   - `80-job-create-access-token.yaml`
   - `81-job-create-edb-operator-pullsecret.yaml`

2. Add an appropriate `schedule:` and `successfulJobsHistoryLimit`/`failedJobsHistoryLimit`.

Example snippet:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: create-access-token-from-vault
spec:
  schedule: "0 * * * *"   # every hour
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: rhsi-vault-reader
          restartPolicy: OnFailure
          containers:
          - name: create-access-token-from-vault
            image: quay.io/.../vault-helper:latest
            # ...
```

3. Rely on ESO to detect new versions in Vault and refresh the intermediate secrets (`rhsi-link-token`, `edb-repos2-token`), and CronJobs to refresh the final K8s secrets.

For now this repo keeps the jobs as **one-shot** for clarity and easier debugging.

---

## 11. Creating a zip of this README

If you want to zip just this README file locally:

```bash
zip rhsi-edb-vault-readme.zip README.md
```

This archive will contain only the README file.
