# Operations

## 1. Where it runs

| What | Where |
|---|---|
| Database | `neo_model` on the NEO tenant Postgres, StatefulSet `iotonix-neo/postgres` (TimescaleDB 2.31 on PG 18.6), `postgres:5432` in the cluster, `10.0.0.180:20019` from outside; owner `neo_owner` |
| Consumer (writes L0) | Deployment `iotonix-neo/huawei-api`, image `huawei-api-consumer:2.1.0-d3d3afa` (repo `ait-iot-dev/hauwei-api-v2`), role `neo_ingest` |
| Model service | Deployment `iotonix-neo/neo-model`, one replica, strategy `Recreate` (never two writers), image `neo-model:0.3.1` built from `service/` |
| Read API | Deployment `iotonix-neo/neo-api` (PostgREST v12.2.3), `http://10.0.0.180:20021`, role `neo_api_auth` → `neo_api` |
| Manifests | `/opt/argocd/tenants/neo/` (repo `AIT-AI/rad_argocd`, Argo CD app `iotonix-neo`): `huawei-api.yaml`, `neo-model.yaml`, `api.yaml`, `lb.yaml`. **Argo CD is the source of truth**; `deploy/` here holds copies for reference |
| Config | SealedSecrets `huawei-api-env`, `neo-model-env`, `neo-api-env` (`tenants/neo/sealed/`); sources in `~ralf/iotonix-tenants/` (`neo-huawei-v2.env`, `neo-model.env`, `neo-api.env`, passwords in `neo.env`; mode 600, never in git) |
| Network | NetworkPolicies `model-egress`, `api-egress`: the pods reach only their own namespace and DNS |
| Other databases | `neo_model_test` (validation, docs/VALIDATION.md), `neo_model_dev` (the v0 sandbox, can be dropped) |

### Database roles

| Role | Used by | Rights |
|---|---|---|
| `neo_owner` | migrations, the model service | owner of everything |
| `neo_ingest` | the consumer (`L0_PG_DSN`) | INSERT on `raw.api_response`; SELECT, INSERT, UPDATE on `src.*` |
| `neo_api_auth` (login) → `neo_api` (no login) | PostgREST | SELECT on `api_v1.*` only |

Created once by the superuser (passwords in `neo.env`: `PG_INGEST_PASSWORD`, `PG_API_PASSWORD`):
```sql
CREATE ROLE neo_ingest LOGIN PASSWORD '…';
CREATE ROLE neo_api NOLOGIN;
CREATE ROLE neo_api_auth LOGIN NOINHERIT PASSWORD '…';
GRANT neo_api TO neo_api_auth;
```
The migrations grant the rights if the roles exist.

## 2. The model service (`service/neo_model.py`)

Every `CYCLE_S` seconds, at `OFFSET_S` after the full cycle (default every 5 minutes at +90 s, after the consumer's 5-minute fetch):

1. **asset_sync** (at start and every `ASSET_SYNC_H` hours): PR configuration (`PG_ASSET_DB`) → `asset.*`. Changed strings/devices: the
   current row is closed (`valid` upper bound = now) and a new one opened.
2. **L1**: `L1_SOURCE=l0` → module `l1_huawei`: `l1.load_huawei(from, to)` over the L0 responses fetched since the watermark
   (`calc.watermark 'l1_huawei'`) minus the module lookback (10 min), up to now − `L0_SETTLE_S`. `L1_SOURCE=influx` → the fallback
   `l1_influx` (Influx `INFLUX_DB` since watermark `ingest` minus `INGEST_OVERLAP_MIN`; on the first start a backfill of `BACKFILL_DAYS`,
   or `BACKFILL_FROM`..`BACKFILL_TO`). The loaded data time range is marked dirty for every module that depends on `l1`.
3. **Modules**: every enabled L2 module of `meta.module` with an entry point, in dependency order: merge its dirty windows, widen them
   by its `lookback`, align them to its grain, call `entrypoint(from, to, version, run_id)` per day (interval modules) or per 7 days
   (daily modules), clear the windows, mark its dependents dirty. A failing module keeps its windows (retried next cycle) and blocks
   only its dependents.

Each step writes a `calc.run` row. An exception is logged and the next cycle retries.

| Variable | Default | Meaning |
|---|---|---|
| `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD` | – / 5432 | Postgres (in the cluster: `postgres`, `neo_owner`) |
| `PG_DB` | `neo_model` | target database |
| `PG_ASSET_DB` | `pr_live_neodb` | PR configuration (plants, devices, strings, factors) |
| `L1_SOURCE` | `influx` | **`l0`** in production (set in the manifest): L1 from L0; `influx`: fallback |
| `L0_SETTLE_S` | 60 | L0 rows younger than this wait for the next cycle |
| `INFLUX_HOST`, `INFLUX_PORT`, `INFLUX_USER`, `INFLUX_PASSWORD`, `INFLUX_DB` | – / 8086 / – / – / `NEO_LIVE` | fallback source |
| `INGEST_OVERLAP_MIN`, `BACKFILL_DAYS`, `BACKFILL_FROM`, `BACKFILL_TO` | 30, 30, –, – | fallback source |
| `CYCLE_S`, `OFFSET_S` | 300, 90 | cycle |
| `ASSET_SYNC_H` | 6 | asset sync interval |
| `ONCE` | – | set: one cycle, then exit (tests, manual runs) |
| `LOGLEVEL` | INFO | |

Versions are no longer configured here: each module's version is in `meta.module`.

### Consumer settings for pipeline B (`neo-huawei-v2.env` → `huawei-api-env`)

| Variable | Value | Meaning |
|---|---|---|
| `L0_PG_DSN` | `postgresql://neo_ingest:…@postgres:5432/neo_model` | turns the Postgres sink on (L0 + `src.*`) |
| `MONGO_ENABLED` | `false` | no Mongo: master data from `src.*`, the Mongo client is a no-op |

## 3. Monitoring

```bash
kubectl -n iotonix-neo logs -f deploy/neo-model | grep -v 'observed string'
kubectl -n iotonix-neo logs -f deploy/huawei-api -c worker | grep -i 'pg_store\|L0 record'   # sink errors (should be none)
curl -s http://10.0.0.180:20021/pipeline_status                                               # lag of L1, failed runs, dirty windows
```
```sql
SELECT method, status, count(*), max(finished_at) FROM calc.run WHERE started_at > now() - interval '1 day' GROUP BY 1, 2 ORDER BY 1;
SELECT module, count(*), min(lower(win)), max(upper(win)) FROM meta.dirty_window GROUP BY 1;   -- empty after each cycle
SELECT endpoint, account, count(*), max(fetched_at), count(*) FILTER (WHERE NOT success) AS failed
FROM raw.api_response WHERE fetched_at > now() - interval '1 day' GROUP BY 1, 2;               -- the consumer's calls
SELECT * FROM dq.pr_prerequisites WHERE pr_active;
SELECT * FROM dq.config_device_missing WHERE pr_active;
```
Expected: `l1_huawei` lag < 10 min while the consumer runs (realtime 05:00–19:00 Bangkok); no failed runs; no dirty windows left.

## 4. Database setup and migrations

A new database (as the superuser), then the migrations as the owner:

```bash
psql -U postgres -c "CREATE DATABASE neo_model OWNER neo_owner TEMPLATE template0 LOCALE 'en_US.utf8'"   # template1 carries timescaledb
psql -U postgres -d neo_model -c "CREATE EXTENSION timescaledb; CREATE EXTENSION btree_gist"
PGHOST=10.0.0.180 PGPORT=20019 PGUSER=neo_owner PGPASSWORD=… PGDATABASE=neo_model sql/migrate.sh
```

`sql/migrate.sh` applies each `sql/migrations/NNN_*.sql` once, in one transaction, and records it in `meta.schema_migration` with its
sha256. **Never edit an applied migration**: add the next number. Functions are replaced with `CREATE OR REPLACE`; a view whose columns
change is dropped and recreated (and its grant repeated) in the new migration. Migrations go **before** a new image and must be
compatible with the running service. After a migration that adds or changes `api_v1` views, PostgREST reloads its schema cache by
itself on the next connection; to force it: `NOTIFY pgrst, 'reload schema'`.

## 5. Recalculation, new versions, backfill

The orchestrator does the work; you only mark windows dirty:

```sql
SELECT meta.backfill('pr_neo_customer.interval', '2026-10-23', now());   -- recompute a module for a period (its dependents follow)
```
A new module version: see METHODS.md §5 (example: `014_pr_iec_v3.sql`). Which version the app sees: `meta.api_published`.

By hand, without the service (e.g. in a test database):
```sql
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;          -- compressed chunks
INSERT INTO calc.run (kind, method, version, params) VALUES ('manual', 'pr_neo_customer.interval', 'v2', '{}') RETURNING run_id;  -- 42
SELECT calc.m_pr_customer_interval(d, d + interval '1 day', 'v2', 42)
  FROM generate_series('2026-11-04 17:00+00'::timestamptz, '2026-11-12 17:00+00', interval '1 day') d;
SELECT calc.m_pr_customer_daily('2026-11-05 00:00+00', '2026-11-13 00:00+00', 'v2', 42);
```

L1 history: L0 starts on 2026-11-22 11:28 UTC; L1 before it came from Influx `NEO_LIVE` (from 2026-10-23). Older history: run the
service once with `L1_SOURCE=influx INFLUX_DB=NEO_RESTORE BACKFILL_FROM=… BACKFILL_TO=… ONCE=1` against a database without the
`ingest` watermark (or delete it), then `meta.backfill` the PR modules for that period. One measurement and one day per Influx query.

Start from scratch: scale `neo-model` to 0, drop and recreate the database (§4), scale to 1.

## 6. Release

```bash
cd service
docker build -t registry.ait.co.th/iotonix/neo-model:0.3.2 . && docker push registry.ait.co.th/iotonix/neo-model:0.3.2
docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' registry.ait.co.th/iotonix/neo-model:0.3.2 | grep registry.ait
# /opt/argocd: set image …:0.3.2@sha256:… in tenants/neo/neo-model.yaml, commit only that file, push; Argo CD syncs
# (or: kubectl -n argocd annotate application iotonix-neo argocd.argoproj.io/refresh=hard --overwrite)
```

Config change (secret): edit the source env file, then

```bash
kubectl create secret generic neo-model-env -n iotonix-neo --from-env-file=$HOME/iotonix-tenants/neo-model.env --dry-run=client -o yaml \
 | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o yaml \
 > /opt/argocd/tenants/neo/sealed/neo-model-env.sealed.yaml
```
commit, push, and restart the pod (`kubectl -n iotonix-neo rollout restart deploy/neo-model`): env from a secret is read at start only.
For `huawei-api-env` the env file holds external host names; build the secret from the deployed one plus the change (as done for F16),
or switch the hosts to the in-cluster names (`postgres`, `influxdb`, `mongo`) before sealing.

## 7. Rollback switches

| Problem | Switch |
|---|---|
| L0 path wrong or broken | model service: `L1_SOURCE=influx` (manifest); L1 continues from Influx (the consumer still writes it) |
| Consumer without Mongo misbehaves | consumer: `MONGO_ENABLED=true` (secret); it reads and writes `NeoLive` again (frozen since 2026-11-22 11:28, refresh it from `src.*` or a sync run) |
| A new calculation version is wrong | `meta.api_published` back to the old version; the old rows are still there |
| Postgres sink errors | consumer: remove `L0_PG_DSN`; Influx (pipeline A) is not affected either way |

## 8. Rules

- The model service and the API **only read** the copies and the live sources; the service writes only its own database, the API nothing.
- No heavy ad-hoc queries on the Influx pod (`SELECT *` over the full history once OOM-killed it): one measurement, one day per query.
- Never connect to customer servers (192.168.1.14, 10.0.88.11) from here; the NetworkPolicies enforce it for the pods.
- Never run a second consumer with the same Huawei accounts (quota).
