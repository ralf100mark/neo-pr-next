# NEO data model

PostgreSQL 18 + TimescaleDB 2.31. Database `neo_model` on the NEO tenant Postgres (`iotonix-neo/postgres-0`, `10.0.0.180:20019`).
The DDL is in `sql/migrations/` (numbered, applied once each by `sql/migrate.sh`). This document describes what the migrations create.

## 1. Principles

| Principle | How |
|---|---|
| **A physical model, not an API mirror** | Tables are named after physical things (plant, inverter, string, irradiance sensor, grid meter), not after Huawei endpoints. The vendor mapping lives in one place (§4). |
| **Clear layers** | `asset` (the plant) · `raw` (L0, as received) · `ts` (L1, measured) · `calc` (L2, derived) · `rpt` (L3, reporting) · `dq` (data quality) · `compat` (old names). Data flows one way: L0 → L1 → L2 → L3. |
| **Units in every name** | `_kw`, `_kwh`, `_w`, `_kvar`, `_v`, `_a`, `_w_m2`, `_kwh_m2`, `_c`, `_pct`, `_pct_per_c`, `_hz`, `_h`. Conversions happen once, at ingest (§4). |
| **Time** | `timestamptz` everywhere (stored in UTC). Local days are `Asia/Bangkok` (`asset.plant.timezone`). |
| **History of configuration** | Configuration rows carry `valid tstzrange`. A change closes the current row and opens a new one; exclusion constraints forbid overlaps. Current rows: `upper(valid) = 'infinity'`. |
| **Reproducible results** | Every L2 row names its `method`, `version` and `run_id` (`calc.run`). Methods live side by side; a new version is computed next to the old one. |
| **Idempotent** | L1 inserts are `ON CONFLICT DO NOTHING`; L2 is upserted. Any period can be re-run. |
| **Lineage** | `source` on asset rows, `run_id` on L1/L2 rows, `calc.run` with parameters and row counts. |

## 2. Overview

```mermaid
erDiagram
    PLANT ||--o{ DEVICE : has
    PLANT ||--|| PLANT_PR_PARAM : "customer params"
    PLANT ||--o{ PLANT_MONTH_FACTOR : "per month"
    PLANT ||--o{ PLANT_IMPORT_POWER : "per month"
    PLANT ||--o{ PVSYST_REFERENCE : "per month no"
    DEVICE ||--o{ PV_STRING : "inverter strings"
    DEVICE ||--o| INVERTER_PR_PARAM : "customer params"
    MODULE_TYPE ||--o{ PV_STRING : "built from"
    DEVICE ||--o{ INVERTER_AC : "L1"
    PV_STRING ||--o{ DC_STRING : "L1"
    DEVICE ||--o{ IRRADIANCE : "L1"
    DEVICE ||--o{ GRID_METER : "L1"
    PLANT ||--o{ PR_INTERVAL : "L2 plant level"
    DEVICE ||--o{ PR_INTERVAL : "L2 inverter level"
    PLANT ||--o{ PR_DAILY : "L2"
    DEVICE ||--o{ PR_DAILY : "L2 inverter"
    PV_STRING ||--o{ PR_DAILY : "L2 string"
    RUN ||--o{ PR_INTERVAL : produced
    RUN ||--o{ PR_DAILY : produced
```

```mermaid
flowchart LR
    HW[Huawei FusionSolar API] --> C[huawei-api consumer]
    C --> L0[(raw.api_response L0<br/>src.* master data)]
    CFG[(PR configuration<br/>pr_live_neodb)]
    subgraph svc [neo-model service, every 5 min]
        AS[asset_sync]
        L1M["l1_huawei<br/>l1.load_huawei()"]
        ORC{orchestrator<br/>meta.module + dirty windows}
        M1["pr_iec_61724_1<br/>interval / daily"]
        M2["pr_neo_customer<br/>interval / daily"]
    end
    CFG --> AS --> ASSET[(asset.*)]
    L0 --> L1M --> TS[(ts.* L1)]
    L1M -- marks dirty --> ORC
    ORC --> M1 --> PR[(calc.pr_interval<br/>calc.pr_daily L2)]
    ORC --> M2 --> PR
    ASSET -.-> M1
    ASSET -.-> M2
    TS --> TJ[Timescale jobs] --> RPT[(rpt.* L3)]
    PR --> API[(api_v1)]
    RPT --> API
    API --> PG[PostgREST neo-api :20021] --> APP[dashboard app]
```

The consumer also still writes Influx `NEO_LIVE` for pipeline A (docs/PIPELINE.md); `l1_influx` can load L1 from there as a fallback.

## 3. Tables and views

### asset: the physical plant (`002_asset.sql`)

| Table | Key | Content |
|---|---|---|
| `asset.plant` | `plant_id`, unique `code` (Huawei stationCode `NE=…`) | name, account, coordinates, timezone, `capacity_dc_kwp` (recorded), `cod_date`, `guarantee_years`, `g_ref_w_m2` (1000), `pr_active` |
| `asset.plant_pr_param` | `plant_id` | customer plant PR parameters: `string_cap_w` (P0 of the plant PR), `panels`, `globinc_pct`, `temp_coeff_pct_per_c` |
| `asset.device` | `device_id`; unique (`vendor`, `vendor_device_id`, `valid`) | `kind` (`inverter`, `irradiance_sensor`, `grid_meter`, `logger`), Huawei devId, ESN, name, model, `is_primary` (the EMI and grid meter PR uses), `valid` |
| `asset.inverter_pr_param` | `device_id` | customer inverter parameters (daily PR, CK/TCF): `string_cap_w`, `panels`, `module_wp`, `globinc_pct`, `temp_coeff_pct_per_c`, `g_ref_w_m2` |
| `asset.module_type` | `module_type_id` | `pmax_stc_w`, `gamma_pct_per_c`; `noct_c`, `area_m2`, manufacturer, model (not known today) |
| `asset.pv_string` | `string_id`; no overlap per (`inverter_id`, `string_no`, `valid`) | `string_no` (Huawei pv<N>), `mppt_no`, `module_type_id`, `modules_count`, `stc_capacity_w` (P0), `poa_factor` (GlobInc % / 100), `tilt_deg`, `azimuth_deg`, `enabled`, `configured` (false = observed in data only), `valid` |
| `asset.plant_month_factor` | (`plant_id`, `month`) | PVsyst / contract values: `temp_ref_c`, `degradation_pct`, `degrade_cap_pct`, `warranty_pct`, `availability_pct` |
| `asset.plant_import_power` | (`plant_id`, `month`) | monthly "import power zero" threshold `value_kw` (the xze filter of month M uses M−1), `method`, `static` (set by hand) |
| `asset.pvsyst_reference` | (`plant_id`, `month_no`) | PVsyst reference temperature per calendar month |
| view `asset.pv_string_current` | | current string rows |
| view `asset.inverter_capacity` | `inverter_id` | P0 (kW), panel-weighted `poa_factor`, capacity-weighted `gamma_pct_per_c`, string count, from the current configured and enabled strings |

### raw and src: L0 (`010_l0_src.sql`), written by the consumer

| Table | Key | Content |
|---|---|---|
| `raw.api_response` | (`raw_id`, `fetched_at`) | every API response unchanged: `account`, `endpoint`, `dev_type_id`, `collect_time`, `request` jsonb, `http_status`, `fail_code`, `success`, `response` jsonb (or `response_text`), `elapsed_ms`. Hypertable, 1-day chunks, compressed after 3 days, **retention 31 days** |
| `src.station` | (`source`, `station_code`, `account`) | stations as delivered (`doc` jsonb), `active`, `first_seen`, `last_seen` |
| `src.device` | (`source`, `dev_id`, `account`) | devices as delivered: `dev_type_id`, `station_code`, `name`, `esn`, `doc` jsonb, `active` |
| `src.sync_state` | (`source`, `sensor_id`, `kind`) | last value per sensor (was Mongo `talegur.lastSensorValueUpdate`) |
| `src.alarm_notification` | (`station_code`, `alarm_id`) | last notification (was Mongo `NotificationHistory`) |

### ts: L1 measured values (`003_raw_ts.sql`), hypertables with 7-day chunks

| Table | Key | Columns |
|---|---|---|
| `ts.inverter_ac` | (`device_id`, `time`) | `active_power_kw`, `reactive_power_kvar`, `power_factor`, `frequency_hz`, `u_ab_v`, `u_bc_v`, `u_ca_v`, `i_a_a`, `i_b_a`, `i_c_a`, `energy_day_kwh` (cumulative per local day), `energy_total_kwh`, `dc_power_kw`, `temperature_c`, `efficiency_pct`, `state`, `quality`, `run_id` |
| `ts.dc_string` | (`string_id`, `time`) | `voltage_v`, `current_a`, `power_w` (generated = V × I), `quality`, `run_id` |
| `ts.irradiance` | (`device_id`, `time`) | `poa_w_m2`, `poa_total_kwh_m2` (cumulative per local day), `ghi_w_m2`, `ghi_total_kwh_m2`, `module_temp_c`, `ambient_temp_c`, `wind_speed_m_s`, `wind_direction_deg`, `quality`, `run_id` |
| `ts.grid_meter` | (`device_id`, `time`) | `active_power_kw` (negative = export), `reactive_power_kvar`, `power_factor`, `frequency_hz`, `energy_forward_kwh` (cumulative, from the grid), `energy_reverse_kwh` (cumulative, to the grid), `quality`, `run_id` |
| `ts.station_real` (`017`) | (`plant_id`, `time`) | Huawei running counters every 5 min: `energy_day_kwh`, `energy_month_kwh`, `energy_total_kwh`, `grid_feed_day_kwh`, `consumption_day_kwh`, `income_day`, `income_total`, `health_state`, `raw_id` |
| `ts.station_period` (`017`) | (`period`, `plant_id`, `time`) | Huawei hourly / daily station KPIs (`period` = `hour` / `day`, `time` = period start): `inverter_energy_kwh`, `grid_feed_kwh`, `consumption_kwh`, `irradiation_kwh_m2`, `theoretical_kwh`, `pr_vendor_pct` (Huawei's PR), `equivalent_hours_h`, `installed_kwp`, `income`, `pv_yield_kwh`, `inverter_yield_kwh`, `self_use_kwh`, `self_provide_kwh`, `purchase_kwh`, `charge_kwh`, `discharge_kwh`, `co2_avoided_t`, `coal_saved_t`, `trees_planted`, `raw_id`; the latest delivery wins |
| `ts.device_day` (`017`) | (`device_id`, `day`) | Huawei daily inverter yield: `energy_kwh`, `equivalent_hours_h`, `installed_kwp`, `raw_id`; the latest delivery wins |

**Missing values:** L1 keeps a value the API delivers as null as NULL (L1 from L0). Rows loaded from Influx before 2026-11-22 11:39 UTC have
0 instead (the consumer's Influx writer stores null as 0.0).

### calc: L2 derived values (`004_calc.sql`, `005_calc_functions.sql`)

| Object | Content |
|---|---|
| `calc.run` | one row per run of a module or service step: `kind`, `method` (module), `version`, `params` (windows), start/end, `status`, `rows_written` |
| `calc.watermark` | L1 state: `l1_huawei` = L0 loaded up to this `fetched_at`; `ingest` = Influx loaded up to (fallback `l1_influx`) |
| `calc.pr_interval` | hypertable; PR per 5-minute interval at **inverter** level (`inverter_id` set) and **plant** level (`inverter_id` NULL), unique (`method`, `version`, `plant_id`, `inverter_id`, `time`). Common: `slot`, `interval_s`, `energy_kwh`, `p0_kw`, `h_meas_kwh_m2`, `h_poa_kwh_m2`, `yf_h`, `yr_h`, `pr`, `module_temp_c`. IEC: `c_k`, `pr_temp_corrected`. Customer: `grid_connected`, `power_limited`, `grid_import`, `meter_power_kw`, `ipz_threshold_kw`, `included`, `exclusion_reason`, `energy_xze_kwh`, `h_xze_kwh_m2`, `pr_xze`, `tmod_c`, `ck`, `tcf`, `pr_ck`, `pr_tcf` |
| `calc.pr_daily` | PR per day at **plant**, **inverter** and **string** level, unique (`method`, `version`, `level`, `plant_id`, `inverter_id`, `string_id`, `day`): `energy_kwh`, `p0_kw`, `h_poa_kwh_m2`, `pr`, `pr_temp_corrected`, `tmod_c`, `energy_xze_kwh`, `h_xze_kwh_m2`, `pr_xze`, `ck`, `tcf`, `pr_ck`, `pr_tcf`, `pr_epc_ck`, `pr_epc_tcf`, `daylight_h`, `ze_h`, `intervals` |
| module functions (`012`, `014`) | `calc.m_pr_iec_interval`, `calc.m_pr_customer_interval`, `calc.m_pr_iec_daily_v3`, `calc.m_pr_customer_daily` (and `calc.m_pr_iec_daily` = v2): signature `(from, to, version, run_id) → rows`; `calc.prepare_pr_inputs(from, to, asis)` builds their shared inputs |
| functions `calc.compute_intervals`, `calc.compute_daily` (`005`) | the v2 functions before the module split; kept for manual comparison, not used by the service |
| view `calc.string_pr_instant` | instantaneous DC PR per string sample, IEC and customer (`pr_asis_pv<N>`), computed on demand (not stored) |

Formulas and rules: [METHODS.md](METHODS.md).

### rpt: L3 reporting (`006_rpt.sql`)

| Object | Kind | Content |
|---|---|---|
| `rpt.inverter_energy_daily` | continuous aggregate | per local day and inverter: energy, peak power, samples |
| `rpt.string_daily` | continuous aggregate | per local day and string: approximate energy (5-min samples), max current, mean voltage |
| `rpt.irradiation_daily` | continuous aggregate | per local day and sensor: POA irradiation, peak irradiance, mean module temperature in daylight |
| `rpt.plant_power_5min` | continuous aggregate | per 5-minute slot and inverter: mean power, energy counter |
| `rpt.pr_daily` | view | `calc.pr_daily` with plant code/name, inverter name and string number |
| `rpt.string_health_daily` | view | daily DC string PR against the plant median (`ratio_to_median`) |

### l1: normalisers (`011`, `017`)

`l1.num(jsonb)` (JSON value → number), `l1.huawei_dev_real(from, to)` (device items of the getDevRealKpi responses),
`l1.load_huawei(from, to, run_id)` = `l1.load_huawei_devices` + `l1.load_huawei_station`: the module `l1_huawei`.

### meta: registry and bookkeeping (`012`, `013`)

| Object | Content |
|---|---|
| `meta.schema_migration` | applied migrations with checksum |
| `meta.module` | module registry: `name`, `version`, `layer`, `entrypoint`, `grain` (`sample`, `interval`, `day_local`, `day_utc`), `lookback`, `depends_on`, `inputs`, `outputs`, `params`, `enabled` |
| `meta.dirty_window` | windows a module has to (re)compute; `meta.mark_dependents(source, window, reason)`, `meta.backfill(module, from, to)` |
| `meta.api_published` | which version per method `api_v1` shows (iec_61724_1 v3, neo_customer v2) |

### dq: data quality (`008`, `015`)

`dq.unknown_sensor` (table, written by `l1_huawei`), views `dq.plant_capacity`, `dq.string_config`, `dq.silent_device`,
`dq.pr_prerequisites`, `dq.config_device_missing`. See [DATA_QUALITY.md](DATA_QUALITY.md).

### api_v1: the app contract (`013`, `015`, `016`, `017`)

Views served read-only by PostgREST (`http://10.0.0.180:20021/<view>`, role `neo_api`): `plant`, `device`, `pv_string`,
`plant_power_5min`, `inverter_power_5min`, `inverter_energy_daily`, `irradiation_daily`, `pr_daily`, `pr_5min`, `string_health_daily`,
`station_kpi`, `station_today`, `inverter_kpi_daily`, `dq_plant_capacity`, `dq_string_config`, `dq_pr_prerequisites`,
`dq_silent_device`, `dq_config_device_missing`, `pipeline_status`. PR views show the version in `meta.api_published`.

### compat: the old field names (`009_compat.sql`)

`compat.getdevrealkpi_1_pr`, `compat.getstationrealkpi_pr`, `compat.getioxdailykpi_plant`, `compat.getioxdailykpi_1` reproduce the Influx PR
fields of PR as-is 0.2 (incl. its daily-inverter scale, `*_asis_scale`) from the new model, for dashboard transition and comparisons.

## 4. Source mapping (Huawei northbound API, L0 → L1 by `l1.load_huawei`)

| Target | Source endpoint / field | Conversion |
|---|---|---|
| `asset.device.vendor_device_id` | `devId` (= Influx tag `sensorId`) | |
| time of the realtime tables | `params.collectTime` of the response (ms), truncated to the second | as the Influx writer did |
| `ts.inverter_ac` | `getDevRealKpi` devTypeId 1: `active_power`, `reactive_power`, `power_factor`, `elec_freq`, `ab_u`, `bc_u`, `ca_u`, `a_i`, `b_i`, `c_i`, `day_cap`, `total_cap`, `mppt_power`, `temperature`, `efficiency`, `inverter_state` | none (kW, kvar, kWh) |
| `ts.dc_string` | same: `pv<N>_u`, `pv<N>_i` → string `string_no = N` | none; an input without configuration becomes an observed string at ≥ 1 A |
| `ts.irradiance` | `getDevRealKpi` devTypeId 10: `radiant_line`, `radiant_total`, `horiz_radiant_line`, `horiz_radiant_total`, `pv_temperature`, `temperature`, `wind_speed`, `wind_direction` | `radiant_total` and `horiz_radiant_total` are MJ/m²: **/ 3.6** → kWh/m² |
| `ts.grid_meter` | `getDevRealKpi` devTypeId 17: `active_power`, `reactive_power`, `power_factor`, `grid_frequency`, `active_cap`, `reverse_active_cap` | `active_power` (W) and `reactive_power` (var): **/ 1000** |
| `ts.station_real` | `getStationRealKpi`: `day_power`, `month_power`, `total_power`, `day_on_grid_energy`, `day_use_energy`, `day_income`, `total_income`, `real_health_state` | none |
| `ts.station_period` | `getKpiStationHour` / `getKpiStationDay` (item `collectTime` = period start): see the column comments in `017` | none |
| `ts.device_day` | `getDevKpiDay`: `product_power`, `perpower_ratio`, `installed_capacity` | none |
| `asset.*` | PR configuration database (`pr_live_neodb`): `plant_information`, `plant_devices`, `inverter_information`, `inverter_configurations`, `plant_monthly_factor_configurations`, `plant_import_power_history`, `plant_pvsyst_reference` | `ic_glob_inc_pcnt` / 100 → `poa_factor`; `piph_value` (W) / 1000 → `value_kw` |

Not in L1 (yet): alarms (they stay in `neo_live_iox."GetAlarmListFlattened"`, written by the consumer); `getDevHistoryKpi` (disabled).
The fallback `l1_influx` maps the same fields from the Influx measurements `GetDevRealKpi_1/_10/_17`.

## 5. Sizes (13 PR plants; all 49 plants are ingested)

One week of L1 for the 13 PR plants is ~350 MB uncompressed, ~66 MB compressed (DC strings 286 → 44 MB). L2 for 30 days: ~2 M
interval rows. Compression: L1 after 7 days, L2 after 14 days, L0 after 3 days. L0: about 25 MB per day before compression, kept 31 days.
