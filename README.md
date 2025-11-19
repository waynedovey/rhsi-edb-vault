# rhsi-edb-vault

GitOps-ready example for:

- **Red Hat Service Interconnect (RHSI)** between two OpenShift clusters (`site-a`, `site-b`)
- A simple **PostgreSQL primary/standby** replication demo using RHSI
- (Optional) Integration point for Vault / EDB to be added later

The repo is designed to be driven by **Argo CD** (OpenShift GitOps) on a **hub** cluster that is
managing `site-a` and `site-b` via **RHACM**.

Clusters are treated generically as:

- **site-a** – OpenShift cluster in AWS `ap-northeast-1`
- **site-b** – OpenShift cluster in AWS `ap-northeast-2`

> This is a _lab / PoC_ setup. For production, harden secrets, HA Postgres, and RHSI policies.

---

## 1. Repo layout

```text
rhsi-edb-vault/
├── README.md
└── rhsi/
    ├── site-a/
    │   ├── namespace-rhsi.yaml
    │   ├── site.yaml
    │   ├── postgres-connector.yaml
    │   └── db-primary/
    │       ├── namespace-db.yaml
    │       ├── pg-primary-auth-secret.yaml
    │       ├── pg-primary-deploy.yaml
    │       └── pg-primary-svc.yaml
    └── site-b/
        ├── namespace-rhsi.yaml
        ├── site.yaml
        ├── link-from-site-b.yaml
        ├── link-tls-sealedsecret.yaml
        ├── postgres-listener.yaml
        └── db-standby/
            ├── namespace-db.yaml
            ├── pg-standby-auth-secret.yaml
            ├── pg-standby-deploy.yaml
            └── pg-standby-svc.yaml
```

You can host this repo on GitHub, e.g.:

```yaml
repoURL: https://github.com/waynedovey/rhsi-edb-vault.git
```

and point Argo CD at the `rhsi/site-a` and `rhsi/site-b` paths.

---

## 2. RHACM + Argo CD integration (high level)

1. Import `site-a` and `site-b` as `ManagedCluster` resources in RHACM on the hub.
2. Configure OpenShift GitOps (Argo CD) as the GitOps engine for RHACM (one `GitOpsCluster` per managed cluster).
3. Ensure Argo sees the managed clusters as destinations with names `site-a` and `site-b`.

Example Argo CD `Application` for **site-a** (applied on the hub in `openshift-gitops`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhsi-site-a
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/waynedovey/rhsi-edb-vault.git
    targetRevision: main
    path: rhsi/site-a
  destination:
    name: site-a              # Must match the Argo cluster name from RHACM
    namespace: rhsi
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

And for **site-b**:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhsi-site-b
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/waynedovey/rhsi-edb-vault.git
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

---

## 3. RHSI installation (operator + Site CRs)

### 3.1 Install RHSI Operator (one-time per cluster)

Install the **Red Hat Service Interconnect** operator into the `rhsi` namespace on both clusters
(e.g. from OperatorHub) using the appropriate channel (`stable`, `stable-1.x`, etc).

You can GitOps the operator as well (Subscription + OperatorGroup), but that’s outside this basic repo.

### 3.2 Namespace and Site CRs (in this repo)

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

`rhsi/site-b/site.yaml`:

```yaml
apiVersion: skupper.io/v2alpha1
kind: Site
metadata:
  name: site-b
  namespace: rhsi
spec: {}
```

Once Argo syncs these, confirm:

```bash
oc --context=site-a -n rhsi get site
oc --context=site-b -n rhsi get site
```

Both Sites should show as **Ready/OK**.

---

## 4. GitOps-friendly link setup (replacing tokens)

RHSI/Skupper supports token-based linking, but tokens contain secrets and aren’t ideal to store in Git.

Instead we:

1. Use `skupper link generate` on **site-a** (`rhsi` namespace).
2. Split the resulting YAML into a `Link` resource and a TLS `Secret`.
3. Convert the TLS `Secret` into a **SealedSecret** (or similar encrypted secret).
4. Commit the `Link` + `SealedSecret` under `rhsi/site-b/`.
5. Argo on site-b applies them and brings the link up.

### 4.1 Generate the link on site-a

From an admin machine with `skupper` CLI:

```bash
# use site-a context
skupper --context site-a --namespace rhsi link generate > link-to-site-b.yaml
```

The file will contain a `Link` + `Secret` (TLS). Treat this file as **sensitive**.

### 4.2 Split and seal the TLS Secret

1. Copy the `Link` part into `rhsi/site-b/link-from-site-b.yaml`.
2. Copy the TLS `Secret` part into a temporary local file
   (NOT committed to Git), e.g. `rhsi/site-b/link-tls-secret-plain.yaml`.
3. Convert to SealedSecret:

```bash
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
  --format yaml < rhsi/site-b/link-tls-secret-plain.yaml \
  > rhsi/site-b/link-tls-sealedsecret.yaml

rm rhsi/site-b/link-tls-secret-plain.yaml
```

> The repo ships with a **placeholder** `link-tls-sealedsecret.yaml` – you **must** regenerate it
> for your environment using `kubeseal`.

4. Commit `link-from-site-b.yaml` + `link-tls-sealedsecret.yaml` to Git.

After Argo syncs for site-b:

```bash
oc --context=site-b -n rhsi get link
oc --context=site-a -n rhsi get link
```

You should see a healthy link joining the two Sites.

---

## 5. PostgreSQL primary/standby across sites

This is a lightweight example using `bitnami/postgresql-repmgr:15`:

- **Primary** on `site-a` in namespace `db`.
- **Standby** on `site-b` in namespace `db`.
- Replication traffic proxied over RHSI using Connector/Listener + routing key `pg-primary`.

### 5.1 Primary on site-a (db namespace)

`rhsi/site-a/db-primary/namespace-db.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db
```

`rhsi/site-a/db-primary/pg-primary-auth-secret.yaml` (example values – change for your lab):

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
            - name: POSTGRESQL_POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: pg-primary-auth
                  key: postgres-password
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

---

### 5.2 Expose primary via RHSI (Connector on site-a)

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

This exposes the `pg-primary` pods via the virtual application network under routing key `pg-primary`.

---

### 5.3 Listener on site-b (service targeting the primary)

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

On site-b, this creates a Service:

- Name: `pg-primary`
- Namespace: `rhsi`
- DNS: `pg-primary.rhsi.svc.cluster.local`

All traffic to that service is forwarded to the primary on site-a.

---

### 5.4 Standby on site-b (db namespace)

`rhsi/site-b/db-standby/namespace-db.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db
```

`rhsi/site-b/db-standby/pg-standby-auth-secret.yaml` (example values – change for your lab):

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

            # Standby configuration (connect to primary via RHSI)
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

            # Join as standby
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

> For full configuration options, see the Bitnami `postgresql-repmgr` image docs.  
> For a real deployment, replace this with your Postgres operator of choice.

---

## 6. Sync and test

1. Point Argo CD at:
   - `rhsi/site-a` (destination cluster `site-a`)
   - `rhsi/site-b` (destination cluster `site-b`)
2. Ensure RHSI operator is installed on both clusters in `rhsi` namespace.
3. Generate and seal the **link TLS secret**, replacing `link-tls-sealedsecret.yaml` with your own.
4. Let Argo sync both apps.

Check pods:

```bash
oc --context=site-a -n rhsi get pods
oc --context=site-a -n db get pods

oc --context=site-b -n rhsi get pods
oc --context=site-b -n db get pods
```

### 6.1 Sanity check replication

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

You should see `hello-from-site-a` in the results.

---

## 7. Next steps / integration points

- Replace Bitnami Postgres with **EDB** or another enterprise Postgres operator.
- Wire in **Vault** for database credentials using Vault Agent Injector or Secrets Operator.
- Move all secrets (DB creds, link TLS) to your preferred secret-management pattern
  (Vault, External Secrets Operator, Sealed Secrets, SOPS, etc.).
- Add RHACM Policies / PlacementRules to make RHSI + DB deployments environment-aware (dev/test/prod).
