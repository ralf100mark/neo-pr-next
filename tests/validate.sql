-- Validation of the neo_customer method against PR as-is 0.2 (neo-dev), field by field.
-- Needs schema ref (tools/load_reference.py) and calc results of :version for the same period. Run:
--   psql -v version=v2 -f tests/validate.sql
-- Output per field: compared values, share equal within the tolerance (abs), share within 1 % (relative).
-- Reference conventions: excluded/undefined values are 0 in the old fields; daily inverter PR of the old system is 100x too
-- small (missing / 100, see docs/METHODS.md); the customer day is UTC 00:00-12:10 (07:00-19:10 Bangkok).
\set ON_ERROR_STOP on
\pset footer off

CREATE TEMP TABLE v_inv AS
SELECT r.*, x.energy_kwh, x.energy_xze_kwh, coalesce(x.pr, 0) AS pr, x.pr_xze AS n_pr_xze, x.ck, x.tcf, x.pr_ck, x.pr_tcf
FROM ref.inverter_interval r
JOIN asset.device d ON d.vendor_device_id = r.sensor_id AND d.kind = 'inverter'
JOIN calc.pr_interval x ON x.inverter_id = d.device_id AND x.time = r.time AND x.method = 'neo_customer' AND x.version = :'version';

CREATE TEMP TABLE v_plant AS
SELECT r.*, x.energy_kwh, x.energy_xze_kwh, x.pr, x.pr_xze AS n_pr_xze, x.included, x.h_poa_kwh_m2, x.h_xze_kwh_m2
FROM ref.plant_interval r
JOIN asset.plant p ON p.code = r.station_code
JOIN calc.pr_interval x ON x.plant_id = p.plant_id AND x.inverter_id IS NULL AND x.slot = time_bucket(INTERVAL '5 min', r.time)
                       AND x.method = 'neo_customer' AND x.version = :'version';

CREATE TEMP TABLE v_pday AS
SELECT r.*, x.energy_kwh, x.energy_xze_kwh, x.pr AS n_pr, x.pr_xze AS n_pr_xze, x.tmod_c, x.ck AS n_ck, x.tcf AS n_tcf,
       x.pr_ck AS n_pr_ck, x.pr_tcf AS n_pr_tcf, x.pr_epc_ck AS n_epc_ck, x.pr_epc_tcf AS n_epc_tcf, x.daylight_h, x.ze_h,
       x.h_poa_kwh_m2, x.h_xze_kwh_m2
FROM ref.plant_daily r
JOIN asset.plant p ON p.code = r.station_code
JOIN calc.pr_daily x ON x.plant_id = p.plant_id AND x.level = 'plant' AND x.day = (r.time AT TIME ZONE 'UTC')::date
                    AND x.method = 'neo_customer' AND x.version = :'version';

CREATE TEMP TABLE v_iday AS
SELECT r.*, x.energy_kwh, x.energy_xze_kwh, x.pr / 100 AS n_pr, x.pr_xze / 100 AS n_pr_xze, x.ck AS n_ck, x.tcf AS n_tcf,
       x.pr_ck / 100 AS n_pr_ck, x.pr_tcf / 100 AS n_pr_tcf, x.pr_epc_ck / 100 AS n_epc_ck, x.pr_epc_tcf / 100 AS n_epc_tcf
FROM ref.inverter_daily r
JOIN asset.device d ON d.vendor_device_id = r.sensor_id AND d.kind = 'inverter'
JOIN calc.pr_daily x ON x.inverter_id = d.device_id AND x.level = 'inverter' AND x.day = (r.time AT TIME ZONE 'UTC')::date
                    AND x.method = 'neo_customer' AND x.version = :'version';

CREATE TEMP TABLE v_str AS
SELECT r.pr_asis AS ref, s.pr_customer AS new
FROM ref.string_interval r
JOIN asset.device d ON d.vendor_device_id = r.sensor_id AND d.kind = 'inverter'
JOIN calc.string_pr_instant s ON s.inverter_id = d.device_id AND s.string_no = r.string_no AND s.time = r.time
WHERE r.pr_asis <> 0;

CREATE TEMP TABLE result (level text, field text, compared bigint, equal_pct numeric, within_1pct numeric, tolerance text);
CREATE FUNCTION pg_temp.chk(level text, field text, ref double precision[], new double precision[], tol double precision)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO result
  SELECT level, field, count(*),
         round(100.0 * count(*) FILTER (WHERE abs(n - r) <= tol) / nullif(count(*), 0), 1),
         round(100.0 * count(*) FILTER (WHERE abs(n - r) <= greatest(tol, 0.01 * abs(r))) / nullif(count(*), 0), 1),
         '±' || tol
  FROM unnest(ref, new) AS u(r, n) WHERE r IS NOT NULL AND n IS NOT NULL $$;

SELECT pg_temp.chk('inverter 5-min', 'energy_asis',   array_agg(energy_asis),   array_agg(energy_kwh), 0.001) FROM v_inv;
SELECT pg_temp.chk('inverter 5-min', 'energy_xze',    array_agg(energy_xze),    array_agg(energy_xze_kwh), 0.001) FROM v_inv;
SELECT pg_temp.chk('inverter 5-min', 'pr_asis_inv',   array_agg(pr_asis_inv),   array_agg(pr), 0.0005) FROM v_inv;
SELECT pg_temp.chk('inverter 5-min', 'pr_xze_inv',    array_agg(pr_xze_inv),    array_agg(n_pr_xze), 0.0005) FROM v_inv;
SELECT pg_temp.chk('inverter 5-min', 'ck_inv',        array_agg(ck_inv),        array_agg(ck), 0.0005) FROM v_inv;
SELECT pg_temp.chk('inverter 5-min', 'tcf_inv',       array_agg(tcf_inv),       array_agg(tcf), 0.0005) FROM v_inv;
SELECT pg_temp.chk('inverter 5-min', 'pr_actual_ck',  array_agg(pr_actual_ck),  array_agg(pr_ck), 0.0005) FROM v_inv;
SELECT pg_temp.chk('inverter 5-min', 'pr_actual_tcf', array_agg(pr_actual_tcf), array_agg(pr_tcf), 0.0005) FROM v_inv;
SELECT pg_temp.chk('plant 5-min', 'energy_asis',  array_agg(energy_asis), array_agg(energy_kwh), 0.01) FROM v_plant;
SELECT pg_temp.chk('plant 5-min', 'energy_xze',   array_agg(energy_xze),  array_agg(energy_xze_kwh), 0.01) FROM v_plant;
SELECT pg_temp.chk('plant 5-min', 'pr_asis',      array_agg(pr_asis),     array_agg(pr), 0.0005) FROM v_plant;
SELECT pg_temp.chk('plant 5-min', 'pr_xze',       array_agg(pr_xze),      array_agg(n_pr_xze), 0.0005) FROM v_plant;
SELECT pg_temp.chk('plant 5-min', 'criteria_filtered_2', array_agg(criteria_filtered_2), array_agg(CASE WHEN included THEN 1.0 ELSE 0 END), 0) FROM v_plant;
SELECT pg_temp.chk('plant 5-min', 'radiant_asis_globinc', array_agg(radiant_asis_globinc), array_agg(h_poa_kwh_m2), 0.0005) FROM v_plant;
SELECT pg_temp.chk('plant daily', 'energy_asis',   array_agg(energy_asis),   array_agg(energy_kwh), 0.1) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'pr_asis',       array_agg(pr_asis),       array_agg(n_pr), 0.0005) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'pr_xze',        array_agg(pr_xze),        array_agg(n_pr_xze), 0.0005) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'tmod',          array_agg(tmod),          array_agg(tmod_c), 0.01) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'ck',            array_agg(ck),            array_agg(n_ck), 0.0005) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'tcf',           array_agg(tcf),           array_agg(n_tcf), 0.0005) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'pr_actual_ck',  array_agg(pr_actual_ck),  array_agg(n_pr_ck), 0.0005) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'pr_actual_tcf', array_agg(pr_actual_tcf), array_agg(n_pr_tcf), 0.0005) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'pr_epc_ck',     array_agg(pr_epc_ck),     array_agg(n_epc_ck), 0.0005) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'pr_epc_tcf',    array_agg(pr_epc_tcf),    array_agg(n_epc_tcf), 0.0005) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'daylight_hour', array_agg(daylight_hour), array_agg(daylight_h), 0.01) FROM v_pday;
SELECT pg_temp.chk('plant daily', 'ze_hour',       array_agg(ze_hour),       array_agg(ze_h), 0.01) FROM v_pday;
SELECT pg_temp.chk('inverter daily', 'energy_asis',   array_agg(energy_asis),   array_agg(energy_kwh), 0.01) FROM v_iday;
SELECT pg_temp.chk('inverter daily', 'pr_asis (as-is scale)',  array_agg(pr_asis),  array_agg(n_pr), 0.0001) FROM v_iday;
SELECT pg_temp.chk('inverter daily', 'pr_xze (as-is scale)',   array_agg(pr_xze),   array_agg(n_pr_xze), 0.0001) FROM v_iday;
SELECT pg_temp.chk('inverter daily', 'ck_inv',        array_agg(ck_inv),        array_agg(n_ck), 0.0005) FROM v_iday;
SELECT pg_temp.chk('inverter daily', 'tcf_inv',       array_agg(tcf_inv),       array_agg(n_tcf), 0.0005) FROM v_iday;
SELECT pg_temp.chk('inverter daily', 'pr_actual_ck (as-is scale)', array_agg(pr_actual_ck), array_agg(n_pr_ck), 0.0001) FROM v_iday;
SELECT pg_temp.chk('inverter daily', 'pr_epc_ck (as-is scale)',    array_agg(pr_epc_ck),    array_agg(n_epc_ck), 0.0001) FROM v_iday;
SELECT pg_temp.chk('string 5-min', 'pr_asis_pv<N>', array_agg(ref), array_agg(new), 0.0005) FROM v_str;

SELECT * FROM result;
