# Roadmap

Target of the redesign: ~2026-12-01. Status: v2 runs (docs/OPERATIONS.md), `neo_customer` validated (docs/VALIDATION.md).

## Next

| # | Item | Notes |
|---|---|---|
| R1 | **API for the new dashboard app** (replaces Grafana and the endpoints in `/data/neo/NEO_APP_API_INVENTORY.md`) | read-only, over `rpt.*` and `calc.*`; a role `neo_api` with SELECT on `rpt`, `calc`, `asset`, `dq` |
| R2 | **L0: the Huawei consumer writes `raw.api_response` directly**, and the model's ingest reads L0 instead of Influx | removes Influx and the Mongo cache from the path; keeps the API responses for re-processing |
| R3 | Station and daily KPIs into L1 (`GetStationRealKpi`, `GetStationHourKpi`, `GetKpiStationDay`, `GetDevKpiDay_1`) and alarms | needed for the app's overview pages and for checking our energy against Huawei's |
| R4 | Master-data fixes at the source (docs/DATA_QUALITY.md Q1–Q6, Q9) | owner: NEOVision; the asset sync takes them over with history |
| R5 | Own asset maintenance | today the PR configuration (`pr_live_neodb`) is the master; later the model's `asset` schema becomes the master and the PR configuration UI writes to it |
| R6 | History before 2026-10-23 | ingest from `NEO_RESTORE` (exact prod copy since 2024-04), then compute L2 for it |

## Later

| # | Item | Notes |
|---|---|---|
| R7 | Physical data: tilt/azimuth per string, module datasheets (NOCT, area), string → MPPT, inverter AC rating | DATA_QUALITY Q10 |
| R8 | Transposition (GHI → POA) for strings whose orientation differs from the sensor; expected power model (irradiance + temperature); clipping/curtailment detection | needs R7 |
| R9 | IEC 61724-1 extras: documented-unavailability exclusions, annual-temperature-equivalent PR, availability KPIs, energy-loss breakdown (the old `energy_loss` curtailment estimate as its own method) | |
| R10 | String diagnostics: persistent under-performers (`rpt.string_health_daily`), alerts | |
| R11 | Simulations (the user's "physical model": what-if, degradation trends) | on top of R7/R8 |
| R12 | Monitoring of the service (metrics, alert when the watermark lags) | |
| R13 | External check of the IEC numbers (PVsyst, FusionSolar PR) | VALIDATION.md §3 |
| R14 | Retire `compat.*` once the new app no longer needs the old field names | |
| R15 | CI: run `sql/migrate.sh` and `tests/validate.sql` on a throw-away database per commit | |
