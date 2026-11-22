-- 009 compat: the old field names of PR as-is 0.2 (Influx), computed from the new model. For the transition of the dashboards
-- and for comparisons with neo-dev. Exclusions are shown as 0 (as the old fields); pr_asis is 0 without irradiation.

CREATE VIEW compat.getdevrealkpi_1_pr AS                         -- GetDevRealKpi_1 PR fields per inverter sample
SELECT x.time, d.vendor_device_id::text AS "sensorId", p.code AS "stationCode", d.name AS "deviceName", x.version,
       x.energy_kwh AS energy_asis, x.energy_xze_kwh AS energy_xze, coalesce(x.pr, 0) AS pr_asis_inv, x.pr_xze AS pr_xze_inv,
       x.ck AS ck_inv, x.tcf AS tcf_inv, x.pr_ck AS pr_actual_ck, x.pr_tcf AS pr_actual_tcf,
       CASE WHEN x.grid_connected THEN 1 ELSE 0 END AS all_grid_connected
FROM calc.pr_interval x
JOIN asset.device d ON d.device_id = x.inverter_id
JOIN asset.plant p ON p.plant_id = x.plant_id
WHERE x.method = 'neo_customer';

CREATE VIEW compat.getstationrealkpi_pr AS                       -- GetStationRealKpi PR fields per plant slot
SELECT x.time, p.code AS "stationCode", x.version, x.energy_kwh AS energy_asis, x.energy_xze_kwh AS energy_xze,
       x.pr AS pr_asis, x.pr_xze, x.h_poa_kwh_m2 AS radiant_asis_globinc, x.h_xze_kwh_m2 AS radiant_xze_globinc,
       x.h_meas_kwh_m2 * 3.6 AS radiant_asis, CASE WHEN x.included THEN x.h_meas_kwh_m2 * 3.6 ELSE 0 END AS radiant_xze,
       CASE WHEN x.included THEN 1 ELSE 0 END AS criteria_filtered_2, CASE WHEN x.power_limited THEN 1 ELSE 0 END AS power_limit,
       CASE WHEN x.grid_connected THEN 1 ELSE 0 END AS all_grid_connected
FROM calc.pr_interval x JOIN asset.plant p ON p.plant_id = x.plant_id
WHERE x.method = 'neo_customer' AND x.inverter_id IS NULL;

CREATE VIEW compat.getioxdailykpi_plant AS                      -- GetIoxDailyKpi_Plant
SELECT d.day, p.code AS "stationCode", d.version, d.energy_kwh AS energy_asis, d.energy_xze_kwh AS energy_xze,
       d.pr AS pr_asis, d.pr_xze, d.tmod_c AS tmod, d.ck, d.tcf, d.pr_ck AS pr_actual_ck, d.pr_tcf AS pr_actual_tcf,
       d.pr_epc_ck, d.pr_epc_tcf, d.daylight_h AS daylight_hour, d.ze_h AS ze_hour,
       d.h_poa_kwh_m2 AS radiant_asis_globinc, d.h_xze_kwh_m2 AS radiant_xze_globinc
FROM calc.pr_daily d JOIN asset.plant p ON p.plant_id = d.plant_id
WHERE d.method = 'neo_customer' AND d.level = 'plant';

CREATE VIEW compat.getioxdailykpi_1 AS                          -- GetIoxDailyKpi_1 (inverter): correct scale and the as-is scale
SELECT d.day, dv.vendor_device_id::text AS "sensorId", p.code AS "stationCode", d.version,
       d.energy_kwh AS energy_asis, d.energy_xze_kwh AS energy_xze, d.h_poa_kwh_m2 * 3.6 AS radiant_asis,
       d.pr AS pr_asis, d.pr_xze, d.tcf AS tcf_inv, d.ck AS ck_inv, d.pr_ck AS pr_actual_ck, d.pr_tcf AS pr_actual_tcf,
       d.pr_epc_ck, d.pr_epc_tcf,
       d.pr / 100 AS pr_asis_asis_scale, d.pr_xze / 100 AS pr_xze_asis_scale,                    -- PR as-is 0.2 forgets / 100
       d.pr_ck / 100 AS pr_actual_ck_asis_scale, d.pr_tcf / 100 AS pr_actual_tcf_asis_scale,
       d.pr_epc_ck / 100 AS pr_epc_ck_asis_scale, d.pr_epc_tcf / 100 AS pr_epc_tcf_asis_scale
FROM calc.pr_daily d JOIN asset.device dv ON dv.device_id = d.inverter_id JOIN asset.plant p ON p.plant_id = d.plant_id
WHERE d.method = 'neo_customer' AND d.level = 'inverter';
