-- P2 check (docs/PIPELINE.md §5): L1 as the module l1_huawei derives it from L0 vs. L1 as it was loaded from Influx (ts.*).
-- Field by field for every device sample of the L0 window. Rule: equal (±1e-6), or L0 null where Influx has 0 (the consumer's
-- Influx writer stores null as 0.0; L1 from L0 keeps NULL on purpose).
--   psql -v from="'2026-11-22 11:28'" -v to="'2026-11-22 12:00'" -f tests/compare_l1_sources.sql
\set ON_ERROR_STOP on
\pset footer off

CREATE TEMP TABLE c_l0 AS
SELECT x.dev_type_id, x.sample_time AS time, dv.device_id, x.m
FROM l1.huawei_dev_real(:from::timestamptz, :to::timestamptz) x
JOIN asset.device dv ON dv.vendor = 'huawei' AND dv.vendor_device_id = x.dev_id AND upper(dv.valid) = 'infinity';

CREATE TEMP TABLE c_pairs (tbl text, field text, l0 double precision, ts double precision, in_l0 boolean, in_ts boolean);

INSERT INTO c_pairs
SELECT 'inverter_ac', f.field, f.l0, f.ts, c.device_id IS NOT NULL, a.device_id IS NOT NULL
FROM (SELECT * FROM c_l0 WHERE dev_type_id = 1) c
FULL JOIN (SELECT a.* FROM ts.inverter_ac a WHERE a.time >= (SELECT min(time) FROM c_l0) AND a.time <= (SELECT max(time) FROM c_l0)
             AND a.device_id IN (SELECT device_id FROM c_l0 WHERE dev_type_id = 1)) a USING (device_id, time)
CROSS JOIN LATERAL (VALUES
   ('active_power_kw', l1.num(c.m->'active_power'), a.active_power_kw), ('energy_day_kwh', l1.num(c.m->'day_cap'), a.energy_day_kwh),
   ('energy_total_kwh', l1.num(c.m->'total_cap'), a.energy_total_kwh), ('state', l1.num(c.m->'inverter_state'), a.state::double precision),
   ('u_ab_v', l1.num(c.m->'ab_u'), a.u_ab_v), ('temperature_c', l1.num(c.m->'temperature'), a.temperature_c),
   ('dc_power_kw', l1.num(c.m->'mppt_power'), a.dc_power_kw)) f(field, l0, ts);

INSERT INTO c_pairs
SELECT 'irradiance', f.field, f.l0, f.ts, c.device_id IS NOT NULL, a.device_id IS NOT NULL
FROM (SELECT * FROM c_l0 WHERE dev_type_id = 10) c
FULL JOIN (SELECT a.* FROM ts.irradiance a WHERE a.time >= (SELECT min(time) FROM c_l0) AND a.time <= (SELECT max(time) FROM c_l0)
             AND a.device_id IN (SELECT device_id FROM c_l0 WHERE dev_type_id = 10)) a USING (device_id, time)
CROSS JOIN LATERAL (VALUES
   ('poa_w_m2', l1.num(c.m->'radiant_line'), a.poa_w_m2), ('poa_total_kwh_m2', l1.num(c.m->'radiant_total') / 3.6, a.poa_total_kwh_m2),
   ('module_temp_c', l1.num(c.m->'pv_temperature'), a.module_temp_c)) f(field, l0, ts);

INSERT INTO c_pairs
SELECT 'grid_meter', f.field, f.l0, f.ts, c.device_id IS NOT NULL, a.device_id IS NOT NULL
FROM (SELECT * FROM c_l0 WHERE dev_type_id = 17) c
FULL JOIN (SELECT a.* FROM ts.grid_meter a WHERE a.time >= (SELECT min(time) FROM c_l0) AND a.time <= (SELECT max(time) FROM c_l0)
             AND a.device_id IN (SELECT device_id FROM c_l0 WHERE dev_type_id = 17)) a USING (device_id, time)
CROSS JOIN LATERAL (VALUES
   ('active_power_kw', l1.num(c.m->'active_power') / 1000, a.active_power_kw), ('energy_forward_kwh', l1.num(c.m->'active_cap'), a.energy_forward_kwh),
   ('energy_reverse_kwh', l1.num(c.m->'reverse_active_cap'), a.energy_reverse_kwh)) f(field, l0, ts);

SELECT tbl, field,
       count(*) FILTER (WHERE in_l0 AND in_ts) AS samples_both,
       count(*) FILTER (WHERE in_l0 AND NOT in_ts) AS only_l0,
       count(*) FILTER (WHERE in_ts AND NOT in_l0) AS only_influx,
       count(*) FILTER (WHERE in_l0 AND in_ts AND (abs(l0 - ts) <= 1e-6 OR (l0 IS NULL AND ts IS NULL))) AS equal,
       count(*) FILTER (WHERE in_l0 AND in_ts AND l0 IS NULL AND ts = 0) AS null_vs_0,
       count(*) FILTER (WHERE in_l0 AND in_ts AND NOT (abs(l0 - ts) <= 1e-6 OR (l0 IS NULL AND ts IS NULL) OR (l0 IS NULL AND ts = 0))) AS different
FROM c_pairs GROUP BY 1, 2 ORDER BY 1, 2;

-- DC strings: per (string, time); L0 side only for strings that exist in the asset model.
SELECT 'dc_string' AS tbl, count(*) FILTER (WHERE d.string_id IS NOT NULL AND p.u IS NOT NULL) AS samples_both,
       count(*) FILTER (WHERE d.string_id IS NULL) AS only_l0, count(*) FILTER (WHERE p.u IS NULL) AS only_influx,
       count(*) FILTER (WHERE abs(d.voltage_v - p.u) <= 1e-6 AND (abs(d.current_a - p.i) <= 1e-6 OR (p.i IS NULL AND d.current_a = 0))) AS equal
FROM (SELECT c.time, s.string_id, l1.num(kv.value) AS u, l1.num(c.m -> replace(kv.key, '_u', '_i')) AS i
      FROM c_l0 c CROSS JOIN LATERAL jsonb_each(c.m) kv
      JOIN asset.pv_string s ON s.inverter_id = c.device_id AND s.string_no = (regexp_match(kv.key, '^pv([0-9]+)_u$'))[1]::smallint
                             AND upper(s.valid) = 'infinity'
      WHERE c.dev_type_id = 1 AND kv.key ~ '^pv[0-9]+_u$' AND kv.value <> 'null'::jsonb) p
FULL JOIN (SELECT d.* FROM ts.dc_string d WHERE d.time >= (SELECT min(time) FROM c_l0) AND d.time <= (SELECT max(time) FROM c_l0)
             AND d.string_id IN (SELECT s.string_id FROM asset.pv_string s JOIN c_l0 c ON c.device_id = s.inverter_id WHERE c.dev_type_id = 1)) d
     USING (string_id, time);
