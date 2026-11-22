# PR methods

Two families are computed side by side, each with a `method` name and a `version` (today `v2`) on every L2 row:

| `method` | What | Levels |
|---|---|---|
| `iec_61724_1` | performance ratio as IEC 61724-1 defines it, plus the temperature-corrected PR | interval (inverter, plant), day (plant, inverter, string) |
| `neo_customer` | NEOVision's method, as implemented by PR as-is 0.2 (`iox.neoclean.performance_ratio.management`); reproduced exactly, bugs included where they are part of the numbers the customer sees (§4) | interval (inverter, plant), day (plant, inverter); instantaneous string PR as a view |

Implementation: `sql/migrations/005_calc_functions.sql` (`calc.compute_intervals`, `calc.compute_daily`, view `calc.string_pr_instant`).
The analysis of the old code is in `/data/neo/PR_FORMULAS.md` (outside this repository).

## 1. Common building blocks

### Interval
An interval **starts at a sample** and ends at the next sample of the same device on the same local day:

- inverter energy `energy_kwh = energy_day_kwh(next) − energy_day_kwh(this)`, never below 0;
- POA irradiation `h_meas_kwh_m2 = poa_total_kwh_m2(next) − poa_total_kwh_m2(this)` of the plant's **primary** irradiance sensor, never below 0;
- grid meter forward energy `energy_forward_kwh(next) − energy_forward_kwh(this)` of the **primary** meter;
- no next sample within 30 minutes → energy and irradiation 0 (a gap, not an extrapolation).

Samples are matched to the plant's 5-minute **slot** `time_bucket('5 min', time)`. The Huawei timestamps vary by seconds; the slot is the join key
between inverter, sensor and meter, the sample time is the row key.

### Capacity P0 and POA factor
`asset.inverter_capacity` (view): P0 = Σ `stc_capacity_w` of the inverter's **current, configured, enabled** strings, in kW;
`poa_factor` = panel-weighted mean of the strings' `poa_factor` (customer GlobInc % / 100, 0.985–0.9997); γ = capacity-weighted mean.
G_ref = `asset.plant.g_ref_w_m2` (1000 W/m²).

### Which devices
Only **primary** inverters, the primary irradiance sensor and the primary grid meter of plants with `pr_active` count (the PR configuration's
selection, `plant_devices`). The other devices are still ingested to L1.

## 2. `iec_61724_1`

| Quantity | Formula | Column |
|---|---|---|
| Final yield | Y_f = E_AC / P0 | `yf_h` |
| Reference yield | Y_r = H_POA / G_ref (H measured in the plane of array, **no** GlobInc factor) | `yr_h` |
| PR | Y_f / Y_r, NULL when H = 0 | `pr` |
| Temperature factor | C_k = 1 + γ · (T_mod − 25 °C) / 100 (γ in %/°C, negative) | `c_k` |
| Temperature-corrected PR | Y_f / (Y_r · C_k) | `pr_temp_corrected` |
| Daily PR (plant, inverter) | Σ Y_f / Σ Y_r over the intervals with Y_r > 0 of the **local** day (00:00–24:00 Bangkok) | `calc.pr_daily.pr` |
| Daily temperature-corrected PR | Σ Y_f / Σ (Y_r · C_k) | `pr_temp_corrected` |
| Daily string PR (DC) | (Σ P_dc · Δt / P0_string) / (H_POA,day / G_ref); Δt = time to the next sample, at most 30 min; DC side, so inverter losses are not included | `pr_daily` level `string` |

The plant level sums energy and P0 over the primary inverters of a slot; γ is P0-weighted.
Not yet implemented from the standard: availability-based exclusions (IEC lets you exclude documented unavailability symmetrically from E and H),
the annual-temperature-equivalent PR (T_ref = the annual mean instead of 25 °C), and the uncertainty classes.

## 3. `neo_customer`

### 3.1 Interval (inverter): `GetDevRealKpi_1` fields of PR as-is

| Quantity | Formula | Column (old field) |
|---|---|---|
| H with GlobInc | H_g = H_meas · poa_factor | `h_poa_kwh_m2` |
| PR | (E / P0) / (H_g / G_ref); 0 when H_g = 0 | `pr` (`pr_asis_inv`) |
| Filter "xze" (exclude zero export) | `included` = all primary inverters in state **512** (grid connected) in this slot **and** in the previous and next slot with data (≤ 30 min away) **and** the meter's forward energy of the interval ≤ 0 (no import) **and** meter `active_power_kw` < the import-power-zero threshold of the **previous** month (`asset.plant_import_power`, 0 if none) | `included`, `exclusion_reason` = `not_grid_connected` / `grid_import` / `zero_export_limit` (`criteria_filtered_2`) |
| Filtered values | E_xze = E, H_xze = H_meas (without GlobInc) and PR_xze = PR if included, else 0 | `energy_xze_kwh`, `h_xze_kwh_m2`, `pr_xze` (`energy_xze`, `pr_xze_inv`) |
| T_mod | the sensor's module temperature if included and H_meas > 0, else 0 | `tmod_c` |
| CK | 1 + γ · (T_mod − T_ref) / 100; 0 when T_mod = 0. γ = `inverter_pr_param.temp_coeff_pct_per_c`, T_ref = `plant_month_factor.temp_ref_c` of the month (UTC) | `ck` (`ck_inv`) |
| TCF | (1 + γ · (T_ref − 25) / 100) / (1 + γ · (T_mod − 25) / 100); 0 when T_mod = 0 | `tcf` (`tcf_inv`) |
| PR actual CK / TCF | PR_xze / CK, PR_xze · TCF (0 if the divisor or PR_xze is 0) | `pr_ck`, `pr_tcf` (`pr_actual_ck`, `pr_actual_tcf`) |

No customer row is written for a month without a month factor (T_ref), as in PR as-is.
`power_limited` (any inverter in state 513) is recorded but does not exclude (as in the old code).

### 3.2 Interval (plant): `GetStationRealKpi` fields

Same filter; E = Σ of the primary inverters; P0 = `plant_pr_param.string_cap_w` (the plant's own value, not the sum of the strings);
H_g = H_meas · `plant_pr_param.globinc_pct` / 100. Here `h_xze_kwh_m2` **includes** the GlobInc factor (`radiant_xze_globinc`).
Columns `pr` (`pr_asis`), `pr_xze`, `energy_xze_kwh`, `included` (`criteria_filtered_2`), `h_poa_kwh_m2` (`radiant_asis_globinc`).

### 3.3 Day

**The customer day is UTC 00:00–12:10** (07:00–19:10 Bangkok): the old end-of-day job runs at 19:10 Bangkok and takes the UTC date of that
moment. Production before 07:00 local is not counted. Reproduced exactly; the IEC method uses the full local day.

| Quantity | Plant (`GetIoxDailyKpi_Plant`) | Inverter (`GetIoxDailyKpi_1`) |
|---|---|---|
| PR | (ΣE / P0) / (ΣH_g / G_ref) | (ΣE / P0_inv) / (ΣH_meas · f / G_ref), P0_inv = `inverter_pr_param.string_cap_w`, f = `globinc_pct` / 100 |
| PR_xze | (ΣE_xze / P0) / (ΣH_xze,g / G_ref) | (ΣE_xze / P0_inv) / (ΣH_xze · f / G_ref) |
| T_mod | Σ(T_mod · H_xze,g) / ΣH_xze,g | the plant's daily T_mod |
| CK, TCF | as 3.1 with the daily T_mod and the plant γ | as 3.1 with the inverter γ |
| PR actual CK / TCF | PR_xze / CK, PR_xze · TCF | same |
| PR EPC | PR_actual / (degrade_cap_pct · availability_pct / 10 000) of the month | same |
| Daylight hours | count(intervals with H_g > 0) / 12 | – |
| Zero-export hours | daylight − count(intervals with H_xze,g > 0) / 12 | – |

### 3.4 String, instantaneous (`pr_asis_pv<N>`)
View `calc.string_pr_instant`: `pr_customer` = (P_dc / P0_string) / (G_POA / G_ref · poa_factor) per string sample, with G_POA the primary
sensor's first sample in the same 5-minute slot. `pr_iec` is the same without the factor. Not stored; filter by time and plant.

## 4. Known faults of PR as-is 0.2 and how the model treats them

| # | Fault in the old system | Effect | Model |
|---|---|---|---|
| B1 | Daily inverter PR: `ii_glob_inc_pcnt` (e.g. 99.5) is used **without / 100** | daily inverter PR, PR_xze, PR actual and EPC are **100× too small** | `calc.pr_daily` is correct; `compat.getioxdailykpi_1` divides by 100 (`*_asis_scale`) to reproduce the old numbers |
| B2 | Negative irradiation deltas (EMI counter reset or glitch) are not clamped | absurd daily PR on single days (e.g. −76) | clamped to 0 (`greatest(…, 0)`); the 5 affected reference days differ on purpose |
| B3 | Customer day = UTC 00:00–12:10 | production before 07:00 Bangkok is lost | reproduced in `neo_customer` (it is the customer's number); the IEC method uses the local day |
| B4 | `pr_asis_total_pv`: no division by the STC capacity, × 1000 | not a ratio | not reproduced |
| B5 | Fixed 5-minute assumption (/12, "previous/next 5 min") | wrong at gaps and late data | real intervals (next sample ≤ 30 min); slots only as the join key |
| B6 | Temperature correction per interval, then averaged | intervals weighted equally, whatever the irradiance | customer: reproduced; IEC: weighted by Y_r (sums) |

## 5. Adding or changing a method

1. Never change the numbers of an existing `(method, version)` silently. New logic → a new `version` (env `CALC_VERSION`) or a new `method`.
2. Write the change as a new migration (`sql/migrations/NNN_*.sql`, `CREATE OR REPLACE FUNCTION`), document it here, and validate it
   (docs/VALIDATION.md).
3. Recompute history by calling the functions for the period (docs/OPERATIONS.md §5). Old versions stay until deleted on purpose.
