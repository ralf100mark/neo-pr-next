# Data quality

The model does not fix master data. It shows what is wrong in the `dq` schema and in this list, so that the people who own the configuration
(NEOVision / the PR configuration in `pr_live_neodb`) can correct it at the source. The next asset sync then picks the correction up, with history.

## 1. Views

| View | Question | Use |
|---|---|---|
| `dq.plant_capacity` | Does the recorded kWp agree with the string configuration and the measured peak? | peak > configured kWp is a red flag |
| `dq.string_config` | Which strings are configured but dead, carry current but are not configured, or are disabled? (last 7 days) | `finding` ≠ `ok` |
| `dq.silent_device` | Which devices delivered data before but nothing in the last day? | outages, comms |
| `dq.pr_prerequisites` | Why does a plant get no customer PR? (primary EMI, primary meter, month factor, last month's IPZ, plant parameters) | before switching a plant to `pr_active` |
| table `dq.unknown_sensor` | Which sensorIds arrive in the data but have no device? | missing device configuration |

```sql
SELECT * FROM dq.plant_capacity WHERE pr_active ORDER BY code;
SELECT finding, count(*) FROM dq.string_config GROUP BY 1;
SELECT * FROM dq.string_config WHERE finding <> 'ok' ORDER BY plant_code, inverter, string_no;
SELECT * FROM dq.pr_prerequisites WHERE pr_active AND NOT (month_factor_now AND ipz_previous_month AND plant_pr_param);
SELECT measurement, count(*) FROM dq.unknown_sensor GROUP BY 1;
```

## 2. Findings (2026-11-22)

| # | Finding | Effect | Owner action |
|---|---|---|---|
| Q1 | **CCET (NE=64821350):** recorded 3,232 kWp, the string configuration says 10,343 kWp, the measured peak is 7.6 MW | the recorded capacity is plainly wrong; any yield per kWp based on it is ~3× too high | confirm the real DC capacity, fix `plant_information` |
| Q2 | 2 plants (NE=72294728, NE=78142560) have neither capacity nor coordinates | no specific yield, no irradiance model possible | complete `plant_information` |
| Q3 | 59 configured strings without (or with only noise) current | dead strings (fuses, connectors) **or** wrong string numbering: they lower the inverter P0 used by PR if they really exist but are mis-numbered, and they are real losses if they are dead | site check; renumber in `inverter_configurations` |
| Q4 | 23 string inputs carry real current (≥ 1 A) but are not configured | their energy counts in the inverter PR, their capacity does not (PR too high); no string PR | add to `inverter_configurations` |
| Q5 | 35 strings disabled (UBIS) | excluded from P0 on purpose | none (check it is still intended) |
| Q6 | SO-TGPRO has 18 inverters, 17 configured | one inverter without PR | configure it |
| Q7 | 87 sensorIds in `NEO_LIVE` without a device in the PR configuration | they belong to plants outside the PR setup (36 of the 49 plants are not `pr_active`); ingested only when known | add devices when those plants join PR |
| Q8 | EMI counters (`radiant_total`) occasionally go backwards | the old system's daily PR becomes absurd (e.g. −76); the model clamps the interval to 0 | check the sensors on the affected days (docs/VALIDATION.md) |
| Q9 | Monthly factors cover 12 to 361 months per plant | no customer PR in months without a factor | complete `plant_monthly_factor_configurations` ahead of time |
| Q10 | Missing physical master data: tilt/azimuth per string, module datasheet (NOCT, area), string → MPPT mapping, inverter AC rating | no transposition, no expected-power model, no clipping detection | collect (docs/ROADMAP.md) |
| Q11 | neo-dev's Influx data ends on 2026-11-13 12:00 UTC (its copy from prod stopped) | the old PR on neo-dev has had no input since | none: PR as-is now runs in `iotonix-neo` on `NEO_LIVE` |

| Q12 | **NE=49785735:** the customer plant parameter `pi_plant_string_cap` is 551 kWp, but its strings add up to 210 kWp (recorded 210 kWp, peak 148 kW) | the customer **plant** PR of this plant is ~2.6× too low (≈ 0.24 instead of ≈ 0.63); the inverter PR is not affected | fix `plant_information.pi_plant_string_cap` |
| Q13 | NE=64821350 and NE=78142560 have no import-power-zero value for last month | the xze threshold falls back to 0 kW (as in the old code): intervals with any meter power ≥ 0 are excluded | check `plant_import_power_history` |
| Q14 | 2 grid meters went silent (NE=51128942 since 2026-11-06, NE=49768173 since 2026-11-13), both on plants outside PR | no meter data | site/comms check |

Numbers Q3–Q5 are from 2026-11-20 midday (215 inverters of the 13 PR plants); `dq.string_config` gives the current state. On 2026-11-22 (last 7 days)
it shows for the PR plants: 1,599 ok, 59 configured but no current, 24 current but not configured, 35 disabled. For the 36 plants outside
PR, most strings are "current but not configured" (3,244), because the PR configuration has no strings for them.
