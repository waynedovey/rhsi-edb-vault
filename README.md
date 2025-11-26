# RHSI EDB + Skupper + Vault Demo

This repo shows how to:

* Run an EDB-style PostgreSQL primary on **site‑a** and a standby on **site‑b**.
* Connect the two clusters using **Skupper**.
* Store the Skupper **AccessGrant** in **Vault** and pull it into **site‑b** using **External Secrets Operator (ESO)**.
* Automatically create / rotate the Skupper **AccessToken** on **site‑b** via a **Job**.

Tested on:

* OpenShift 4.x
* Skupper 2.1.1 (router 3.4.0)
* External Secrets Operator 0.9+
* HashiCorp Vault (KV v2)

> **Naming used below**
>
> * Context `site-a` – primary cluster (Postgres primary + Skupper grant server)
> * Context `site-b` – standby cluster (Postgres standby + Skupper link)
> * Namespace `rhsi` in both clusters

---

## 1. Prereqs

### 1.1. CLI contexts

Make sure your `kubeconfig` has both contexts:

```bash
oc config get-contexts
# ... site-a, site-b present ...
```

Throughout the docs we’ll assume:

```bash
export SITE_A_CTX=site-a
export SITE_B_CTX=site-b
export NAMESPACE=rhsi
```

### 1.2. Skupper installed

Install Skupper on both clusters in the `rhsi` namespace. For example:

```bash
skupper --context "$SITE_A_CTX" init -n "$NAMESPACE"
skupper --context "$SITE_B_CTX" init -n "$NAMESPACE"
```

You should be able to see the sites:

```bash
oc --context "$SITE_A_CTX" -n "$NAMESPACE" get site
oc --context "$SITE_B_CTX" -n "$NAMESPACE" get site
```

### 1.3. Vault + ESO wired up

On **site‑b**, you must already have:

* A `SecretStore` pointing at Vault, called `vault-rhsi`.
* ESO installed and working in the `rhsi` namespace.

The repo assumes Vault KV path:

```text
rhsi/site-b/link-token
```

containing keys:

* `url` – Skupper AccessGrant URL
* `code` – Skupper AccessGrant code
* `ca` – Skupper grant-server CA certificate

---

## 2. Flow overview

High level:

1. On **site‑a** we create a Skupper `AccessGrant` (`rhsi-standby-grant`).
2. A helper script `40-accessgrant-to-vault.sh` reads the grant from `site-a` and writes it into Vault at `rhsi/site-b/link-token`.
3. On **site‑b**, ESO (`ExternalSecret rhsi-link-token`) pulls the Vault secret into a regular Kubernetes `Secret rhsi-link-token`.
4. A Job (`create-access-token-from-vault`) on **site‑b** reads `rhsi-link-token` and creates an `AccessToken` CR `standby-from-vault` in the `rhsi` namespace.
5. Skupper on **site‑b** uses the `AccessToken` to create a link back to **site‑a**.
6. Postgres standby on **site‑b** can now reach Postgres primary on **site‑a** via Skupper.

The fix for the issue we hit was mainly:

* Ensure the AccessGrant allows multiple redemptions (`redemptionsAllowed`).
* Ensure we **do not** leave behind a conflicting `Secret standby-from-vault`.
* Add a proper Job that creates the `AccessToken` in the correct namespace with good debug output.
* Provide a sanity-check script to verify everything.

---

## 3. AccessGrant on site‑a

YAML: [`rhsi/access-standby-accessgrant.yaml`](rhsi/access-standby-accessgrant.yaml)

```yaml
apiVersion: skupper.io/v2alpha1
kind: AccessGrant
metadata:
  name: rhsi-standby-grant
  namespace: rhsi
spec:
  # How long the grant is valid for after creation
  expirationWindow: 1h
  # Allow multiple redemptions while we’re testing / rotating tokens
  redemptionsAllowed: 10
```

Apply and wait:

```bash
oc --context "$SITE_A_CTX" -n "$NAMESPACE" apply -f rhsi/access-standby-accessgrant.yaml

oc --context "$SITE_A_CTX" -n "$NAMESPACE" wait accessgrant rhsi-standby-grant   --for=condition=Ready --timeout=60s

oc --context "$SITE_A_CTX" -n "$NAMESPACE" get accessgrant rhsi-standby-grant -o yaml
```

You should see `status.status: Ready` and populated `status.url`, `status.code`, and `status.ca`.

---

## 4. Script: write AccessGrant to Vault

Script: [`scripts/40-accessgrant-to-vault.sh`](scripts/40-accessgrant-to-vault.sh)

This script:

1. Reads the `AccessGrant` on **site‑a**.
2. Extracts `status.url`, `status.code`, `status.ca`.
3. Writes them into Vault at `rhsi/site-b/link-token`.
4. Verifies the values.

Usage:

```bash
export SITE_A_CTX=site-a
export NAMESPACE=rhsi

# VAULT_ADDR / VAULT_TOKEN should already be set in your shell

./scripts/40-accessgrant-to-vault.sh
```

You should see it printing the URL, code, and CA, plus confirmation from Vault.

---

## 5. ExternalSecret on site‑b

YAML: [`rhsi/standby/30-externalsecret-rhsi-link-token.yaml`](rhsi/standby/30-externalsecret-rhsi-link-token.yaml)

This ExternalSecret pulls the Vault secret and writes:

* `Secret rhsi-link-token` in `rhsi` namespace.
* Fields: `url`, `code`, `ca` (base64 encoded, as usual for Kubernetes Secrets).

Check that the `SecretStore vault-rhsi` and `ExternalSecret rhsi-link-token` are created and (eventually) `READY`:

```bash
oc --context "$SITE_B_CTX" -n "$NAMESPACE" get secretstore,externalsecret
```

You can inspect the secret itself:

```bash
oc --context "$SITE_B_CTX" -n "$NAMESPACE" get secret rhsi-link-token -o yaml

SECRET_URL="$(
  oc --context "$SITE_B_CTX" -n "$NAMESPACE" get secret rhsi-link-token     -o jsonpath='{.data.url}' | base64 -d
)"
SECRET_CODE="$(
  oc --context "$SITE_B_CTX" -n "$NAMESPACE" get secret rhsi-link-token     -o jsonpath='{.data.code}' | base64 -d
)"

echo "SECRET_URL=${SECRET_URL}"
echo "SECRET_CODE=${SECRET_CODE}"
```

They should match the `AccessGrant.status.url` and `AccessGrant.status.code` on **site‑a**.

---

## 6. Job on site‑b to create AccessToken

YAML: [`rhsi/standby/80-job-create-access-token.yaml`](rhsi/standby/80-job-create-access-token.yaml)

This Job:

1. Waits for `Secret rhsi-link-token` to exist.
2. Reads `code`, `url`, and `ca` out of the Secret.
3. Applies an `AccessToken` CR `standby-from-vault` in namespace `rhsi`.
4. Prints some debug: what cluster it is connected to, what AccessTokens it sees before and after.

Apply it once (or let ArgoCD or your GitOps tool manage it):

```bash
oc --context "$SITE_B_CTX" -n "$NAMESPACE" apply -f rhsi/standby/80-job-create-access-token.yaml
oc --context "$SITE_B_CTX" -n "$NAMESPACE" logs -f job/create-access-token-from-vault
```

You should see logs like:

```text
Waiting for Secret rhsi-link-token to exist...
Secret rhsi-link-token found.
Reading AccessToken fields from Secret rhsi-link-token...
Creating AccessToken standby-from-vault in rhsi...
oc apply output:
accesstoken.skupper.io/standby-from-vault created
...
Job complete: AccessToken standby-from-vault creation flow finished.
```

Then:

```bash
oc --context "$SITE_B_CTX" -n "$NAMESPACE" get accesstoken standby-from-vault -o yaml
```

The `spec` fields should match the `AccessGrant` values and the Secret contents. The `status` may be updated by Skupper’s controllers once the link is used.

> **Important cleanups**
>
> * Make sure there is **no** conflicting `Secret standby-from-vault` in any namespace. Skupper wants to create that Secret itself.
> * If you change the grant, re-run:
>   * `40-accessgrant-to-vault.sh`
>   * Wait for `ExternalSecret` to refresh or annotate it with `reconcile.external-secrets.io/refresh=true`.
>   * Re-run the Job (or let GitOps re-run it by updating the template).

---

## 7. Sanity check script

Script: [`scripts/sanity-check-skupper-vault-link.sh`](scripts/sanity-check-skupper-vault-link.sh)

This script runs a series of checks across both clusters:

* AccessGrant exists and Ready on **site‑a**.
* SecretStore and ExternalSecret status on **site‑b**.
* `rhsi-link-token` Secret contents match the AccessGrant and Vault.
* AccessToken `standby-from-vault` exists on **site‑b`.
* Skupper sites show a network size of 2.

Usage:

```bash
export SITE_A_CTX=site-a
export SITE_B_CTX=site-b
export NAMESPACE=rhsi

bash ./scripts/sanity-check-skupper-vault-link.sh
```

You should see `[OK]` lines all the way down when everything is healthy.

---

## 8. Postgres connectivity test

Once Skupper is up and the link is established (site network size shows 2), you can test Postgres connectivity from **site‑b** to **site‑a** via Skupper.

Example:

```bash
oc --context "$SITE_B_CTX" -n "$NAMESPACE" exec -it deploy/postgres-standby -- bash

export PGPASSWORD='supersecret'

psql   -h postgres-primary   -p 5432   -U appuser   -d postgres
```

Inside psql:

```sql
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

You should see the row coming from **site‑b** inserted into the primary Postgres on **site‑a**.

---

## 9. Operational notes

* To rotate the link token:
  1. Delete and recreate the `AccessGrant` on **site‑a**.
  2. Run `scripts/40-accessgrant-to-vault.sh` to push the new grant to Vault.
  3. Force ESO to refresh (`kubectl annotate externalsecret rhsi-link-token reconcile.external-secrets.io/refresh=true --overwrite`).
  4. Re-run the Job `create-access-token-from-vault` on **site‑b**.

* If you ever see `Controller got failed response: 404 (Not Found) No such access granted` in the AccessToken status, it usually means:
  * The grant has expired.
  * Or the code/url pair doesn’t match a current grant (stale secret).
  * Or the grant was already fully redeemed and `redemptionsAllowed` was too low.

Increasing `redemptionsAllowed` and ensuring all moving pieces (AccessGrant, Vault, ExternalSecret, AccessToken) are in sync fixes these issues.

---

## 10. Files in this repo

* `README.md` – this document
* `rhsi/access-standby-accessgrant.yaml` – AccessGrant on site‑a
* `rhsi/standby/30-externalsecret-rhsi-link-token.yaml` – ESO wiring on site‑b
* `rhsi/standby/80-job-create-access-token.yaml` – Job on site‑b to create AccessToken
* `scripts/40-accessgrant-to-vault.sh` – site‑a → Vault helper
* `scripts/sanity-check-skupper-vault-link.sh` – cross-cluster sanity check

Use this as a starting point for productionising the pattern (tighter RBAC, better rotation, GitOps for manifests and scripts, etc.).
