# rhsi-edb-vault

End-to-end example for:

* Red Hat Service Interconnect (RHSI, Skupper v2 API)
* OpenShift GitOps (Argo CD) + RHACM ApplicationSet **cluster decision** generator
* A simple PostgreSQL primary/standby logical replication test across two OpenShift clusters

The repo assumes:

* **Hub cluster** with **RHACM** and **OpenShift GitOps** (namespace `openshift-gitops`).
* Two managed clusters called **`site-a`** and **`site-b`** in ACM (`ManagedCluster` names).
* Red Hat Service Interconnect operator installed on each *application* cluster.
* You want to avoid hard-coding API URLs like `https://api.site-a...` in your manifests.
  * We use **Placement + ApplicationSet + clusterDecisionResource** so Argo learns the
    right cluster API URLs dynamically from ACM.

> 🔐 This repo deliberately **does not** contain any real tokens or TLS material.
> You generate RHSI link tokens once per environment and (optionally) convert
> them to SealedSecrets in your own fork of this repo.

---

## 1. Topology

* **Hub**: RHACM + OpenShift GitOps (`openshift-gitops`).
* **Managed clusters** (OpenShift):
  * `site-a` – will be labelled as **primary**.
  * `site-b` – will be labelled as **standby**.

On the clusters:

* Namespace `rhsi` contains:
  * RHSI **Site** CRs.
  * Postgres **primary** on whichever cluster is labelled `rhsi-role=primary`.
  * Postgres **standby** on whichever cluster is labelled `rhsi-role=standby`.
  * RHSI **Connector** on the primary side and **Listener** on the standby side
    for a cross-site `postgres-primary` service.
* Logical replication is configured manually using `psql` once connectivity is in place.

---

## 2. Repo layout

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
   ├─ primary/
   │  ├─ 00-namespace-rhsi.yaml
   │  ├─ 10-site.yaml
   │  ├─ 20-postgres-primary-secret.yaml
   │  ├─ 30-postgres-primary-deployment.yaml
   │  ├─ 40-postgres-primary-service.yaml
   │  └─ 50-connector-postgres.yaml
   └─ standby/
      ├─ 00-namespace-rhsi.yaml
      ├─ 10-site.yaml
      ├─ 20-postgres-standby-secret.yaml
      ├─ 30-postgres-standby-deployment.yaml
      ├─ 40-postgres-standby-service.yaml
      └─ 50-listener-postgres.yaml
```

---

## 3. Prerequisites

On the **hub** cluster:

1. **RHACM** is installed and managing `site-a` and `site-b`.

   ```bash
   oc get managedcluster
   # NAME            HUB ACCEPTED   JOINED   AVAILABLE
   # local-cluster   true           True     True
   # site-a          true           True     True
   # site-b          true           True     True
   ```

2. **OpenShift GitOps** operator is installed (default namespace `openshift-gitops`).

3. The **GitOps–ACM integration** is in place:
   * A `ManagedClusterSet` and `ManagedClusterSetBinding` that includes
     `site-a` and `site-b` is bound to `openshift-gitops`.
   * A `GitOpsCluster` registers those managed clusters to the
     OpenShift GitOps instance.
   * If you don’t already have this, see `hub/optional-30-gitopscluster-example.yaml`
     as a starting point (and the ACM Applications docs).

On **each managed cluster (`site-a`, `site-b`)**:

4. Install **Red Hat Service Interconnect** operator into namespace `rhsi`
   (or globally and then target `rhsi`).

5. `skupper` CLI installed locally (optional but useful for debugging).

On your **laptop**:

6. `oc` CLI with contexts for hub, `site-a`, and `site-b`.
7. Optional but recommended:
   * `kubeseal` + SealedSecrets controller if you want to GitOps your RHSI link
     TLS secrets (not included by default in this repo).

---

## 4. Label the managed clusters

We use **labels** on the ACM `ManagedCluster` resources and **Placement**
to drive which cluster gets which manifests.

On the hub cluster:

```bash
# Primary site
oc label managedcluster site-a rhsi-role=primary --overwrite

# Standby site
oc label managedcluster site-b rhsi-role=standby --overwrite
```

You can relabel later if you ever want to switch roles; the ApplicationSets
will re-target automatically.

---

## 5. Register clusters to OpenShift GitOps (GitOpsCluster)

If you **already** have GitOps–ACM integration set up, you can skip this
section and move to [Section 6](#6-create-placements-on-the-hub).

Otherwise, on the hub:

1. Make sure you have a `ManagedClusterSet` with your OpenShift clusters
   and a `ManagedClusterSetBinding` that binds that set to the
   `openshift-gitops` namespace (see the ACM docs).

2. Create a **Placement** listing the OpenShift clusters you want GitOps
   to manage, for example:

   ```bash
   cat << 'EOF' | oc apply -f -
   apiVersion: cluster.open-cluster-management.io/v1beta1
   kind: Placement
   metadata:
     name: all-openshift-clusters
     namespace: openshift-gitops
   spec:
     predicates:
     - requiredClusterSelector:
         labelSelector:
           matchExpressions:
           - key: vendor
             operator: In
             values:
             - OpenShift
   EOF
   ```

3. Create a **GitOpsCluster** that binds that Placement to your
   `openshift-gitops` instance (see `hub/optional-30-gitopscluster-example.yaml`):

   ```bash
   oc apply -f hub/optional-30-gitopscluster-example.yaml
   ```

After a short period, OpenShift GitOps will create cluster credentials for
each selected `ManagedCluster`. ACM also installs a ConfigMap called
`acm-placement` in `openshift-gitops` that the `clusterDecisionResource`
generator uses.

---

## 6. Create Placements on the hub

These determine which clusters get the primary vs standby manifests.

```bash
oc apply -f hub/10-placement-rhsi-primary.yaml
oc apply -f hub/11-placement-rhsi-standby.yaml
```

* `rhsi-primary` selects clusters with label `rhsi-role=primary`.
* `rhsi-standby` selects clusters with label `rhsi-role=standby`.

You can verify the placement decisions with:

```bash
oc -n openshift-gitops get placementdecisions
```

---

## 7. Create ApplicationSets on the hub

Now create the two ApplicationSets that use the **clusterDecisionResource**
generator. These use the ACM-provided ConfigMap `acm-placement`.

```bash
oc apply -f hub/20-applicationset-rhsi-primary.yaml
oc apply -f hub/21-applicationset-rhsi-standby.yaml
```

What happens:

* The ApplicationSet controller reads the PlacementDecisions from ACM.
* For each cluster in the decision list it renders an Argo CD Application:
  * One Application for each **primary** cluster (path `rhsi/primary`).
  * One Application for each **standby** cluster (path `rhsi/standby`).
* The `destination.server` in each Application is populated dynamically
  from the ACM integration – no API URLs are hard-coded in this repo.

You can see the generated Applications in the OpenShift GitOps UI or with:

```bash
oc -n openshift-gitops get applications.argoproj.io | grep rhsi-
```

---

## 8. What gets deployed on each cluster

### 8.1 Primary cluster(s) (`rhsi-role=primary`)

From `rhsi/primary`:

* Namespace `rhsi`.
* RHSI Site CR: `Site/rhsi-primary`.
* PostgreSQL deployment + service:
  * `Deployment/postgres-primary`
  * `Service/postgres-primary`
* RHSI Connector:
  * `Connector/postgres` (routing key `postgres`) pointing to the primary DB.

### 8.2 Standby cluster(s) (`rhsi-role=standby`)

From `rhsi/standby`:

* Namespace `rhsi` (same name, created independently).
* RHSI Site CR: `Site/rhsi-standby`.
* PostgreSQL deployment + service:
  * `Deployment/postgres-standby`
  * `Service/postgres-standby`
* RHSI Listener:
  * `Listener/postgres-primary` that exposes a local service
    `postgres-primary.rhsi.svc` on the standby cluster, forwarding
    to the `postgres` connector on the primary site.

Once the RHSI sites are linked, any pod in the standby cluster in
namespace `rhsi` can reach the primary database at:

```text
postgres-primary.rhsi.svc.cluster.local:5432
```

---

## 9. Creating a RHSI link (one-time bootstrap per environment)

This repo deliberately **does not** include the link definition or TLS
material, because they are environment-specific and sensitive.

The usual GitOps-friendly pattern is:

1. **On the primary site** (`site-a`), log in with `oc` and ensure the
   `Site` CR is ready:

   ```bash
   oc --context site-a -n rhsi get site
   ```

2. Use the `skupper` CLI to generate a **link** definition and TLS secret
   as YAML instead of a binary token file:

   ```bash
   # On site-a (primary)
   skupper --namespace rhsi link generate rhsi-to-standby > /tmp/rhsi-to-standby.yaml
   ```

   The file contains:

   * `Link` resource (`kind: Link`)
   * `Secret` (`type: kubernetes.io/tls`) holding the TLS key and CA

3. Optional but recommended: turn the TLS secret into a **SealedSecret**
   so you can safely store it in Git.

   ```bash
   # Adjust namespace if your SealedSecrets controller watches another ns
   kubeseal \
     --controller-namespace kube-system \
     --controller-name sealed-secrets-controller \
     --format yaml <(yq e 'select(.kind=="Secret")' /tmp/rhsi-to-standby.yaml) \
     > rhsi/standby/60-link-tls-sealedsecret.yaml
   ```

4. Extract the `Link` resource from the YAML (without the Secret)
   and save it under `rhsi/standby/55-link.yaml`:

   ```bash
   yq e 'select(.kind=="Link")' /tmp/rhsi-to-standby.yaml \
     > rhsi/standby/55-link.yaml
   ```

5. Commit those two files to **your fork** of this repository and
   let ArgoCD sync them to the **standby** cluster(s).

Once synced, you should see a link become `Ready` on the standby site:

```bash
skupper --namespace rhsi link status
```

From this point onward, the link definition and TLS identity are managed
by GitOps just like the rest of your manifests.

> Note: There are more advanced flows using `AccessGrant` and `AccessToken`
> CRs. The pattern above sticks to the documented
> `skupper link generate` → GitOps → SealedSecret flow.

---

## 10. PostgreSQL logical replication example

Once connectivity via RHSI is working, you can set up **logical replication**
between the primary and standby Postgres instances. This is intentionally
simple and uses Docker Hub’s `postgres:15` image for clarity.

### 10.1 Create schema and publication on the primary

On **site-a** (primary), open a shell into the Postgres pod:

```bash
oc --context site-a -n rhsi exec -it deploy/postgres-primary -- bash
```

Inside the pod, run:

```bash
psql -U appuser -d appdb << 'EOF'
CREATE TABLE IF NOT EXISTS demo (
  id   integer PRIMARY KEY,
  msg  text
);

-- Enable logical replication on the table
DROP PUBLICATION IF EXISTS demo_pub;
CREATE PUBLICATION demo_pub FOR TABLE demo;
EOF
```

Leave the pod shell.

### 10.2 Create schema and subscription on the standby

On **site-b** (standby), open a shell into the standby Postgres pod:

```bash
oc --context site-b -n rhsi exec -it deploy/postgres-standby -- bash
```

Inside the pod, create the same table:

```bash
psql -U appuser -d appdb << 'EOF'
CREATE TABLE IF NOT EXISTS demo (
  id   integer PRIMARY KEY,
  msg  text
);
EOF
```

Now create a **subscription** that connects to the primary database via
RHSI (the listener service `postgres-primary` in the same namespace):

```bash
psql -U appuser -d appdb << 'EOF'
DROP SUBSCRIPTION IF EXISTS demo_sub;

CREATE SUBSCRIPTION demo_sub
  CONNECTION 'host=postgres-primary port=5432 dbname=appdb user=appuser password=supersecret'
  PUBLICATION demo_pub;
EOF
```

Leave the pod shell.

> Note: For a real setup you would:
> * Use stronger credentials and secrets managed by Vault or Kubernetes Secrets.
> * Tune `wal_level`, `max_wal_senders`, `max_replication_slots` etc.
>   via a ConfigMap + mounted `postgresql.conf`.
> * Use persistent volumes instead of `emptyDir`.

### 10.3 Test replication

On the **primary**:

```bash
oc --context site-a -n rhsi exec -it deploy/postgres-primary -- \
  psql -U appuser -d appdb -c "INSERT INTO demo (id, msg) VALUES (1, 'hello-from-primary');"
```

On the **standby**:

```bash
oc --context site-b -n rhsi exec -it deploy/postgres-standby -- \
  psql -U appuser -d appdb -c "SELECT * FROM demo;"
```

You should see the row inserted on the primary appear on the standby.

---

## 11. Cleaning up

To remove everything created by this repo (but **not** the operators):

On the hub:

```bash
oc delete -f hub/21-applicationset-rhsi-standby.yaml
oc delete -f hub/20-applicationset-rhsi-primary.yaml
oc delete -f hub/11-placement-rhsi-standby.yaml
oc delete -f hub/10-placement-rhsi-primary.yaml
```

On each application cluster (optional if you want the namespace removed):

```bash
oc --context site-a delete ns rhsi
oc --context site-b delete ns rhsi
```

If you created any SealedSecrets for links, remove those from your repo
or delete them from the clusters as appropriate.

---

## 12. Next steps

* Replace the Docker Hub Postgres image with a supported RHEL / EDB image.
* Wire database credentials into Vault and inject them into your deployments.
* Add NetworkPolicies around the `rhsi` namespace.
* Use more advanced RHSI constructs (AccessGrant, AccessToken) once you are
  comfortable with the basics.

## Installing the Red Hat Service Interconnect operator via Argo CD

This repo now includes `hub/05-rhsi-operator.yaml`, which installs the **Red Hat Service Interconnect**
Operator (`red-hat-service-interconnect`) in the `openshift-operators` namespace using an
`OperatorGroup` + `Subscription`.

If you are using Argo CD on the hub, make sure your Argo CD `Application` (or `ApplicationSet`) that
targets the `hub/` directory has permissions to sync into cluster‑scoped and `openshift-*` namespaces.
Once that application is synced, the RHSI operator and its CRDs (`skupper.io/Site`, `skupper.io/Connector`, etc.)
will be available on the managed clusters where the operator installs.
