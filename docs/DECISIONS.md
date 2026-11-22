# Decisions

| # | Date | Decision | Why |
|---|---|---|---|
| M1 | 2026-11-22 | **PostgreSQL + TimescaleDB** is the platform of the redesign; InfluxDB and Grafana are retired step by step | one database for assets, time series and results (joins, constraints, SQL for PR); the old Influx crashed daily under the PR load |
| M2 | 2026-11-22 | **Layers L0 raw → L1 measured → L2 derived → L3 reporting**, one schema each (`raw`, `ts`, `calc`, `rpt`), plus `asset`, `dq`, `compat`, `meta` | clear lineage; any layer can be rebuilt from the one below |
| M3 | 2026-11-22 | **Physical asset model down to the string** (plant → device → string, module type), not API-shaped tables | string-level PR is wanted; vendors and API versions change, the plant does not |
| M4 | 2026-11-22 | **Both PR families side by side**: `iec_61724_1` and `neo_customer`, each row with `method` + `version` | the customer's contractual numbers must continue unchanged, the standard is needed for comparison and the future |
| M5 | 2026-11-22 | `neo_customer` reproduces PR as-is 0.2 **exactly**, incl. the UTC-12:10 customer day; only plainly invalid arithmetic is not copied (negative irradiation, the missing ÷100 is reproduced in `compat` only) | the numbers must match what the customer has seen; validated field by field (VALIDATION.md) |
| M6 | 2026-11-22 | The customer formulas were **derived from the code**, not asked | user decision; the code is the specification of record |
| M7 | 2026-11-22 | Units in column names, conversions once at ingest (MJ → kWh, W → kW) | the old code had implicit /12, ×1000, /3.6 and % vs fraction mix-ups |
| M8 | 2026-11-22 | Real intervals (next sample ≤ 30 min), 5-minute slots only as the join key | the Huawei timestamps drift by seconds; gaps must not be filled with fixed /12 |
| M9 | 2026-11-22 | Configuration history with `tstzrange valid` + exclusion constraints, closed and opened by the asset sync | PR of a past day must use that day's configuration |
| M10 | 2026-11-22 | Compute PR **in SQL functions** in the database, called by a small service | set-based, testable with psql, no row-by-row pandas; a backfill of 30 days takes seconds per day |
| M11 | 2026-11-22 | Numbered SQL migrations with checksums (`sql/migrate.sh`), no ORM | the schema is the product; plain SQL is reviewable |
| M12 | 2026-11-22 | Inputs for now: Influx `NEO_LIVE` (fed by the Huawei consumer v2) and the PR configuration `pr_live_neodb` | they exist and are live; L0 written by the consumer directly comes later (ROADMAP) |
| M13 | 2026-11-22 | Compression: L1 after 7 days, L2 after 14, L0 after 3 | late data and recalculation hit recent chunks; ~66 MB per week for 13 plants |
| M14 | 2026-11-22 | Huawei only, no other vendors for now; the vendor is a column (`device.vendor`) so others can be added | scope |
| M15 | 2026-11-22 | The model's service runs in `iotonix-neo` with a NetworkPolicy (namespace + DNS only) | it must never reach the customer servers |
| M16 | 2026-11-22 | The old PR code (`iox.neoclean.performance_ratio.management`) is not changed and gets no new repository; it runs as-is (image 0.2) next to the model until the redesign replaces it | user decision |
| M17 | 2026-11-22 | **Two pipelines during the transition:** A (Influx + PR as-is + Grafana, frozen) and B (Postgres layers + modules + API), both fed by the same consumer fetch | no second consumer on the quota-limited accounts; one-to-one comparison until the cut-over |
| M18 | 2026-11-22 | **Mongo is eliminated:** the API cache becomes `raw.api_response` (JSONB, 31-day retention), master data and state go to `src.*` | one database less; the cache is the L0 of pipeline B, and retention is automatic instead of a manual prune |
| M19 | 2026-11-22 | **Everything from L1 up is a module** with a fixed contract (inputs, outputs, version, grain, lookback, idempotent compute); orchestration by dirty windows | a new method, simulation or extrapolation changes one module, not the pipeline |
| M20 | 2026-11-22 | The app reads only `api_v1` (versioned views), never the calculation tables | calculations can change without breaking the app |
