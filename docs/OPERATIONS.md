# Operations

## 1. Where it runs

| What | Where |
|---|---|
| Database | `neo_model` on the NEO tenant Postgres, StatefulSet `iotonix-neo/postgres` (TimescaleDB 2.31 on PG 18.6), `postgres:5432` in the cluster, `10.0.0.180:20019` from outside; owner `neo_owner` |
| Service | Deployment `iotonix-neo/neo-model`, one replica, strategy `Recreate` (never two writers) |
| Manifest | `/opt/argocd/tenants/neo/neo-model.yaml` (repo `AIT-AI/rad_argocd`, Argo CD app `iotonix-neo`). **Argo CD is the source of truth**; `deploy/neo-model.yaml` here is a copy for reference |
| Image | `registry.ait.co.th/iotonix/neo-model:<version>`, built from `service/`, pinned by digest in the manifest |
| Config | SealedSecret `neo-model-env` (`/opt/argocd/tenants/neo/sealed/neo-model-env.sealed.yaml`), source `~ralf/iotonix-tenants/neo-model.env` (mode 600, never in git) |
| Network | NetworkPolicy `model-egress`: the pod reaches only its own namespace and DNS (no customer servers) |
| Other databases | `neo_model_test` (validation, docs/VALIDATION.md), `neo_model_dev` (the v0 sandbox, can be dropped) |

## 2. The service (`service/neo_model.py`)

Every `CYCLE_S` seconds, at `OFFSET_S` after the full cycle (default every 5 minutes at +90 s, so the 5-minute data has arrived):

1. **Asset sync** (at start and every `ASSET_SYNC_H` hours) from the PR configuration database (`PG_ASSET_DB`) into `asset.*`. Changed
   strings/devices: the current row is closed (`valid` upper bound = now) and a new one opened; unchanged rows are not touched.
2. **Ingest** L1 from Influx (`INFLUX_DB`) since the watermark `calc.watermark('ingest')` minus `INGEST_OVERLAP_MIN` (late data), one
   measurement and one day per query, `ON CONFLICT DO NOTHING`. Unknown sensorIds go to `dq.unknown_sensor`; an unconfigured string input
   becomes an observed string (`configured = false`) once it carries ≥ 1 A.
3. **Compute** `calc.compute_intervals` for the last `PR_LOOKBACK_H` hours and `calc.compute_daily` for yesterday and today
   (local days), version `CALC_VERSION`.

Each step writes a `calc.run` row (status `running` → `ok`/`failed`, rows, parameters). An exception is logged and the next cycle retries.
**First start** (no watermark): backfill `BACKFILL_DAYS` back from now, or `BACKFILL_FROM`..`BACKFILL_TO` (local dates), then normal cycles.

| Variable | Default | Meaning |
|---|---|---|
| `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD` | – / 5432 | Postgres (in the cluster: `postgres`, `neo_owner`) |
| `PG_DB` | `neo_model` | target database |
| `PG_ASSET_DB` | `pr_live_neodb` | PR configuration (plants, devices, strings, factors) |
| `INFLUX_HOST`, `INFLUX_PORT`, `INFLUX_USER`, `INFLUX_PASSWORD`, `INFLUX_DB` | – / 8086 / – / – / `NEO_LIVE` | the live time series |
| `CALC_VERSION` | `v2` | the `version` written to L2 |
| `CYCLE_S`, `OFFSET_S` | 300, 90 | cycle |
| `PR_LOOKBACK_H` | 3 | intervals recomputed each cycle |
| `BACKFILL_DAYS` / `BACKFILL_FROM`, `BACKFILL_TO` | 30 / – | first start |
| `ASSET_SYNC_H` | 6 | asset sync interval |
| `INGEST_OVERLAP_MIN` | 30 | re-read window for late data |
| `ONCE` | – | set: one cycle, then exit (for tests and manual runs) |
| `LOGLEVEL` | INFO | |

## 3. Monitoring

```bash
kubectl -n iotonix-neo logs -f deploy/neo-model | grep -v 'observed string'
psql -h 10.0.0.180 -p 20019 -U neo_owner -d neo_model
```
```sql
SELECT kind, status, count(*), max(finished_at) FROM calc.run WHERE started_at > now() - interval '1 day' GROUP BY 1, 2;
SELECT * FROM calc.watermark;                                   -- ingest should be < 10 min behind
SELECT * FROM calc.run WHERE status = 'failed' ORDER BY run_id DESC LIMIT 5;
SELECT job_id, application_name, last_run_status, next_start FROM timescaledb_information.job_stats JOIN timescaledb_information.jobs USING (job_id);
SELECT * FROM dq.pr_prerequisites WHERE pr_active;              -- what blocks a plant's customer PR
```

## 4. Database setup and migrations

A new database (as the superuser, `postgres-superuser` secret), then the migrations as the owner:

```bash
psql -U postgres -c "CREATE DATABASE neo_model OWNER neo_owner TEMPLATE template0 LOCALE 'en_US.utf8'"   # template1 carries timescaledb
psql -U postgres -d neo_model -c "CREATE EXTENSION timescaledb; CREATE EXTENSION btree_gist"
PGHOST=10.0.0.180 PGPORT=20019 PGUSER=neo_owner PGPASSWORD=… PGDATABASE=neo_model sql/migrate.sh
```

`sql/migrate.sh` applies each `sql/migrations/NNN_*.sql` once, in one transaction, and records it in `meta.schema_migration` with its
sha256. **Never edit an applied migration**: add the next number (a changed file is reported, not re-applied).
Functions and views are replaced with `CREATE OR REPLACE` in a new migration.

## 5. Recalculation and backfill

Recompute any period by hand (idempotent upsert; compressed chunks need the decompression limit lifted):

```sql
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
INSERT INTO calc.run (kind, method, version, params) VALUES ('intervals', 'manual', 'v2', '{"why": "…"}') RETURNING run_id;  -- e.g. 42
SELECT calc.compute_intervals(d, d + interval '1 day', 'v2', 42)                      -- one day per call keeps temp tables small
  FROM generate_series('2026-10-23'::timestamptz, '2026-11-21', interval '1 day') d;
SELECT calc.compute_daily('2026-10-23', '2026-11-22', 'v2', 42);
UPDATE calc.run SET status = 'ok', finished_at = now() WHERE run_id = 42;
CALL refresh_continuous_aggregate('rpt.inverter_energy_daily', '2026-10-23', '2026-11-23');   -- and the other caggs, if L1 changed
```

A new **version**: change `CALC_VERSION` in the secret (or run the functions by hand with the new version), backfill, compare
(`tests/validate.sql` reads the version), then delete the old version's rows when nobody needs them.

L1 history beyond NEO_LIVE (it holds 2026-10-23 onwards): set `PG_DB` to a fresh database and `BACKFILL_FROM`, or ingest by hand from
`NEO_RESTORE` (the exact prod copy since 2024-04) with `INFLUX_DB=NEO_RESTORE ONCE=1`. Mind: NEO_RESTORE writes `deviceName` as an
extra tag; the ingest groups by `sensorId`, so this does not matter.

Start from scratch: scale the deployment to 0, drop and recreate the database (§4), scale to 1 (first start = backfill).

## 6. Release

```bash
cd service
docker build -t registry.ait.co.th/iotonix/neo-model:0.3.0 . && docker push registry.ait.co.th/iotonix/neo-model:0.3.0
docker inspect --format '{{index .RepoDigests 0}}' registry.ait.co.th/iotonix/neo-model:0.3.0
# /opt/argocd: set image …:0.3.0@sha256:… in tenants/neo/neo-model.yaml, show the diff, commit only that file, push; Argo CD syncs.
```

Migrations go **before** the new image (run `sql/migrate.sh` first; migrations must be backward compatible with the running service).

Config change: edit `~ralf/iotonix-tenants/neo-model.env`, then

```bash
kubectl create secret generic neo-model-env -n iotonix-neo --from-env-file=$HOME/iotonix-tenants/neo-model.env --dry-run=client -o yaml \
 | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o yaml \
 > /opt/argocd/tenants/neo/sealed/neo-model-env.sealed.yaml
```
commit, push, and restart the pod (`kubectl -n iotonix-neo rollout restart deploy/neo-model`): env from a secret is read at start only.

## 7. Rules

- The service and anyone using this model **only read** the copies (`neo_*`, `pr_*`, `NEO_RESTORE`, `PR_RESTORE`) and the live
  databases (`NEO_LIVE`, `pr_live_neodb`); it writes only its own database.
- No heavy ad-hoc queries on the Influx pod (`SELECT *` over the full history once OOM-killed it): one measurement, one day per query.
- Never connect to customer servers (192.168.1.14, 10.0.88.11) from here; the NetworkPolicy enforces it for the pod.
