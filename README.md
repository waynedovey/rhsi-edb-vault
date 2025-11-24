# rhsI + Skupper + EDB / PostgreSQL lab

This repo is a small lab that demonstrates:

* Red Hat **Advanced Cluster Management (ACM)** driving **GitOps** for:
  * A **primary** PostgreSQL database on one cluster
  * A **standby** PostgreSQL database on another cluster
* **Red Hat Service Interconnect (RHSI / Skupper)** providing L4 connectivity
  between the two databases
* A **Vault-backed Skupper AccessToken** on the standby side, using the
  **OpenShift External Secrets Operator** to pull the grant from Vault so that
  no Skupper secrets/tokens are ever stored in Git

The topology:

* **Hub**: ACM + OpenShift GitOps
* **Site A**: “primary”:
  * Skupper site (`rhsi` namespace)
  * Primary PostgreSQL instance (`db` namespace)
* **Site B**: “standby”:
  * Skupper site (`rhsi` namespace)
  * Standby PostgreSQL instance (`db` namespace)
  * Vault-backed Skupper AccessToken created from a Vault secret via
    External Secrets + a small Job

The hub decides which clusters are **primary** vs **standby** based on labels,
and the ApplicationSets use placement rules to deploy the corresponding
manifests.

---

## 1. Repo layout

```text
rhsi-edb-vault/
├─ README.md
├─ hub/
│  ├─ 10-placement-rhsi-primary.yaml
│  ├─ 11-placement-rhsi-standby.yaml
│  ├─ 20-applicationset-rhsi-primary.yaml
│  ├─ 21-applicationset-rhsi-standby.yaml
│  └─ optional-30-gitopscluster-example.yaml
└─ rhsi/
   ├─ primary/         # resources for the primary cluster(s)
   │  ├─ 00-namespace-rhsi.yaml
   │  ├─ 10-site.yaml
   │  ├─ 20-postgres-primary-secret.yaml
   │  ├─ 30-postgres-primary-deployment.yaml
   │  ├─ 40-postgres-primary-service.yaml
   │  ├─ 50-connector-postgres.yaml
   │  └─ 60-networkobserver.yaml
   ├─ standby/         # resources for the standby cluster(s)
   │  ├─ 00-namespace-rhsi.yaml
   │  ├─ 05-serviceaccount-rhsi-vault-reader.yaml
   │  ├─ 06-rbac-access-token-job.yaml
   │  ├─ 10-site.yaml
   │  ├─ 20-postgres-standby-secret.yaml
   │  ├─ 30-postgres-standby-deployment.yaml
   │  ├─ 40-postgres-standby-service.yaml
   │  ├─ 50-listener-postgres.yaml
   │  ├─ 60-networkobserver.yaml
   │  ├─ 65-secret-vault-ca.yaml
   │  ├─ 70-secretstore-vault-rhsi.yaml
   │  ├─ 75-externalsecret-rhsi-link-token.yaml
   │  └─ 80-job-create-access-token.yaml
   ├─ site-a/          # optional, older direct example (not used by ApplicationSet)
   │  ├─ namespace-db.yaml
   │  ├─ pg-primary-auth-secret.yaml
   │  ├─ pg-primary-deploy.yaml
   │  ├─ pg-primary-svc.yaml
   │  ├─ namespace-rhsi.yaml
   │  ├─ postgres-connector.yaml
   │  └─ site.yaml
   └─ site-b/          # optional, older direct example (not used by ApplicationSet)
      ├─ namespace-db.yaml
      ├─ pg-standby-auth-secret.yaml
      ├─ pg-standby-deploy.yaml
      ├─ pg-standby-svc.yaml
      ├─ link-from-site-b.yaml
      ├─ link-tls-sealedsecret.yaml
      ├─ namespace-rhsi.yaml
      ├─ postgres-listener.yaml
      └─ site.yaml
```

The **ApplicationSets** only use `rhsi/primary` and `rhsi/standby`. The
`rhsi/site-a` and `rhsi/site-b` directories are kept as a simpler “direct”
example using Skupper links and TLS secrets (not driven by ACM).

---

## 2. Target environment

This lab assumes:

* 1 **hub** OpenShift cluster running:
  * ACM
  * OpenShift GitOps (Argo CD)
  * Vault (for Skupper grant storage)
* 2 **managed** OpenShift clusters:
  * `site-a` – primary site
  * `site-b` – standby site

All clusters are added to ACM as managed clusters.

Skupper and the database workloads run on the managed clusters. The hub only
hosts ACM, GitOps and Vault.

---

## 3. Prerequisites

On the **hub cluster**:

1. ACM installed and configured.
2. OpenShift GitOps (Argo CD) installed.
3. This repository cloned and available to Argo CD (either directly or via a
   mirror/fork).
4. HashiCorp Vault installed and reachable from the site clusters
   (for example via `https://vault-vault.apps.<your-domain>`).

On each **managed cluster (site-a, site-b)**:

1. Skupper / RHSI operator installed from the OpenShift OperatorHub.
2. A `db` namespace (or another namespace of your choice) where postgres will run.
3. A `rhsi` namespace where the Skupper `Site` is created.
4. Sufficient network connectivity such that `site-b` can reach the Skupper
   grant URL on `site-a` (HTTPS).
5. `skupper` CLI installed locally (optional but useful for debugging).

6. Install the **OpenShift External Secrets Operator** on each application cluster
   (`site-a` and `site-b`) if you want to use the Vault-backed link example:

   ```bash
   oc new-project external-secrets-operator

   cat << 'EOF' | oc apply -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     name: openshift-external-secrets-operator
     namespace: external-secrets-operator
   spec:
     targetNamespaces: []
   ---
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: openshift-external-secrets-operator
     namespace: external-secrets-operator
   spec:
     channel: tech-preview-v0.1
     name: openshift-external-secrets-operator
     source: redhat-operators
     sourceNamespace: openshift-marketplace
     installPlanApproval: Automatic
   ---
   apiVersion: operator.openshift.io/v1alpha1
   kind: ExternalSecrets
   metadata:
     name: cluster
     labels:
       app.kubernetes.io/name: external-secrets-operator
   spec: {}
   EOF
   ```

   That CR (`externalsecrets.operator.openshift.io/cluster`) turns on the
   external-secrets.io controllers that are used by
   `rhsi/standby/70-secretstore-vault-rhsi.yaml` and
   `rhsi/standby/75-externalsecret-rhsi-link-token.yaml` to read the Skupper
   link token from Vault.

On your **laptop**:

7. `oc` CLI with contexts for hub, `site-a`, and `site-b`.
8. Optional but recommended:
   * `kubeseal` + SealedSecrets controller if you want to GitOps your RHSI link
     TLS secrets (not included by default in this repo).

---

## 4. Label clusters with roles (primary vs standby)

On the **hub**, label the managed clusters to indicate which role they play.
For example:

```bash
# site-a is primary
oc label managedcluster site-a rhsidemo/role=primary --overwrite

# site-b is standby
oc label managedcluster site-b rhsidemo/role=standby --overwrite
```

These labels are used by the Placement rules in `hub/10-placement-rhsi-primary.yaml`
and `hub/11-placement-rhsi-standby.yaml`.

---

## 5. Create Placement rules on the hub

Apply the Placement resources on the hub:

```bash
oc apply -f hub/10-placement-rhsi-primary.yaml
oc apply -f hub/11-placement-rhsi-standby.yaml
```

You can verify the placement decisions with:

```bash
oc -n openshift-gitops get placementdecisions
```

---

## 6. Create ApplicationSets on the hub

Now create the two ApplicationSets that use the **clusterDecisionResource**
generator. These use the ACM-provided ConfigMap `acm-placement`.

```bash
oc apply -f hub/20-applicationset-rhsi-primary.yaml
oc apply -f hub/21-applicationset-rhsi-standby.yaml
```

Once these are applied, Argo CD will:

* Discover which clusters are primary vs standby (from Placement)
* Create:
  * `rhsi-primary-<cluster>` Applications using `rhsi/primary/`
  * `rhsi-standby-<cluster>` Applications using `rhsi/standby/`

---

## 7. What gets deployed on each cluster

On a **primary** cluster (role = primary):

* Namespace `rhsi`
* Skupper `Site` (`rhsi/primary/10-site.yaml`)
* Secret `postgres-credentials` in `rhsi`
* PostgreSQL primary Deployment + Service in `db`
* Skupper `Connector` in `rhsi` pointing at `db`
* Skupper `NetworkObserver` in `rhsi`

On a **standby** cluster (role = standby):

* Namespace `rhsi`
* ServiceAccount `rhsi-vault-reader` in `rhsi`
* RBAC so that the access-token job can read secrets in `rhsi`
* Skupper `Site` in `rhsi`
* Secret `postgres-credentials` in `rhsi`
* PostgreSQL standby Deployment + Service in `db`
* Skupper `Listener` in `rhsi` exposing the standby DB
* Skupper `NetworkObserver` in `rhsi`
* Vault CA secret (`vault-ca`) in `rhsi`
* `SecretStore` pointing at Vault (`vault-rhsi`)
* `ExternalSecret` (`rhsi-link-token`) that pulls the Skupper grant from Vault
* Job `create-access-token-from-vault` to create/reconcile the Skupper
  `AccessToken` from the Vault-backed Secret

---

## 8. Creating a RHSI link with Vault + External Secrets (one-time bootstrap per environment)

For the `primary` / `standby` example used by the ApplicationSets, this
repo now uses a **Vault-backed Skupper AccessToken** instead of committing
link secrets or tokens to Git.

At a high level:

* On **site-a** (primary), you create a Skupper *grant* (out of band).
* You copy the resulting `code`, `url`, and `ca` into Vault under a known
  path (`rhsi/site-b/link-token` in this example).
* On **site-b** (standby), the OpenShift External Secrets Operator reads
  that Vault entry into `Secret/rhsi-link-token`.
* A small Job (`create-access-token-from-vault`) turns that Secret into a
  `AccessToken` CR, which Skupper then redeems to establish the link.

Nothing sensitive (grant code, URL, CA) lives in Git.

---

### 8.1 Prepare Vault Kubernetes auth for `site-b`

On a machine that can talk to Vault (for example your bastion / hub), and
with `vault` pointing at:

```bash
export VAULT_ADDR=https://vault-vault.apps.<your-domain>
```

do the following **once per standby cluster**.

1. Log in to the **site-b** cluster and capture the service account
   token and CA that External Secrets will use:

   ```bash
   oc --context site-b -n rhsi get sa rhsi-vault-reader
   oc --context site-b -n kube-public get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > /tmp/site-b-ca.crt

   # Short-lived token used as the reviewer JWT for Vault
   REVIEWER_JWT=$(oc --context site-b -n rhsi create token rhsi-vault-reader)
   ```

2. Configure (or reconfigure) a **Kubernetes auth mount** in Vault for
   this cluster. In this example we use `kubernetes-site-b`:

   ```bash
   # Enable the auth mount once (if not already present)
   vault auth enable -path=kubernetes-site-b kubernetes || true

   # Point the auth method at the site-b API server
   KUBE_HOST=$(oc --context site-b config view --minify -o jsonpath='{.clusters[0].cluster.server}')
   KUBE_CA_CRT=$(cat /tmp/site-b-ca.crt)

   vault write auth/kubernetes-site-b/config      token_reviewer_jwt="$REVIEWER_JWT"      kubernetes_host="$KUBE_HOST"      kubernetes_ca_cert="$KUBE_CA_CRT"
   ```

3. Create a **policy** and **role** that allows reading the link token
   for `site-b`:

   ```bash
   vault policy write rhsi-site-b - << 'EOF'
   path "rhsi/data/site-b/*" {
     capabilities = ["read"]
   }
   EOF

   vault write auth/kubernetes-site-b/role/rhsi-site-b      bound_service_account_names="rhsi-vault-reader"      bound_service_account_namespaces="rhsi"      token_policies="rhsi-site-b"      ttl="1h"
   ```

> During debugging you can temporarily widen the role with
> `bound_service_account_names="*"` and
> `bound_service_account_namespaces="*"`. For production you should
> lock this back down to the specific service account/namespace as
> shown above.

---

### 8.2 Store the Skupper grant in Vault

On **site-a** (primary), create a Skupper grant for the standby site using
either the Skupper CLI or the `AccessGrant` CR (see the Skupper
documentation for the exact commands).

From the grant, you need three fields:

* `code` – the grant code Skupper will redeem
* `url` – the HTTPS URL of the grant server
* `ca` – the PEM-encoded certificate for `SkupperGrantServerCA`

Create a secret at the expected path in Vault:

```bash
vault kv put rhsi/site-b/link-token   code="<grant-code-from-site-a>"   url="<grant-url-from-site-a>"   ca=@/path/to/skupper-grant-server-ca.pem
```

You can verify it later with:

```bash
vault kv get rhsi/site-b/link-token
```

The example in this repo expects exactly that path
`rhsi/site-b/link-token` and those three keys (`code`, `url`, `ca`).

---

### 8.3 How the ExternalSecret + Job work on site-b

Once Vault auth is configured and the grant is stored:

1. The **SecretStore** in `rhsi/standby/70-secretstore-vault-rhsi.yaml`
   tells External Secrets how to talk to Vault:

   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: SecretStore
   metadata:
     name: vault-rhsi
     namespace: rhsi
   spec:
     provider:
       vault:
         server: https://vault-vault.apps.<your-domain>
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

   Make sure the `mountPath` and `role` match what you configured in Vault.

2. The **ExternalSecret** in
   `rhsi/standby/75-externalsecret-rhsi-link-token.yaml` pulls the
   grant from Vault and writes it to `Secret/rhsi-link-token`:

   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: rhsi-link-token
     namespace: rhsi
   spec:
     secretStoreRef:
       kind: SecretStore
       name: vault-rhsi
     refreshInterval: 5m
     target:
       name: rhsi-link-token
       creationPolicy: Owner
       deletionPolicy: Retain
     dataFrom:
       - extract:
           key: site-b/link-token
   ```

3. The Job in `rhsi/standby/80-job-create-access-token.yaml`
   waits for `Secret/rhsi-link-token` to appear and then creates the
   `AccessToken`:

   ```bash
   oc --context site-b -n rhsi logs -f job/create-access-token-from-vault
   ```

   Once it has run successfully you should see:

   ```bash
   oc --context site-b -n rhsi get secret rhsi-link-token
   oc --context site-b -n rhsi get accesstoken standby-from-vault
   ```

4. Skupper redeems the AccessToken and establishes the link. You can
   confirm on the standby site:

   ```bash
   skupper --context site-b --namespace rhsi link status
   ```

From this point onward, the link identity is **derived from Vault** and
no secrets or grant codes are committed to Git. Rotating the grant is as
simple as updating the Vault entry and re-running the job.

> If you prefer the older pattern using `Link` + TLS secret + SealedSecret,
> you can still use the manifests under `rhsi/site-a` and `rhsi/site-b` as a
> standalone example, but the GitOps flow driven by the ApplicationSets
> uses the Vault + AccessToken approach described above.

---

## 9. PostgreSQL logical replication example

The `primary` / `standby` deployments are configured to demonstrate logical
replication between the two PostgreSQL instances once the Skupper link is up.

(Details of the logical replication configuration and test steps can be
documented here, or you can adapt this section to your specific EDB/Postgres
setup.)

## Skupper link via Vault-stored AccessToken (updated flow)

This repository now uses the **Skupper v2 AccessGrant + Vault + ExternalSecrets** pattern so that
the **standby** site can obtain and redeem a Skupper access token fully automatically.

High-level flow:

1. **Primary site (site-a)** issues an `AccessGrant`.
2. The **AccessGrant status** (`ca`, `code`, `url`) is written into Vault under `rhsi/site-a/link-token`
   and `rhsi/site-b/link-token`.
3. On **standby site (site-b)**, `ExternalSecret rhsi-link-token` reads from Vault and creates the
   in-cluster `Secret rhsi-link-token` with the three fields: `ca`, `code`, `url`.
4. A small **Job** (`create-access-token-from-vault`) reads `rhsi-link-token` and creates the
   Skupper `AccessToken standby-from-vault` resource.
5. The Skupper controller uses that `AccessToken` to establish a **link** from `rhsi-standby`
   to `rhsi-primary`.
6. **Connectors** on the primary and **listeners** on the standby then provide L4 Postgres
   connectivity across clusters.

### 1. Create AccessGrant on primary (site-a)

On **site-a** (primary), in the `rhsi` namespace, apply the `AccessGrant` manifest:

```bash
oc --context site-a -n rhsi apply -f rhsi-standby-grant.yaml

oc --context site-a -n rhsi get accessgrant rhsi-standby-grant -o yaml
```

Wait until the `status` is `Ready`. Then capture the three important fields:

```bash
oc --context site-a -n rhsi get accessgrant rhsi-standby-grant   -o jsonpath='{.status.ca}'   > /tmp/grant-ca.pem

oc --context site-a -n rhsi get accessgrant rhsi-standby-grant   -o jsonpath='{.status.code}' > /tmp/grant-code

oc --context site-a -n rhsi get accessgrant rhsi-standby-grant   -o jsonpath='{.status.url}'  > /tmp/grant-url
```

And write them into Vault for both sites:

```bash
CODE=$(cat /tmp/grant-code)
URL=$(cat /tmp/grant-url)

vault kv put rhsi/site-a/link-token   ca=@/tmp/grant-ca.pem   code="$CODE"   url="$URL"

vault kv put rhsi/site-b/link-token   ca=@/tmp/grant-ca.pem   code="$CODE"   url="$URL"
```

### 2. ExternalSecrets + SecretStore (site-b)

On **site-b**, the `SecretStore vault-rhsi` is configured to use the Vault
`kubernetes-site-b` auth mount and role `rhsi-site-b`. The important bits:

- `spec.provider.vault.server` points at the Vault route
- `spec.provider.vault.path` is `rhsi`
- `spec.provider.vault.auth.kubernetes.mountPath` is `kubernetes-site-b`
- `spec.provider.vault.auth.kubernetes.role` is `rhsi-site-b`
- `spec.provider.vault.caProvider` references the Vault CA secret

The `ExternalSecret` looks up `rhsi/site-b/link-token` and creates
`Secret rhsi-link-token` in the `rhsi` namespace with keys:

- `ca`
- `code`
- `url`

You can force a reconcile if needed:

```bash
oc --context site-b -n rhsi annotate externalsecret rhsi-link-token   reconciled-at="$(date +%s)" --overwrite
```

And verify the resulting secret:

```bash
oc --context site-b -n rhsi get secret rhsi-link-token -o yaml
```

### 3. Job: create AccessToken from Vault (site-b)

On **site-b**, the `Job create-access-token-from-vault`:

- waits for `Secret rhsi-link-token`,
- reads the `ca`, `code`, `url` keys,
- and creates/updates an `AccessToken` named `standby-from-vault`.

This produces an object like:

```yaml
apiVersion: skupper.io/v2alpha1
kind: AccessToken
metadata:
  name: standby-from-vault
  namespace: rhsi
spec:
  ca: |-
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  code: qUObUPgnx0FxOSqcDpSddcfD
  url: https://skupper-grant-server-https-openshift-operators.apps.site-a.sandbox2745.opentlc.com:443/...
```

Once this exists, Skupper will automatically redeem it and create the link.

### 4. Validate Skupper sites and link

Check the sites:

```bash
skupper --context site-a -n rhsi site status
skupper --context site-b -n rhsi site status
```

You should see both `rhsi-primary` and `rhsi-standby` in `Ready` state.

Check the link from the standby site:

```bash
skupper --context site-b -n rhsi link status
```

Example output:

```text
NAME                  STATUS  COST  MESSAGE
standby-from-vault    Ready   0     OK
```

On the standby site you can also inspect the link CR:

```bash
oc --context site-b -n rhsi get links.skupper.io
```

and confirm the `REMOTE SITE` is `rhsi-primary`.

### 5. Postgres connector + listener

The repo also includes:

- A **connector** on `site-a` (`connector-postgres.yaml`)
- A **listener** on `site-b` (`listener-postgres.yaml`)

Apply them like this:

```bash
# Primary / site-a
oc --context site-a -n rhsi apply -f connector-postgres.yaml
skupper --context site-a -n rhsi connector status

# Standby / site-b
oc --context site-b -n rhsi apply -f listener-postgres.yaml
skupper --context site-b -n rhsi listener status
```

You should see something like:

```text
NAME                  STATUS  ROUTING-KEY  SELECTOR                HOST  PORT  HAS MATCHING LISTENER  MESSAGE
postgres              Ready   postgres     app=postgres-primary          5432  true                   OK
```

and

```text
NAME                  STATUS  ROUTING-KEY  HOST              PORT  MATCHING-CONNECTOR  MESSAGE
postgres-primary      Ready   postgres      postgres-primary  5432  true                OK
```

which indicates that Postgres from the **primary** cluster is now available
via Skupper on the **standby** cluster as `Service postgres-primary` on
port `5432`.

