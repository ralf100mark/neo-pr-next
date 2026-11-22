-- 013 api_v1: the contract with the dashboard app (docs/PIPELINE.md §2, S4). The app reads ONLY this schema, through the
-- read-only API service (PostgREST, role neo_api). Names here are stable; calculations behind them may change.
-- Which calculation version the app sees is chosen in meta.api_published (one row per method), not in the app.

CREATE TABLE meta.api_published (
    method  text PRIMARY KEY,                               -- iec_61724_1, neo_customer
    version text NOT NULL,                                  -- the version api_v1 shows
    since   timestamptz NOT NULL DEFAULT now(),
    note    text
);
INSERT INTO meta.api_published (method, version, note) VALUES
    ('iec_61724_1', 'v2', 'first published version'),
    ('neo_customer', 'v2', 'validated against PR as-is 0.2 (docs/VALIDATION.md)');

CREATE SCHEMA api_v1;
COMMENT ON SCHEMA api_v1 IS 'Read API for the dashboard app, version 1 (stable names; served by PostgREST)';

CREATE VIEW api_v1.plant AS
SELECT p.code AS plant_code, p.name, p.account, p.latitude, p.longitude, p.timezone, p.capacity_dc_kwp, p.cod_date,
       p.guarantee_years, p.pr_active, pp.string_cap_w / 1000.0 AS pr_capacity_kwp
FROM asset.plant p LEFT JOIN asset.plant_pr_param pp USING (plant_id);
COMMENT ON VIEW api_v1.plant IS 'Plants. pr_capacity_kwp = the P0 of the customer plant PR';

CREATE VIEW api_v1.device AS
SELECT p.code AS plant_code, d.device_id, d.kind::text AS kind, d.name, d.vendor, d.vendor_device_id, d.serial_no, d.model,
       d.is_primary
FROM asset.device d JOIN asset.plant p USING (plant_id)
WHERE upper(d.valid) = 'infinity';
COMMENT ON VIEW api_v1.device IS 'Current devices (inverter, irradiance_sensor, grid_meter, logger); vendor_device_id = Huawei devId';

CREATE VIEW api_v1.pv_string AS
SELECT p.code AS plant_code, v.device_id AS inverter_id, v.name AS inverter, s.string_id, s.string_no, s.mppt_no,
       s.modules_count, s.stc_capacity_w, s.poa_factor, s.configured, s.enabled
FROM asset.pv_string s JOIN asset.device v ON v.device_id = s.inverter_id JOIN asset.plant p ON p.plant_id = v.plant_id
WHERE upper(s.valid) = 'infinity';
COMMENT ON VIEW api_v1.pv_string IS 'Current PV strings; configured=false: observed in the data but not in the configuration';

CREATE VIEW api_v1.inverter_power_5min AS
SELECT p.code AS plant_code, r.device_id AS inverter_id, d.name AS inverter, r.slot, r.active_power_kw, r.energy_day_kwh
FROM rpt.plant_power_5min r JOIN asset.device d USING (device_id) JOIN asset.plant p ON p.plant_id = d.plant_id;
COMMENT ON VIEW api_v1.inverter_power_5min IS 'Mean AC power per inverter and 5-min slot; always filter by plant_code and slot';

CREATE VIEW api_v1.plant_power_5min AS
SELECT p.code AS plant_code, r.slot, sum(r.active_power_kw) AS active_power_kw, count(*) AS inverters
FROM rpt.plant_power_5min r JOIN asset.device d USING (device_id) JOIN asset.plant p ON p.plant_id = d.plant_id
GROUP BY 1, 2;
COMMENT ON VIEW api_v1.plant_power_5min IS 'Plant AC power per 5-min slot (sum of inverters); always filter by plant_code and slot';

CREATE VIEW api_v1.inverter_energy_daily AS
SELECT p.code AS plant_code, r.device_id AS inverter_id, d.name AS inverter, (r.day_start AT TIME ZONE 'Asia/Bangkok')::date AS day,
       r.energy_kwh, r.peak_power_kw, r.samples
FROM rpt.inverter_energy_daily r JOIN asset.device d USING (device_id) JOIN asset.plant p ON p.plant_id = d.plant_id;
COMMENT ON VIEW api_v1.inverter_energy_daily IS 'Energy per inverter and local day (from the inverter day counter)';

CREATE VIEW api_v1.irradiation_daily AS
SELECT p.code AS plant_code, r.device_id AS sensor_id, d.name AS sensor, d.is_primary,
       (r.day_start AT TIME ZONE 'Asia/Bangkok')::date AS day, r.h_poa_kwh_m2, r.peak_poa_w_m2, r.avg_module_temp_c
FROM rpt.irradiation_daily r JOIN asset.device d USING (device_id) JOIN asset.plant p ON p.plant_id = d.plant_id;
COMMENT ON VIEW api_v1.irradiation_daily IS 'Plane-of-array irradiation per sensor and local day';

CREATE VIEW api_v1.pr_daily AS
SELECT r.day, r.level, r.method, r.version, r.plant_code, r.plant_name, r.inverter_id, r.inverter, r.string_id, r.string_no,
       r.energy_kwh, r.p0_kw, r.h_poa_kwh_m2, r.pr, r.pr_temp_corrected, r.pr_xze, r.pr_ck, r.pr_tcf, r.pr_epc_ck, r.pr_epc_tcf,
       r.tmod_c, r.ck, r.tcf, r.daylight_h, r.ze_h, r.intervals
FROM rpt.pr_daily r JOIN meta.api_published a ON a.method = r.method AND a.version = r.version;
COMMENT ON VIEW api_v1.pr_daily IS 'Daily PR, published version per method. level = plant | inverter | string; customer days are UTC 00:00-12:10';

CREATE VIEW api_v1.pr_5min AS
SELECT x.slot, x.time, x.method, x.version, p.code AS plant_code, x.inverter_id, d.name AS inverter,
       x.energy_kwh, x.h_poa_kwh_m2, x.pr, x.pr_temp_corrected, x.included, x.exclusion_reason, x.pr_xze, x.ck, x.tcf, x.pr_ck, x.pr_tcf
FROM calc.pr_interval x
JOIN meta.api_published a ON a.method = x.method AND a.version = x.version
JOIN asset.plant p ON p.plant_id = x.plant_id
LEFT JOIN asset.device d ON d.device_id = x.inverter_id;
COMMENT ON VIEW api_v1.pr_5min IS 'PR per interval (inverter_id NULL = plant level), published version; always filter by plant_code and slot';

CREATE VIEW api_v1.string_health_daily AS
SELECT h.day, h.plant_code, h.inverter_id, h.inverter, h.string_id, h.string_no, h.pr_dc, h.plant_median_pr_dc, h.ratio_to_median,
       h.energy_dc_kwh, h.p0_kw
FROM rpt.string_health_daily h JOIN meta.api_published a ON a.method = 'iec_61724_1' AND a.version = h.version;
COMMENT ON VIEW api_v1.string_health_daily IS 'Daily DC string PR against the plant median (ratio < 0.9: look at it)';

CREATE VIEW api_v1.dq_plant_capacity AS SELECT * FROM dq.plant_capacity;
CREATE VIEW api_v1.dq_string_config AS SELECT plant_code, inverter, string_no, configured, enabled, stc_capacity_w, max_current_a, samples, finding FROM dq.string_config;
CREATE VIEW api_v1.dq_pr_prerequisites AS SELECT * FROM dq.pr_prerequisites;
CREATE VIEW api_v1.dq_silent_device AS SELECT * FROM dq.silent_device;

CREATE VIEW api_v1.pipeline_status AS
SELECT w.job, w.until_ts AS loaded_until, now() - w.until_ts AS lag,
       (SELECT max(finished_at) FROM calc.run r WHERE r.status = 'ok') AS last_ok_run,
       (SELECT count(*) FROM calc.run r WHERE r.status = 'failed' AND r.started_at > now() - INTERVAL '1 day') AS failed_runs_24h,
       (SELECT count(*) FROM meta.dirty_window) AS dirty_windows
FROM calc.watermark w;
COMMENT ON VIEW api_v1.pipeline_status IS 'Freshness of the pipeline (for a status badge in the app)';

-- The API role (PostgREST connects as neo_api_auth and switches to neo_api; created outside the migrations, docs/OPERATIONS.md).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'neo_api') THEN
    GRANT USAGE ON SCHEMA api_v1 TO neo_api;
    GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO neo_api;
  END IF;
END $$;
