

## End-to-end PostgreSQL connectivity test (via Skupper)

Once the Skupper sites, link, connector and listener are all `Ready`, you can do
a quick end-to-end test from **site-b** to the primary PostgreSQL instance on
**site-a** using the existing `postgres-standby` Deployment.

From your workstation:

```bash
# Exec into the standby pod on site-b
oc --context site-b -n rhsi exec -it deploy/postgres-standby -- bash
```

Inside the container:

```bash
export PGPASSWORD='supersecret'

psql \
  -h postgres-primary \
  -p 5432 \
  -U appuser \
  -d postgres
```

You should see a `postgres=>` prompt. Run the following to prove traffic is
successfully flowing from **site-b** to the **site-a** primary:

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

You should see a row similar to:

```text
 id |        site        |          created_at
----+--------------------+-------------------------------
  1 | site-b-via-skupper | 2025-11-24 22:24:44.824008+00
```

This confirms:

- The `postgres-standby` pod on **site-b** can resolve `postgres-primary`
- Skupper is carrying traffic to the **site-a** primary service
- Authentication for user `appuser` with password `supersecret` is working

