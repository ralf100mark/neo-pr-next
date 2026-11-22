# Roadmap

Target of the redesign: ~2026-12-01. Status 2026-11-22: pipeline B runs end to end (consumer → L0 → L1 → modules → `api_v1` → API),
phases P1–P5 done (docs/PIPELINE.md §5). Pipeline A runs unchanged next to it.

## Next

| # | Item | Notes |
|---|---|---|
| R1 | **Cut-over (P6)**: the new app on `api_v1`, then Influx sink off, PR as-is pod and Grafana retired | needs the new app and the customer's sign-off of the PR numbers |
| R2 | The new dashboard app reads `api_v1`; extend `api_v1` page by page (`NEO_APP_API_INVENTORY.md`) | not covered yet: users/auth (IOX user service), alarms (`neo_live_iox`), Strapi content, write operations |
| R3 | Alarms into the model (`src.alarm` from L0 `getAlarmList`, an `api_v1.alarm` view) | today the consumer writes `neo_live_iox."GetAlarmListFlattened"`, which the old app reads |
| R4 | Master-data fixes at the source (docs/DATA_QUALITY.md Q1–Q6, Q9, Q12, Q15, Q16) | owner: NEOVision; the asset sync takes them over with history |
| R5 | Drop the Mongo databases `NeoLive` / `talegurLive` (not written since 2026-11-22 11:28) and the Mongo code in the consumer | after 2026-12-06 (two weeks of pipeline B) |
| R6 | History before 2026-10-23 | from `NEO_RESTORE` (prod copy since 2024-04), OPERATIONS.md §5 |
| R7 | Backups for `neo_model` (and the whole tenant) | tenant `ait` has `services/iotonix-tenant/backup`; NEO has none yet |
| R8 | Own asset maintenance | today the PR configuration (`pr_live_neodb`) is the master; later `asset` becomes the master and the configuration UI writes to it |

## Later

| # | Item | Notes |
|---|---|---|
| R9 | Physical data: tilt/azimuth per string, module datasheets (NOCT, area), string → MPPT, inverter AC rating | DATA_QUALITY Q10 |
| R10 | Modules: `expected_power` (irradiance + temperature model), transposition for strings whose orientation differs from the sensor, clipping/curtailment detection | needs R9 |
| R11 | Modules: availability, energy-loss breakdown (incl. the old curtailment estimate), IEC exclusions for documented unavailability, annual-temperature-equivalent PR | each a module (PIPELINE.md §3.3) |
| R12 | Module `simulation` (scenarios: other modules, tilt, cleaning interval) and `estimate` (gap fill, forecast; flagged as estimated) | PIPELINE.md §3.3 |
| R13 | A correction module for the Influx-era L1 history (missing values stored as 0, Q17) | IEC history only |
| R14 | String diagnostics: persistent under-performers (`api_v1.string_health_daily`), alerts | |
| R15 | Monitoring and alerting on `api_v1.pipeline_status` (lag, failed runs) | |
| R16 | External check of the IEC numbers (PVsyst, Huawei's own PR in `ts.station_period.pr_vendor_pct`) | VALIDATION.md §3 |
| R17 | Retire `compat.*` and `calc.compute_intervals/compute_daily` once nothing uses them | |
| R18 | CI: run `sql/migrate.sh`, `tests/validate.sql` and `tests/compare_l1_sources.sql` on a throw-away database per commit | |
| R19 | A second vendor: its own L0 endpoint rows and an `l1_<vendor>` module; L2 modules stay unchanged | |
