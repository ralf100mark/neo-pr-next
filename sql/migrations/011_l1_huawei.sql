-- 011 l1: the normaliser L0 -> L1 for the Huawei northbound API (module l1_huawei, docs/PIPELINE.md §2).
-- Reads raw.api_response (getDevRealKpi), writes ts.inverter_ac, ts.dc_string, ts.irradiance, ts.grid_meter.
-- Same mapping and units as the interim Influx ingest (docs/MODEL.md §4) with one deliberate difference: a value the API
-- delivers as null stays NULL here (the Influx writer of the consumer stores null as 0.0). Modules that must reproduce
-- the old numbers apply that convention to their own inputs (calc.pr_neo_customer_*).

CREATE SCHEMA IF NOT EXISTS l1;
COMMENT ON SCHEMA l1 IS 'Normalisers L0 -> L1 (one set of functions per vendor API)';

-- A JSON value as a number: numbers as they are, numeric strings cast, anything else NULL.
CREATE OR REPLACE FUNCTION l1.num(v jsonb) RETURNS double precision LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE jsonb_typeof(v)
           WHEN 'number' THEN (v #>> '{}')::double precision
           WHEN 'string' THEN CASE WHEN (v #>> '{}') ~ '^\s*-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\s*$'
                                   THEN (v #>> '{}')::double precision END
         END $$;

-- The device items of the getDevRealKpi responses fetched in [p_from, p_to): one row per device and sample.
-- time = the request collectTime echoed in params, truncated to the second (as the Influx writer does).
-- Items whose dataItemMap is empty or all null are skipped (as the Influx writer does).
CREATE OR REPLACE FUNCTION l1.huawei_dev_real(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (raw_id bigint, dev_type_id smallint, sample_time timestamptz, dev_id bigint, m jsonb)
LANGUAGE sql STABLE AS $$
  SELECT r.raw_id, r.dev_type_id,
         to_timestamp(floor((r.response #>> '{params,collectTime}')::numeric / 1000)),
         (e ->> 'devId')::bigint, e -> 'dataItemMap'
  FROM raw.api_response r
  CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r.response -> 'data') = 'array' THEN r.response -> 'data' ELSE '[]' END) e
  WHERE r.endpoint = 'getDevRealKpi' AND r.success AND r.fetched_at >= p_from AND r.fetched_at < p_to
    AND (r.response #>> '{params,collectTime}') IS NOT NULL
    AND jsonb_typeof(e -> 'dataItemMap') = 'object'
    AND EXISTS (SELECT 1 FROM jsonb_each(e -> 'dataItemMap') kv WHERE kv.value <> 'null'::jsonb) $$;

-- Load [p_from, p_to) of L0 into L1. Idempotent (ON CONFLICT DO NOTHING). Returns the row counts and the data time range
-- (for the dirty windows of the downstream modules).
CREATE OR REPLACE FUNCTION l1.load_huawei(p_from timestamptz, p_to timestamptz, p_run bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    n_inv bigint; n_dc bigint; n_emi bigint; n_gm bigint; n_new_str bigint; n_unknown bigint;
    t_min timestamptz; t_max timestamptz;
BEGIN
    CREATE TEMP TABLE _d ON COMMIT DROP AS
    SELECT x.*, dv.device_id
    FROM l1.huawei_dev_real(p_from, p_to) x
    LEFT JOIN asset.device dv ON dv.vendor = 'huawei' AND dv.vendor_device_id = x.dev_id AND upper(dv.valid) = 'infinity';
    SELECT min(sample_time), max(sample_time) INTO t_min, t_max FROM _d;

    -- Devices delivered by the API but not in the asset model.
    INSERT INTO dq.unknown_sensor (vendor_device_id, measurement, station_code)
    SELECT DISTINCT ON (d.dev_id, d.dev_type_id) d.dev_id, 'GetDevRealKpi_' || d.dev_type_id,
           (SELECT s.station_code FROM src.device s WHERE s.dev_id = d.dev_id ORDER BY s.last_seen DESC LIMIT 1)
    FROM _d d WHERE d.device_id IS NULL
    ON CONFLICT (vendor, vendor_device_id, measurement) DO UPDATE SET last_seen = now(), station_code = excluded.station_code;
    GET DIAGNOSTICS n_unknown = ROW_COUNT;

    INSERT INTO ts.inverter_ac (time, device_id, active_power_kw, reactive_power_kvar, power_factor, frequency_hz, u_ab_v, u_bc_v,
                                u_ca_v, i_a_a, i_b_a, i_c_a, energy_day_kwh, energy_total_kwh, dc_power_kw, temperature_c,
                                efficiency_pct, state, run_id)
    SELECT sample_time, device_id, l1.num(m->'active_power'), l1.num(m->'reactive_power'), l1.num(m->'power_factor'),
           l1.num(m->'elec_freq'), l1.num(m->'ab_u'), l1.num(m->'bc_u'), l1.num(m->'ca_u'), l1.num(m->'a_i'), l1.num(m->'b_i'),
           l1.num(m->'c_i'), l1.num(m->'day_cap'), l1.num(m->'total_cap'), l1.num(m->'mppt_power'), l1.num(m->'temperature'),
           l1.num(m->'efficiency'), l1.num(m->'inverter_state')::integer, p_run
    FROM _d WHERE dev_type_id = 1 AND device_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n_inv = ROW_COUNT;

    -- DC inputs pv<N>_u / pv<N>_i. An input without a configured string becomes an observed string once it carries >= 1 A.
    CREATE TEMP TABLE _pv ON COMMIT DROP AS
    SELECT d.sample_time AS time, d.device_id, (regexp_match(kv.key, '^pv([0-9]+)_u$'))[1]::smallint AS string_no,
           l1.num(kv.value) AS u, l1.num(d.m -> replace(kv.key, '_u', '_i')) AS i
    FROM _d d CROSS JOIN LATERAL jsonb_each(d.m) kv
    WHERE d.dev_type_id = 1 AND d.device_id IS NOT NULL AND kv.key ~ '^pv[0-9]+_u$' AND kv.value <> 'null'::jsonb;

    INSERT INTO asset.pv_string (inverter_id, string_no, enabled, configured, source)
    SELECT p.device_id, p.string_no, true, false, 'observed in data, not configured'
    FROM _pv p
    WHERE NOT EXISTS (SELECT 1 FROM asset.pv_string s WHERE s.inverter_id = p.device_id AND s.string_no = p.string_no
                        AND upper(s.valid) = 'infinity')
    GROUP BY p.device_id, p.string_no HAVING max(p.i) >= 1.0;
    GET DIAGNOSTICS n_new_str = ROW_COUNT;

    INSERT INTO ts.dc_string (time, string_id, voltage_v, current_a, run_id)
    SELECT p.time, s.string_id, p.u, p.i, p_run
    FROM _pv p JOIN asset.pv_string s ON s.inverter_id = p.device_id AND s.string_no = p.string_no AND upper(s.valid) = 'infinity'
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n_dc = ROW_COUNT;

    INSERT INTO ts.irradiance (time, device_id, poa_w_m2, poa_total_kwh_m2, ghi_w_m2, ghi_total_kwh_m2, module_temp_c, ambient_temp_c,
                               wind_speed_m_s, wind_direction_deg, run_id)
    SELECT sample_time, device_id, l1.num(m->'radiant_line'), l1.num(m->'radiant_total') / 3.6, l1.num(m->'horiz_radiant_line'),
           l1.num(m->'horiz_radiant_total') / 3.6, l1.num(m->'pv_temperature'), l1.num(m->'temperature'), l1.num(m->'wind_speed'),
           l1.num(m->'wind_direction'), p_run
    FROM _d WHERE dev_type_id = 10 AND device_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n_emi = ROW_COUNT;

    INSERT INTO ts.grid_meter (time, device_id, active_power_kw, reactive_power_kvar, power_factor, frequency_hz, energy_forward_kwh,
                               energy_reverse_kwh, run_id)
    SELECT sample_time, device_id, l1.num(m->'active_power') / 1000, l1.num(m->'reactive_power') / 1000, l1.num(m->'power_factor'),
           l1.num(m->'grid_frequency'), l1.num(m->'active_cap'), l1.num(m->'reverse_active_cap'), p_run
    FROM _d WHERE dev_type_id = 17 AND device_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n_gm = ROW_COUNT;

    DROP TABLE _d, _pv;
    RETURN jsonb_build_object('inverter_ac', n_inv, 'dc_string', n_dc, 'irradiance', n_emi, 'grid_meter', n_gm,
                              'new_observed_strings', n_new_str, 'unknown_devices', n_unknown,
                              'time_min', t_min, 'time_max', t_max);
END $$;
COMMENT ON FUNCTION l1.load_huawei IS 'Module l1_huawei: L0 getDevRealKpi responses fetched in [from, to) -> ts.*, idempotent';
