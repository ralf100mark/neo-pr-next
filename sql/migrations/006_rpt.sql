-- 006 rpt (L3): aggregates and views for reporting and the dashboard app. Local days are Asia/Bangkok.

CREATE MATERIALIZED VIEW rpt.inverter_energy_daily WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 day', time, 'Asia/Bangkok') AS day_start,
       device_id,
       max(energy_day_kwh)  AS energy_kwh,                      -- day_cap is cumulative within the local day
       max(active_power_kw) AS peak_power_kw,
       count(*)             AS samples
FROM ts.inverter_ac GROUP BY 1, 2 WITH NO DATA;

CREATE MATERIALIZED VIEW rpt.string_daily WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 day', time, 'Asia/Bangkok') AS day_start,
       string_id,
       sum(power_w) * 5.0 / 60 / 1000 AS energy_approx_kwh,     -- assumes 5-min samples (exact value: calc.pr_daily)
       max(current_a)  AS max_current_a,
       avg(voltage_v)  AS avg_voltage_v,
       count(*)        AS samples
FROM ts.dc_string GROUP BY 1, 2 WITH NO DATA;

CREATE MATERIALIZED VIEW rpt.irradiation_daily WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '1 day', time, 'Asia/Bangkok') AS day_start,
       device_id,
       max(poa_total_kwh_m2) - min(poa_total_kwh_m2) AS h_poa_kwh_m2,
       max(poa_w_m2)      AS peak_poa_w_m2,
       avg(module_temp_c) FILTER (WHERE poa_w_m2 > 50) AS avg_module_temp_c,
       count(*)           AS samples
FROM ts.irradiance GROUP BY 1, 2 WITH NO DATA;

CREATE MATERIALIZED VIEW rpt.plant_power_5min WITH (timescaledb.continuous) AS
SELECT time_bucket(INTERVAL '5 min', a.time) AS slot,
       a.device_id,
       avg(a.active_power_kw) AS active_power_kw,
       max(a.energy_day_kwh)  AS energy_day_kwh
FROM ts.inverter_ac a GROUP BY 1, 2 WITH NO DATA;

-- Daily PR in readable form (local day as date, names instead of ids).
CREATE VIEW rpt.pr_daily AS
SELECT d.day, d.level, d.method, d.version, p.code AS plant_code, p.name AS plant_name, v.name AS inverter, s.string_no,
       d.energy_kwh, d.p0_kw, d.h_poa_kwh_m2, d.pr, d.pr_temp_corrected, d.pr_xze, d.pr_ck, d.pr_tcf, d.pr_epc_ck, d.pr_epc_tcf,
       d.tmod_c, d.ck, d.tcf, d.daylight_h, d.ze_h, d.intervals,
       d.plant_id, d.inverter_id, d.string_id
FROM calc.pr_daily d
JOIN asset.plant p ON p.plant_id = d.plant_id
LEFT JOIN asset.device v ON v.device_id = d.inverter_id
LEFT JOIN asset.pv_string s ON s.string_id = d.string_id;

-- String health per day: string PR against the median of its plant (weak strings stand out).
CREATE VIEW rpt.string_health_daily AS
WITH med AS (SELECT day, plant_id, version, percentile_cont(0.5) WITHIN GROUP (ORDER BY pr) AS median_pr
             FROM calc.pr_daily WHERE level = 'string' AND method = 'iec_61724_1' AND pr IS NOT NULL GROUP BY 1, 2, 3)
SELECT d.day, d.version, d.plant_code, d.inverter, d.string_no, d.pr AS pr_dc, m.median_pr AS plant_median_pr_dc,
       d.pr / nullif(m.median_pr, 0) AS ratio_to_median,
       d.energy_kwh AS energy_dc_kwh, d.p0_kw, d.plant_id, d.inverter_id, d.string_id
FROM rpt.pr_daily d
JOIN med m ON m.day = d.day AND m.plant_id = d.plant_id AND m.version = d.version
WHERE d.level = 'string' AND d.method = 'iec_61724_1' AND d.pr IS NOT NULL;
