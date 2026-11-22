# Validation

The `neo_customer` method must give the customer the same numbers as the old system (PR as-is 0.2). It was checked field by field against
the results neo-dev (10.0.88.11) wrote into its Influx: copied to our Influx `PR_RESTORE` (2026-10-17..2026-11-13). The model was fed the
same raw data (also from `PR_RESTORE`), so both sides see the same inputs.

## 1. How to rerun

```bash
# 1. a test database with the migrations (docs/OPERATIONS.md §4), e.g. neo_model_test
# 2. the service once, on PR_RESTORE, for the reference week (local dates):
PG_DB=neo_model_test PG_ASSET_DB=pr_neodb INFLUX_DB=PR_RESTORE BACKFILL_FROM=2026-11-05 BACKFILL_TO=2026-11-12 ONCE=1 \
  PG_HOST=10.0.0.180 PG_PORT=20019 PG_USER=neo_owner PG_PASSWORD=… INFLUX_HOST=10.0.0.180 INFLUX_PORT=20018 INFLUX_USER=… INFLUX_PASSWORD=… \
  python service/neo_model.py
# 3. neo-dev's results into schema ref (same env):
python tools/load_reference.py 2026-11-05 2026-11-12
# 4. compare
psql … -d neo_model_test -v version=v2 -f tests/validate.sql
```

`pr_neodb` is neo-dev's configuration as of the dump (2026-11-22), the one its results were computed with.
Tolerances: ±0.0005 for ratios, ±0.001 kWh (inverter interval), ±0.01 kWh (plant interval), ±0.1 kWh (plant day). The old fields write 0
for excluded or undefined values; the comparison takes them as they are.

## 2. Results (version v2, reference week 2026-11-05..2026-11-12, 13 plants)

| Level | Field | Compared | Equal within tolerance |
|---|---|---:|---:|
| inverter 5-min | `energy_asis`, `energy_xze`, `pr_asis_inv`, `pr_xze_inv`, `ck_inv`, `tcf_inv`, `pr_actual_ck`, `pr_actual_tcf` | 266,973 each | **100 %** |
| plant 5-min | `energy_asis`, `energy_xze`, `pr_asis`, `pr_xze`, `criteria_filtered_2`, `radiant_asis_globinc` | 16,017 each | **100 %** |
| string 5-min | `pr_asis_pv<N>` | 1,585,286 | **100 %** |
| plant daily | `energy_asis`, `daylight_hour`, `ze_hour`, `ck`, `tcf` | all | **100 %** |
| plant daily | `pr_xze` / `pr_asis` | all | 97.9 % / 94.8 % |
| plant daily | `pr_epc_ck`, `pr_epc_tcf` | all | 99 % within 1 % |
| inverter daily | `pr_xze`, `ck_inv`, `tcf_inv`, `pr_actual_ck` (old scale, B1) | all | **100 %** |
| inverter daily | `pr_asis` (old scale) | all | 95.4 % |

**The remaining daily differences are faults of the old system, not of the model:** they sit on 5 plant-days where the EMI irradiation
counter went backwards (negative deltas, PR as-is computes a daily PR of e.g. −76; the model clamps to 0, METHODS.md B2). Every
5-minute value, which the daily values are built from, matches.

How the match was reached (the rules that mattered): the interval starts at the sample (energy = next − this); the customer day is UTC
00:00–12:10; the import-power-zero threshold is in W in the source (÷1000); the meter `active_power` is W (÷1000); the daily inverter PR of the
old system lacks ÷100 (B1).

## 3. IEC method

`iec_61724_1` has no reference implementation here. Checks done: Y_f, Y_r and PR by hand for single intervals; the daily PR equals Σ Y_f / Σ Y_r;
string-level PR medians are plausible (PTTOR-SL-TR on 2026-11-10: median 0.832, p10/p90 0.781/0.875). An external check (e.g. against PVsyst
or the Huawei FusionSolar PR) is on the roadmap.
