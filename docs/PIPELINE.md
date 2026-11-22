# Data pipeline

How data moves from the Huawei FusionSolar API to the dashboard app. The document has three parts: the two pipelines (the legacy one and the
target), the stages of the target pipeline, and the **module contract**. Under that contract, a new calculation, a changed PR method, a
simulation or an extrapolation is a small module of its own, not a change to the pipeline.

> Status legend: ✅ running · 🟡 running as an interim solution · ⬜ designed, not built.

## 1. Two pipelines

```mermaid
flowchart LR
    HW[Huawei FusionSolar<br/>northbound API]
    C[huawei-api consumer v2<br/>one fetch, two sinks]
    HW --> C

    subgraph A [Pipeline A: legacy, frozen]
        direction LR
        IF[(Influx NEO_LIVE)]
        PRA[PR as-is 0.2<br/>pod pr]
        GF[Grafana / old app]
        IF --> PRA --> IF --> GF
    end

    subgraph B [Pipeline B: target]
        direction LR
        L0[(L0 raw<br/>JSONB, 31 days)]
        L1[(L1 measured)]
        L2[(L2 derived<br/>modules)]
        L3[(L3 serving<br/>marts + api_v1)]
        API[API service]
        APP[new dashboard app]
        L0 --> L1 --> L2 --> L3 --> API --> APP
    end

    C -- InfluxSink --> IF
    C -- PostgresSink --> L0
```

| | Pipeline A (legacy) | Pipeline B (target) |
|---|---|---|
| Purpose | keeps today's numbers and dashboards alive; reference for validation | the product: physical model, both PR methods, string level, simulations |
| Store | InfluxDB 1.8 `NEO_LIVE` (+ Mongo `NeoLive` as API cache) | PostgreSQL 18 + TimescaleDB 2.31, database `neo_model`; **no Mongo** |
| Calculation | PR as-is 0.2 (Django, row by row, writes back into the same measurements) | modules (§3), set-based SQL or Python, each writes only its own outputs |
| Consumers | Grafana, `iox.neo.app.v2` | API `api_v1` → the new dashboard app |
| Changes | **none** (frozen: fixes only if production breaks) | all new development |
| End | retired at the cut-over (§5, phase P6) | – |

Both pipelines are fed by **the same fetch**. The consumer calls each Huawei endpoint once and hands the response to every sink. There
are never two consumers on the same accounts (the API quota), and the two pipelines can be compared one to one.

## 2. Stages of pipeline B

| Stage | Layer / schema | Content | Written by | Kept |
|---|---|---|---|---|
| **S0 acquire** | – | calls the API on a schedule, handles login, quota and retries | `huawei-api` (consumer) | – |
| **S1 land** | **L0** `raw.api_response`; `src.*` | every API response **unchanged** as JSONB, with request, account, endpoint, fetch time and fail code; the master data as delivered (`src.station`, `src.device`), alarms (`src.alarm`), sync state (`src.sync_state`) | consumer, `PostgresSink` | **31 days** (retention policy), the cache that replaces Mongo; `src.*` current state + first/last seen |
| **S2 normalise** | **L1** `ts.*`, `asset.*` | typed, unit-converted measurements per physical object (inverter AC, DC string, irradiance, grid meter, station/day KPIs); the asset model with validity periods | module `l1_huawei`, module `asset_sync` | forever (compressed after 7 days) |
| **S3 derive** | **L2** `calc.*` | everything computed: PR (IEC, customer), string PR, availability, losses, expected power, simulations, gap estimates; every row has `module`, `version`, `run_id` (and `scenario_id` where relevant) | one **module** per calculation (§3) | forever; old versions until deleted on purpose |
| **S4 serve** | **L3** `rpt.*`, `api_v1.*` | continuous aggregates and marts per use case; `api_v1` views are the **contract** with the app (stable names, versioned schema) | Timescale jobs, migrations | derived, rebuildable |
| **S5 present** | – | API service (read-only role) → dashboard app | API, app | – |

Rules that hold for every stage:

1. **Data only flows downward.** A stage reads only the layer below it (and `asset`). Nothing writes back into a lower layer.
2. **Measured is never overwritten by derived.** L1 holds what was measured. Corrections, gap fills and extrapolations are L2 outputs,
   flagged as `estimated`, and never mixed into L1.
3. **Every layer can be rebuilt from the one below.** L1 can be rebuilt from L0 within its 31 days; L2 and L3 can be rebuilt from L1 at
   any time.
4. **Idempotent.** Re-running any module for any window gives the same rows (upsert on the natural key).
5. **Lineage.** Every row can be traced back: L1 → `run_id` → the L0 rows (`raw_id`); L2 → module, version, run, parameters.

### 2.1 Mongo replaced

| Mongo today (consumer v2) | Role | Pipeline B |
|---|---|---|
| `GetDevRealKpi_1/_10/_17`, `GetStationRealKpi`, `GetStationHourKpi(RAW)` | API response cache (~136 k docs/day, pruned to 30 days by hand) | `raw.api_response` (JSONB, retention 31 days, automatic) |
| `GetKpiStationDay`, `GetDevKpiDay_1` (kept forever on prod) | daily KPIs | L1 `ts.station_day`, `ts.device_day` (forever); raw 31 days |
| `Stations`, `GetDevList` | master data that the consumer **reads back** to know what to fetch | `src.station`, `src.device`; the consumer's getters read from Postgres |
| `talegur.lastSensorValueUpdate` | last update per sensor | `src.sync_state` |
| `GetAlarmList` (raw), `NotificationHistory`, consolidated alarm list | alarm intake and notification state | raw → L0; notification state → `src.alarm_notification`. **The alarms themselves are already in Postgres:** the consumer keeps `"GetAlarmListFlattened"` in `neo_live_iox` (insert new, set `clearedTime`), and the app reads it (`alarms-pg`); this stays as it is until the app redesign moves it into `src.alarm` |
| `Escalations`, `user_groups`, `email_log` (app data, not written by v2) | app features | move with the app redesign (owner: the new app), not part of the consumer change |

The consumer's Mongo access sits in a few places: `database/mongo/getters.py`, one block per fetcher in `controller/data_fetchers/*`, and
`helpers/mongodb_client.py`. These are replaced by a repository interface with a Postgres implementation.

### 2.2 Schedule (consumer, Asia/Bangkok)

| Job | When | Endpoint(s) | L1 target |
|---|---|---|---|
| `realtime` | every 5 min, 05:00–18:55, plus 19:00 | `getDevRealKpi` (inverter 1, EMI 10, meter 17), `getStationRealKpi` | `ts.inverter_ac`, `ts.dc_string`, `ts.irradiance`, `ts.grid_meter`, `ts.station_real` |
| `hour` | :37, 07–21 h | `getKpiStationHour` | `ts.station_hour` |
| `daily` | 19:30 | `getDevKpiDay`, `getKpiStationDay` | `ts.device_day`, `ts.station_day` |
| `alarm` | every 30 min | `getAlarmList` | `neo_live_iox."GetAlarmListFlattened"` (today) → `src.alarm` (with the app redesign) |
| `sync_stations` / `sync_devices` | 19:45 / 19:47 | `stations`, `getDevList` | `src.station`, `src.device` → `asset_sync` |
| `auth` | 3×/h | `login` | – |
| `history` | **disabled** (it deletes real-time Influx data) | `getDevHistoryKpi` | – |

## 3. Modules: the unit of change

A **module** is the smallest unit of processing. Everything from L1 onwards is a module: normalising, asset sync, every PR method,
availability, loss analysis, the physical expected-power model, simulations and extrapolations.

### 3.1 Contract

Every module declares the following and must keep to it:

| Item | Meaning |
|---|---|
| `name`, `version` | e.g. `pr_neo_customer` `v2`. A new version is computed **next to** the old one, never over it |
| `layer` | L1, L2 or L3 |
| `inputs` | the relations it reads (L1 tables, `asset.*`, outputs of other modules) |
| `outputs` | the relations it writes; **only this module writes them** |
| `grain` | the time unit it works in (sample, 5 min, day, month) |
| `params` | parameters as JSON (stored per run) |
| `lookback` | how far back new or late input can change its output |
| `compute(window, params, run_id)` | computes the window `[t0, t1)` and upserts; a SQL function or a Python class, same contract |

Registered in `meta.module` (name, version, layer, inputs, outputs, enabled), run history in `calc.run`.

### 3.2 Orchestration: dirty windows

```mermaid
flowchart LR
    L0[(L0 new rows)] --> N[l1_huawei]
    N -- marks dirty --> D[(meta.dirty_window)]
    D --> O{orchestrator<br/>neo-model service}
    O -->|dependency order| M1[pr_iec_61724_1]
    O --> M2[pr_neo_customer]
    O --> M3[string_pr]
    M1 --> M4[availability ...]
    O -. scenario run .-> S[simulation]
```

1. A module that writes rows for `[t0, t1)` marks that window **dirty** for every module that reads its output (`meta.dirty_window`).
2. Each cycle (every 5 min), the orchestrator runs the enabled modules in dependency order on their dirty windows. It extends each window
   by the module's `lookback`, rounds it to the module's grain, and clears the window after a successful run.
3. **A new module or a new version** gets its whole history marked dirty once. It backfills in the background and does not touch the
   other modules.
4. A failed module stops only its own downstream modules. The rest of the pipeline continues; the window stays dirty and is retried.

### 3.3 What a change costs

| Change | What you do | What does not change |
|---|---|---|
| Fix or change a PR method | new version of that one module (`pr_neo_customer` v3); it backfills next to v2; compare; switch the `api_v1` view to v3 | L0, L1, every other module, the app |
| New KPI (availability, losses, soiling) | new module, own output table, register it | everything else |
| **Simulation** (what-if: other modules, tilt, cleaning interval) | module `simulation` with `calc.scenario` (id, params); outputs keyed by `scenario_id`; baseline = measured | measured data and the official PR (scenario 0) |
| **Extrapolation / gap fill / forecast** | module writes `calc.estimate_*` with `quality = 'estimated'` and the method; reporting chooses measured, or measured + estimated | L1 stays measured only |
| A second vendor | new L1 normaliser `l1_<vendor>` from its own L0 endpoint rows | L2 modules (they read physical L1 tables, not vendor data) |
| New app page | new `rpt` mart or `api_v1` view | calculations |

### 3.4 Modules (status)

| Module | Layer | Status |
|---|---|---|
| `asset_sync` (PR configuration → `asset.*`, SCD history) | L1 | ✅ (inside `neo_model.py`) |
| `l1_influx` (Influx `NEO_LIVE` → `ts.*`) | L1 | 🟡 interim, replaced by `l1_huawei` |
| `l1_huawei` (L0 JSONB → `ts.*`) | L1 | ⬜ |
| `pr_iec_61724_1` (interval + daily, inverter/plant/string) | L2 | ✅ (in `calc.compute_intervals` / `compute_daily`, to be split per module) |
| `pr_neo_customer` (xze, CK/TCF, daily, EPC) | L2 | ✅ validated (same functions) |
| `string_pr_instant` | L2 | ✅ view |
| `availability`, `energy_loss`, `expected_power`, `simulation`, `estimate` | L2 | ⬜ |
| `rpt.*` aggregates, `api_v1` | L3 | ✅ `rpt` / ⬜ `api_v1` |

## 4. L0 design (sketch for P1)

```sql
CREATE TABLE raw.api_response (                 -- hypertable on fetched_at, 1-day chunks
    raw_id       bigint GENERATED ALWAYS AS IDENTITY,
    fetched_at   timestamptz NOT NULL,           -- when we received it
    source       text NOT NULL DEFAULT 'huawei',
    account      text NOT NULL,                  -- Huawei user (quota owner)
    endpoint     text NOT NULL,                  -- e.g. getDevRealKpi
    dev_type_id  smallint,                       -- 1, 10, 17 … where the endpoint has one
    collect_time timestamptz,                    -- the time the data is for (day KPIs), if any
    request      jsonb NOT NULL,                 -- parameters sent (devIds, stationCodes, collectTime)
    http_status  smallint,
    fail_code    integer,                        -- Huawei failCode (0 = ok, 407 = quota …)
    response     jsonb,                          -- the body, unchanged
    job          text,                           -- scheduler job (realtime, hour, daily …)
    PRIMARY KEY (raw_id, fetched_at)
);
SELECT add_retention_policy('raw.api_response', INTERVAL '31 days');
SELECT add_compression_policy('raw.api_response', INTERVAL '3 days');
```

Migration `003` already created a minimal `raw.api_response` (no writer yet). `010` brings it to this shape and adds the retention policy.

One row per API call (not per device): what Huawei sent, exactly, in one place. The size is about 300 calls per day per account and
endpoint; the 30 days in Mongo `NeoLive` are about 2 GB, and compressed JSONB is in the same range. `l1_huawei` reads new rows by `raw_id`.

## 5. Migration plan

| Phase | Step | Done when |
|---|---|---|
| **P1** | Consumer: sink interface; `PostgresSink` writes L0 + `src.*` **in addition** (Influx and Mongo unchanged); migration `010_l0_src.sql` | every API call is in `raw.api_response`; counts per job = consumer log |
| **P2** | Module `l1_huawei` (L0 → L1), run next to `l1_influx` into a test database | one week of L1 identical (counts and values) from both paths; then switch `neo_model` to `l1_huawei` |
| **P3** | Consumer reads master data and state from `src.*`; notification state to `src.alarm_notification`; **Mongo writes off**; drop `NeoLive`/`talegurLive` after 2 weeks | consumer runs without a Mongo connection |
| **P4** | Module framework: `meta.module`, `meta.dirty_window`, orchestrator; split the PR functions into modules | adding a module needs no change to the service |
| **P5** | `api_v1` + API service (read-only role); the new app reads only `api_v1` | the app pages of `NEO_APP_API_INVENTORY.md` are covered |
| **P6** | Cut-over: Influx sink off, PR as-is pod and Grafana retired | customer sign-off of the PR numbers from pipeline B |

Pipeline A keeps running unchanged until P6. Until then, every phase can be rolled back by switching a sink or a module off.
