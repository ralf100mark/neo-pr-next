# NEO data model

The data model of the NEO redesign: a **physical asset model of the solar plants down to the PV string**, measured time series and
**performance ratio (PR) per interval and day** in PostgreSQL + TimescaleDB, kept current by a small service.
It computes PR in two methods side by side: **IEC 61724-1** and the **customer's method (NEOVision)**. The customer's method reproduces the old system
(PR as-is 0.2) exactly; it was validated field by field.

```
Huawei FusionSolar API → consumer v2 → Influx NEO_LIVE ─┐
PR configuration (Postgres pr_live_neodb) ──────────────┼─► neo-model service ─► neo_model:  asset · ts (L1) · calc (L2) · rpt (L3) · dq
                                                        └─  every 5 min           Timescale: compression, continuous aggregates
```

## Contents

| Path | What |
|---|---|
| `sql/migrations/001…009_*.sql` | the schema: base, asset, raw + ts, calc, PR functions, rpt, policies, dq, compat |
| `sql/migrate.sh` | applies the migrations once each (checksummed) |
| `service/` | `neo_model.py` (asset sync, L1 ingest, L2 compute loop), Dockerfile, requirements |
| `tools/load_reference.py` | loads the old system's PR results as a reference |
| `tests/validate.sql` | field-by-field comparison with the reference |
| `deploy/neo-model.yaml` | copy of the Kubernetes manifest (source of truth: `/opt/argocd/tenants/neo/neo-model.yaml`) |
| [docs/MODEL.md](docs/MODEL.md) | layers, ERD, every table and column, units, source mapping |
| [docs/METHODS.md](docs/METHODS.md) | the PR formulas (IEC, customer), the customer day, the old system's faults |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | running, configuring, migrating, recalculating, releasing |
| [docs/VALIDATION.md](docs/VALIDATION.md) | results against the old system and how to rerun |
| [docs/DATA_QUALITY.md](docs/DATA_QUALITY.md) | the `dq` views and the master-data findings |
| [docs/DECISIONS.md](docs/DECISIONS.md) | design decisions |
| [docs/ROADMAP.md](docs/ROADMAP.md) | what comes next |

## Status (2026-11-22)

- Running as Deployment `iotonix-neo/neo-model` (image `neo-model:0.2.0`, rad_argocd `a0ca8e9`), database `neo_model` on the NEO tenant Postgres
  (`10.0.0.180:20019`). 49 plants, 1,066 devices and 2,881 strings are synced. L1 holds the last 30 days from `NEO_LIVE` (from 2026-10-23); PR is computed for the 13
  PR-active plants.
- Validation (reference week 2026-11-05..12): every 5-minute inverter, plant and string field matches the old system 100 %. The daily values
  match 95–100 %, and the rest are the old system's faults (docs/VALIDATION.md).

## Quick start

```bash
PGHOST=10.0.0.180 PGPORT=20019 PGUSER=neo_owner PGPASSWORD=… PGDATABASE=neo_model sql/migrate.sh   # schema
kubectl -n iotonix-neo logs -f deploy/neo-model                                                     # service
```
```sql
SELECT * FROM rpt.pr_daily WHERE level = 'plant' AND day = current_date - 1 ORDER BY plant_code, method;
SELECT * FROM rpt.string_health_daily WHERE day = current_date - 1 AND ratio_to_median < 0.9;
```
