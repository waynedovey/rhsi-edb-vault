# Red Hat Service Interconnect between site-a and site-b (GitOps with RHACM + Argo CD)

This README describes a **pragmatic GitOps pattern** to run Red Hat Service Interconnect (RHSI, Skupper v2)
between two OpenShift clusters and use it to replicate a PostgreSQL database between sites.

Clusters:

- **site-a** – `https://console-openshift-console.apps.site-a.sandbox2745.opentlc.com/` (AWS `ap-northeast-1`)
- **site-b** – `https://console-openshift-console.apps.site-b.sandbox2745.opentlc.com/` (AWS `ap-northeast-2`)

RHSI is installed on both clusters and managed via **Argo CD** (OpenShift GitOps) on the hub, which itself is
managed by **RHACM**.

The guide focuses on:

1. Git layout and Argo CD setup (assumed on a hub / RHACM cluster).
2. Declarative RHSI **Sites** on site-a and site-b.
3. A **GitOps‑friendly way to handle the “token”/link**:  
   use `skupper link generate` once, then store the resulting TLS material as a **sealed secret** in Git.
4. An example PostgreSQL primary on site-a and standby on site-b using RHSI to carry the replication traffic.

> ⚠️ **Note:** This is primarily a lab / PoC pattern. For production you’d usually add:
> - Policy + RBAC for Skupper,  
> - Stronger secret management (Vault / External Secrets / SOPS / Sealed Secrets),  
> - Real HA PostgreSQL (CloudNativePG, Crunchy, Postgres-HA, etc.).

---

## 1. Prerequisites

- Two OpenShift clusters (site-a, site-b) reachable from your hub cluster.
- RHACM installed on the hub and both clusters imported as `ManagedCluster` resources.
- OpenShift GitOps (Argo CD) installed on the hub (usually in `openshift-gitops`).
- RHSI entitlement & access to the **Red Hat Service Interconnect Operator** on both clusters.
- `oc` and `kubectl` configured for hub, site-a, and site-b.
- `skupper` CLI installed (on your admin machine or bastion).
- (Recommended) **Bitnami Sealed Secrets** installed on both clusters if you want to keep link TLS in Git.

We’ll use these namespaces:

- `rhsi` – RHSI controller & site resources.
- `db`   – Application namespace containing PostgreSQL deployments.

---

## 2. Git layout

Example Git repo structure:

```text
gitops-root/
└── rhsi/
    ├── site-a/
    │   ├── namespace-rhsi.yaml
    │   ├── site.yaml
    │   ├── postgres-connector.yaml
    │   └── db-primary/
    │       ├── namespace-db.yaml
    │       ├── pg-primary-deploy.yaml
    │       └── pg-primary-svc.yaml
    └── site-b/
        ├── namespace-rhsi.yaml
        ├── site.yaml
        ├── link-from-site-b.yaml      # Link resource pointing to site-a
        ├── link-tls-sealedsecret.yaml # SealedSecret with TLS keys for the link
        ├── postgres-listener.yaml
        └── db-standby/
            ├── namespace-db.yaml
            ├── pg-standby-deploy.yaml
            └── pg-standby-svc.yaml
```

You can obviously embed this into your existing repo layout – paths are examples.

---

## 3. RHACM + Argo CD integration (high level)

This guide assumes:

- RHACM imports **site-a** and **site-b** as managed clusters.
- OpenShift GitOps is configured as the GitOps engine for RHACM.  
  (Typically via a `GitOpsCluster` per managed cluster.)

Once the integration is done, Argo CD sees both clusters as destinations with names like `site-a` and `site-b`.

Example Argo CD `Application` (on the hub) for **site-a**:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhsi-site-a
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_ORG/YOUR_REPO.git
    targetRevision: main
    path: rhsi/site-a
  destination:
    name: site-a              # Must match the Argo cluster name from RHACM integration
    namespace: rhsi
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

And similarly for **site-b**:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhsi-site-b
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_ORG/YOUR_REPO.git
    targetRevision: main
    path: rhsi/site-b
  destination:
    name: site-b
    namespace: rhsi
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply those on the **hub** cluster in `openshift-gitops` and Argo will manage both sites.

---

## 4. Install Red Hat Service Interconnect via GitOps

### 4.1 Namespace manifest (both sites)

`rhsi/site-a/namespace-rhsi.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rhsi
```

`rhsi/site-b/namespace-rhsi.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rhsi
```

### 4.2 Install RHSI Operator (one time per cluster)

For simplicity, **install the Red Hat Service Interconnect Operator manually** from OperatorHub
into the `rhsi` namespace on each cluster (site-a, site-b), using the `stable` / `stable-1.8` / `stable-2`
channel as appropriate.

If you prefer GitOps for the operator itself, you can add a Subscription and OperatorGroup
to each `rhsi/site-*/` tree – just adjust the `spec.name` and `spec.channel` to match your catalog.

Once the operator is installed:

- Operator namespace: `rhsi`
- It watches Skupper / RHSI resources cluster-wide (or at least in selected namespaces – check the operator’s config).

---

## 5. Declarative RHSI Site definitions

### 5.1 site-a Site CR

`rhsi/site-a/site.yaml`:

```yaml
apiVersion: skupper.io/v2alpha1
kind: Site
metadata:
  name: site-a
  namespace: rhsi
spec:
  # Allow incoming links from other sites
  linkAccess: default
```

### 5.2 site-b Site CR

`rhsi/site-b/site.yaml`:

```yaml
apiVersion: skupper.io/v2alpha1
kind: Site
metadata:
  name: site-b
  namespace: rhsi
spec: {}
```

Commit and push these manifests; let Argo sync them to both clusters.

To verify (from your laptop):

```bash
# On site-a
oc --context=site-a -n rhsi get site

# On site-b
oc --context=site-b -n rhsi get site
```

Wait until `STATUS` shows `Ready` (or `OK` depending on CLI output).

---

## 6. GitOps-friendly linking using `skupper link generate` + sealed secrets

### 6.1 Why not just use tokens?

RHSI/Skupper supports **token-based** linking (`skupper token issue/redeem`) and **link resource**–based
linking (`skupper link generate`). Tokens and links both carry **secret** information and must
not be stored in plain Git.

For GitOps, the most practical pattern is:

1. Use `skupper link generate` on **site-a** to generate:
   - A `Link` resource (non-secret metadata),
   - A TLS `Secret` (private key + cert).
2. Convert the **Secret** into a **SealedSecret** (or SOPS-encrypted Secret).
3. Store both the `Link` resource and the encrypted Secret in Git under `rhsi/site-b/`.
4. Argo on **site-b** applies them and the site-to-site link comes up.

This is effectively automating the “token” via a one-time bootstrap with `skupper`.

### 6.2 Generate link YAML on site-a

1. Ensure the `Site` on site-a is **Ready**.
2. From your admin machine:

```bash
# Use site-a context and rhsi namespace
oc --context=site-a -n rhsi whoami
skupper --context site-a --namespace rhsi link generate > link-to-site-b.yaml
```

The output file will look like this (simplified):

```yaml
apiVersion: skupper.io/v2alpha1
kind: Link
metadata:
  name: site-b-link
spec:
  endpoints:
    - group: skupper-router-1
      host: 10.97.161.185
      name: inter-router
      port: "55671"
    - group: skupper-router-1
      host: 10.97.161.185
      name: edge
      port: "45671"
  tlsCredentials: site-b-link-tls
---
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: site-b-link-tls
data:
  ca.crt: ...
  tls.crt: ...
  tls.key: ...
```

> ⚠️ Treat this file as sensitive – it contains a private key.

### 6.3 Split into Link + Secret and add to Git

Create two files under `rhsi/site-b/`:

`rhsi/site-b/link-from-site-b.yaml` (Link resource only):

```yaml
apiVersion: skupper.io/v2alpha1
kind: Link
metadata:
  name: site-b-link
  namespace: rhsi
spec:
  endpoints:
    - group: skupper-router-1
      host: 10.97.161.185
      name: inter-router
      port: "55671"
    - group: skupper-router-1
      host: 10.97.161.185
      name: edge
      port: "45671"
  tlsCredentials: site-b-link-tls
```

`rhsi/site-b/link-tls-secret-plain.yaml` (temporary, **not** committed):

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: site-b-link-tls
  namespace: rhsi
data:
  ca.crt: ...
  tls.crt: ...
  tls.key: ...
```

Now convert the Secret to a SealedSecret (or your preferred encrypted secret format).

Example using Bitnami Sealed Secrets (with site-b cluster):

```bash
# Make sure kubeseal points to site-b and its controller
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
  --format yaml < rhsi/site-b/link-tls-secret-plain.yaml \
  > rhsi/site-b/link-tls-sealedsecret.yaml

# Immediately delete the plain secret file
rm rhsi/site-b/link-tls-secret-plain.yaml
```

Commit **only**:

- `rhsi/site-b/link-from-site-b.yaml`
- `rhsi/site-b/link-tls-sealedsecret.yaml`

Push to Git and let Argo for **site-b** sync.

### 6.4 Verify the link

After Argo syncs on site-b:

```bash
# On site-b
oc --context=site-b -n rhsi get link
oc --context=site-b -n rhsi get pods

# On site-a
oc --context=site-a -n rhsi get link
```

You should see the link in `Ready`/`OK` state and the Skupper router pods running on both sites.
Once linked, services exposed via RHSI will be reachable transparently between the two clusters.

---

## 7. PostgreSQL example across sites

To keep it reasonably simple, this example uses **Bitnami PostgreSQL with repmgr** image
(`bitnami/postgresql-repmgr`) to build a **primary on site-a** and a **standby on site-b** using
streaming replication. The replication traffic goes through RHSI.

> ⚠️ This is **not** a full production design – it’s a working demo of cross-site replication.
> For real HA, use a PostgreSQL operator (e.g. CloudNativePG) and carefully plan failover semantics.

### 7.1 PostgreSQL primary on site-a

#### 7.1.1 Namespace for DB

`rhsi/site-a/db-primary/namespace-db.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db
```

#### 7.1.2 Primary Service

`rhsi/site-a/db-primary/pg-primary-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pg-primary
  namespace: db
spec:
  selector:
    app: pg-primary
  ports:
    - name: postgres
      protocol: TCP
      port: 5432
      targetPort: 5432
```

#### 7.1.3 Primary Deployment

`rhsi/site-a/db-primary/pg-primary-deploy.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pg-primary
  namespace: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pg-primary
  template:
    metadata:
      labels:
        app: pg-primary
    spec:
      containers:
        - name: postgres
          image: bitnami/postgresql-repmgr:15
          imagePullPolicy: IfNotPresent
          env:
            # PostgreSQL superuser password
            - name: POSTGRESQL_POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-primary-auth
                  key: postgres-password
            # repmgr password
            - name: REPMGR_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-primary-auth
                  key: repmgr-password
            # Cluster config - single primary node in site-a
            - name: REPMGR_PRIMARY_HOST
              value: pg-primary.db.svc.cluster.local
            - name: REPMGR_NODE_NAME
              value: pg-primary
            - name: REPMGR_NODE_NETWORK_NAME
              value: pg-primary.db.svc.cluster.local
            - name: REPMGR_PARTNER_NODES
              value: pg-primary.db.svc.cluster.local
          ports:
            - containerPort: 5432
              name: postgres
          volumeMounts:
            - name: data
              mountPath: /bitnami/postgresql
      volumes:
        - name: data
          emptyDir: {}
```

Add a simple Secret (you can keep this in Git encrypted, or create manually):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pg-primary-auth
  namespace: db
type: Opaque
stringData:
  postgres-password: PostgresPassw0rd!
  repmgr-password: RepmgrPassw0rd!
```

(You can place this Secret YAML into the repo and encrypt it the same way as link TLS.)

---

### 7.2 Expose primary via RHSI (Connector on site-a)

We want site-b to reach the primary in site-a via RHSI. We do this using a **Connector** on site-a
and a **Listener** on site-b, sharing a `routingKey`.

#### 7.2.1 Connector on site-a

`rhsi/site-a/postgres-connector.yaml`:

```yaml
apiVersion: skupper.io/v2alpha1
kind: Connector
metadata:
  name: pg-primary
  namespace: rhsi
spec:
  routingKey: pg-primary
  selector: app=pg-primary
  port: 5432
  namespace: db
```

This tells RHSI:

- In site-a, pick pods with `app=pg-primary` in namespace `db` on port `5432`,
- Expose them on the Skupper network with routing key `pg-primary`.

---

### 7.3 Listener on site-b (creates a service pointing to site-a DB)

`rhsi/site-b/postgres-listener.yaml`:

```yaml
apiVersion: skupper.io/v2alpha1
kind: Listener
metadata:
  name: pg-primary
  namespace: rhsi
spec:
  routingKey: pg-primary
  host: pg-primary
  port: 5432
```

This creates a Kubernetes Service `pg-primary` in namespace `rhsi` on site-b, which forwards
traffic over the RHSI link to the primary in site-a.

Service DNS on site-b will be: `pg-primary.rhsi.svc.cluster.local`.

---

### 7.4 PostgreSQL standby on site-b

The standby connects to the **primary via RHSI** using the `pg-primary.rhsi.svc.cluster.local` hostname.

#### 7.4.1 Namespace for DB on site-b

`rhsi/site-b/db-standby/namespace-db.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db
```

#### 7.4.2 Standby Service

`rhsi/site-b/db-standby/pg-standby-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pg-standby
  namespace: db
spec:
  selector:
    app: pg-standby
  ports:
    - name: postgres
      protocol: TCP
      port: 5432
      targetPort: 5432
```

#### 7.4.3 Standby Deployment

`rhsi/site-b/db-standby/pg-standby-deploy.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pg-standby
  namespace: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pg-standby
  template:
    metadata:
      labels:
        app: pg-standby
    spec:
      containers:
        - name: postgres
          image: bitnami/postgresql-repmgr:15
          imagePullPolicy: IfNotPresent
          env:
            - name: POSTGRESQL_POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-standby-auth
                  key: postgres-password
            - name: REPMGR_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-standby-auth
                  key: repmgr-password

            # Standby configuration
            - name: REPMGR_PRIMARY_HOST
              value: pg-primary.rhsi.svc.cluster.local
            - name: REPMGR_PRIMARY_PORT
              value: "5432"
            - name: REPMGR_NODE_NAME
              value: pg-standby
            - name: REPMGR_NODE_NETWORK_NAME
              value: pg-standby.db.svc.cluster.local
            - name: REPMGR_PARTNER_NODES
              value: pg-primary.rhsi.svc.cluster.local,pg-standby.db.svc.cluster.local

            # This tells the container it should join as a standby
            - name: POSTGRESQL_REPLICATION_MODE
              value: replica
            - name: POSTGRESQL_REPLICA_PRIORITY
              value: "100"

          ports:
            - containerPort: 5432
              name: postgres
          volumeMounts:
            - name: data
              mountPath: /bitnami/postgresql
      volumes:
        - name: data
          emptyDir: {}
```

Authentication Secret (again, ideally encrypted in Git):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pg-standby-auth
  namespace: db
type: Opaque
stringData:
  postgres-password: PostgresPassw0rd!
  repmgr-password: RepmgrPassw0rd!
```

> 🔎 For full details of the environment variables supported by `bitnami/postgresql-repmgr`,
> refer to the Bitnami documentation. You can also extend this with additional standby nodes,
> using `REPMGR_PARTNER_NODES` as shown in their examples.

---

### 7.5 Sync everything with Argo and test

1. Commit and push all manifests under `rhsi/site-a/` and `rhsi/site-b/`.
2. Let Argo CD applications (`rhsi-site-a` and `rhsi-site-b`) sync.
3. Wait for pods:

```bash
# Primary in site-a
oc --context=site-a -n db get pods

# Standby in site-b
oc --context=site-b -n db get pods
```

4. Use `psql` to verify replication:

On **site-a**:

```bash
oc --context=site-a -n db exec -it deploy/pg-primary -- bash
psql -U postgres -c "CREATE DATABASE testdb;"
psql -U postgres -d testdb -c "CREATE TABLE demo (id serial primary key, value text);"
psql -U postgres -d testdb -c "INSERT INTO demo (value) VALUES ('hello-from-site-a');"
```

On **site-b**:

```bash
oc --context=site-b -n db exec -it deploy/pg-standby -- bash
psql -U postgres -d testdb -c "SELECT * FROM demo;"
```

You should see the row inserted on the primary.

(If you don’t, check the `pg-standby` logs for replication errors – often `pg_hba.conf`
or replication variable tuning is needed. For a lab, you can relax `pg_hba` using the
image’s provided env vars.)

---

## 8. Summary

- RHSI **Sites** and application workloads are fully declarative and GitOps‑managed via Argo CD.
- The **link credentials** are handled via a one-time `skupper link generate` on site-a and stored
  as a **sealed secret** in Git for site-b.
- PostgreSQL primary/standby replication demonstrates a real cross-cluster data path over RHSI,
  using Connectors and Listeners to hide the network complexity.

From here you can:

- Wrap site-a and site-b into higher-level RHACM policies or placement rules.
- Replace the simple PostgreSQL example with a production-grade Postgres operator.
- Expose other services over the same RHSI virtual application network.
