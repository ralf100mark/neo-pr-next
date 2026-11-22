-- 012 modules: registry, dirty windows, and the PR calculation split into one module per method and grain
-- (docs/PIPELINE.md §3). Every L2 module has the same entry signature:
--     <entrypoint>(p_from timestamptz, p_to timestamptz, p_version text, p_run bigint) RETURNS bigint   -- rows written
-- and writes only its own outputs. The orchestrator (service/neo_model.py) runs enabled modules in dependency order on their
-- dirty windows. The numbers are those of calc.compute_intervals / compute_daily (005), which stay for manual use.

CREATE TABLE meta.module (
    name        text PRIMARY KEY,
    version     text NOT NULL,                          -- written to calc.* (version column); a new version runs next to the old
    layer       text NOT NULL CHECK (layer IN ('L1', 'L2', 'L3')),
    entrypoint  text,                                   -- SQL function (schema-qualified); NULL: run by the service in Python
    grain       text NOT NULL CHECK (grain IN ('sample', 'interval', 'day_local', 'day_utc')),
    lookback    interval NOT NULL DEFAULT '0',          -- the window is widened backwards by this (late input changes earlier output)
    depends_on  text[] NOT NULL DEFAULT '{}',           -- modules whose output this module reads
    inputs      text[] NOT NULL DEFAULT '{}',
    outputs     text[] NOT NULL DEFAULT '{}',
    params      jsonb NOT NULL DEFAULT '{}',
    enabled     boolean NOT NULL DEFAULT true,
    description text
);
COMMENT ON TABLE meta.module IS 'Module registry (docs/PIPELINE.md §3): one row per processing unit';

CREATE TABLE meta.dirty_window (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    module    text NOT NULL REFERENCES meta.module,
    win       tstzrange NOT NULL,
    reason    text,
    marked_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON meta.dirty_window (module, id);
COMMENT ON TABLE meta.dirty_window IS 'Windows a module must (re)compute; cleared by the orchestrator after a successful run';

-- Mark a window dirty for the modules that read the output of p_source (a module name, or ''l1'' for any L1 load).
CREATE OR REPLACE FUNCTION meta.mark_dependents(p_source text, p_win tstzrange, p_reason text) RETURNS integer
LANGUAGE sql AS $$
  WITH ins AS (
    INSERT INTO meta.dirty_window (module, win, reason)
    SELECT m.name, p_win, p_reason FROM meta.module m WHERE m.enabled AND p_source = ANY (m.depends_on)
    RETURNING 1)
  SELECT count(*)::integer FROM ins $$;

-- Backfill: mark the whole period dirty for one module (e.g. after a new version), the orchestrator does the rest.
CREATE OR REPLACE FUNCTION meta.backfill(p_module text, p_from timestamptz, p_to timestamptz) RETURNS void
LANGUAGE sql AS $$ INSERT INTO meta.dirty_window (module, win, reason) VALUES (p_module, tstzrange(p_from, p_to), 'backfill') $$;


-- ------------------------------------------------------------------------------------------------ shared preparation
-- Temp tables _inv, _slot, _pl for [p_from, p_to) (plus 35 min context). p_asis = true applies the input convention of
-- PR as-is 0.2: a missing value counts as 0 (its Influx source stored null as 0.0). Used by neo_customer; IEC uses NULLs.
CREATE OR REPLACE FUNCTION calc.prepare_pr_inputs(p_from timestamptz, p_to timestamptz, p_asis boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    DROP TABLE IF EXISTS _inv, _ps, _gm, _emi, _slot, _pl;
    CREATE TEMP TABLE _inv ON COMMIT DROP AS
    SELECT device_id, plant_id, time, slot, state, next_time,
           CASE WHEN next_time <= time + INTERVAL '30 min' THEN greatest(next_e - e, 0) ELSE 0 END AS e_kwh
    FROM (SELECT a.device_id, d.plant_id, a.time, time_bucket(INTERVAL '5 min', a.time) AS slot,
                 CASE WHEN p_asis THEN coalesce(a.state, 0) ELSE a.state END AS state,
                 CASE WHEN p_asis THEN coalesce(a.energy_day_kwh, 0) ELSE a.energy_day_kwh END AS e,
                 lead(a.time) OVER w AS next_time,
                 lead(CASE WHEN p_asis THEN coalesce(a.energy_day_kwh, 0) ELSE a.energy_day_kwh END) OVER w AS next_e
          FROM ts.inverter_ac a
          JOIN asset.device d USING (device_id)
          JOIN asset.plant p ON p.plant_id = d.plant_id AND p.pr_active
          WHERE d.kind = 'inverter' AND d.is_primary
            AND a.time >= p_from - INTERVAL '35 min' AND a.time < p_to + INTERVAL '35 min'
          WINDOW w AS (PARTITION BY a.device_id, (a.time AT TIME ZONE 'Asia/Bangkok')::date ORDER BY a.time)) q;

    CREATE TEMP TABLE _ps ON COMMIT DROP AS
    WITH s AS (SELECT plant_id, slot, bool_and(state = 512) AS gc, bool_or(state = 513) AS pl FROM _inv GROUP BY 1, 2)
    SELECT plant_id, slot, gc, pl,
           coalesce(lag(gc) OVER w AND lag(slot) OVER w >= slot - INTERVAL '30 min', false)  AS gc_prev,
           coalesce(lead(gc) OVER w AND lead(slot) OVER w <= slot + INTERVAL '30 min', false) AS gc_next
    FROM s WINDOW w AS (PARTITION BY plant_id ORDER BY slot);

    CREATE TEMP TABLE _gm ON COMMIT DROP AS
    SELECT DISTINCT ON (plant_id, slot) plant_id, slot, active_power_kw, fwd_kwh
    FROM (SELECT d.plant_id, g.time, time_bucket(INTERVAL '5 min', g.time) AS slot,
                 CASE WHEN p_asis THEN coalesce(g.active_power_kw, 0) ELSE g.active_power_kw END AS active_power_kw,
                 CASE WHEN lead(g.time) OVER w <= g.time + INTERVAL '30 min'
                      THEN lead(CASE WHEN p_asis THEN coalesce(g.energy_forward_kwh, 0) ELSE g.energy_forward_kwh END) OVER w
                           - CASE WHEN p_asis THEN coalesce(g.energy_forward_kwh, 0) ELSE g.energy_forward_kwh END
                      ELSE 0 END AS fwd_kwh
          FROM ts.grid_meter g JOIN asset.device d USING (device_id)
          WHERE d.kind = 'grid_meter' AND d.is_primary
            AND g.time >= p_from - INTERVAL '35 min' AND g.time < p_to + INTERVAL '35 min'
          WINDOW w AS (PARTITION BY g.device_id ORDER BY g.time)) x
    ORDER BY plant_id, slot, time;

    CREATE TEMP TABLE _emi ON COMMIT DROP AS
    SELECT DISTINCT ON (plant_id, slot) plant_id, slot, h_kwh_m2, module_temp_c
    FROM (SELECT d.plant_id, i.time, time_bucket(INTERVAL '5 min', i.time) AS slot,
                 CASE WHEN p_asis THEN coalesce(i.module_temp_c, 0) ELSE i.module_temp_c END AS module_temp_c,
                 CASE WHEN lead(i.time) OVER w <= i.time + INTERVAL '30 min'
                      THEN greatest(lead(CASE WHEN p_asis THEN coalesce(i.poa_total_kwh_m2, 0) ELSE i.poa_total_kwh_m2 END) OVER w
                                    - CASE WHEN p_asis THEN coalesce(i.poa_total_kwh_m2, 0) ELSE i.poa_total_kwh_m2 END, 0)
                      ELSE 0 END AS h_kwh_m2
          FROM ts.irradiance i JOIN asset.device d USING (device_id)
          WHERE d.kind = 'irradiance_sensor' AND d.is_primary
            AND i.time >= p_from - INTERVAL '35 min' AND i.time < p_to + INTERVAL '35 min'
          WINDOW w AS (PARTITION BY i.device_id, (i.time AT TIME ZONE 'Asia/Bangkok')::date ORDER BY i.time)) x
    ORDER BY plant_id, slot, time;

    CREATE TEMP TABLE _slot ON COMMIT DROP AS
    SELECT ps.plant_id, ps.slot, (ps.gc AND ps.gc_prev AND ps.gc_next) AS all_gc, ps.pl,
           gm.active_power_kw AS meter_kw, (gm.fwd_kwh > 0) AS grid_import, coalesce(ipz.value_kw, 0) AS ipz_kw,
           e.h_kwh_m2, e.module_temp_c, mf.temp_ref_c, p.g_ref_w_m2 / 1000.0 AS g_ref_kw_m2
    FROM _ps ps
    JOIN _gm gm USING (plant_id, slot)
    JOIN _emi e USING (plant_id, slot)
    JOIN asset.plant p ON p.plant_id = ps.plant_id
    LEFT JOIN asset.plant_import_power ipz
           ON ipz.plant_id = ps.plant_id AND ipz.month = (date_trunc('month', ps.slot AT TIME ZONE 'UTC') - INTERVAL '1 month')::date
    LEFT JOIN asset.plant_month_factor mf
           ON mf.plant_id = ps.plant_id AND mf.month = date_trunc('month', ps.slot AT TIME ZONE 'UTC')::date;
    ALTER TABLE _slot ADD COLUMN included boolean, ADD COLUMN reason text;
    UPDATE _slot SET included = all_gc AND NOT grid_import AND meter_kw < ipz_kw,
                     reason = CASE WHEN NOT all_gc THEN 'not_grid_connected'
                                   WHEN grid_import THEN 'grid_import'
                                   WHEN NOT (meter_kw < ipz_kw) THEN 'zero_export_limit' END;

    CREATE TEMP TABLE _pl ON COMMIT DROP AS
    SELECT i.plant_id, i.slot, sum(i.e_kwh) AS e_kwh, sum(c.p0_kw) AS p0_kw,
           sum(c.p0_kw * coalesce(c.gamma_pct_per_c, 0)) / nullif(sum(c.p0_kw), 0) AS gamma
    FROM _inv i JOIN asset.inverter_capacity c ON c.inverter_id = i.device_id AND c.p0_kw > 0
    WHERE i.time >= p_from AND i.time < p_to
    GROUP BY 1, 2;
END $$;


-- ------------------------------------------------------------------------------------------------ module pr_iec_61724_1.interval
CREATE OR REPLACE FUNCTION calc.m_pr_iec_interval(p_from timestamptz, p_to timestamptz, p_version text, p_run bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n_total bigint := 0; n bigint;
BEGIN
    PERFORM calc.prepare_pr_inputs(p_from, p_to, false);

    INSERT INTO calc.pr_interval (time, slot, interval_s, plant_id, inverter_id, method, version, energy_kwh, p0_kw,
                                  h_meas_kwh_m2, h_poa_kwh_m2, yf_h, yr_h, pr, module_temp_c, c_k, pr_temp_corrected, run_id)
    SELECT i.time, i.slot, extract(epoch FROM i.next_time - i.time)::int, i.plant_id, i.device_id, 'iec_61724_1', p_version,
           i.e_kwh, c.p0_kw, s.h_kwh_m2, s.h_kwh_m2, i.e_kwh / c.p0_kw, s.h_kwh_m2 / s.g_ref_kw_m2,
           CASE WHEN s.h_kwh_m2 > 0 THEN (i.e_kwh / c.p0_kw) / (s.h_kwh_m2 / s.g_ref_kw_m2) END,
           s.module_temp_c, k.c_k,
           CASE WHEN s.h_kwh_m2 > 0 AND k.c_k > 0 THEN (i.e_kwh / c.p0_kw) / (s.h_kwh_m2 / s.g_ref_kw_m2) / k.c_k END,
           p_run
    FROM _inv i
    JOIN _slot s USING (plant_id, slot)
    JOIN asset.inverter_capacity c ON c.inverter_id = i.device_id AND c.p0_kw > 0
    CROSS JOIN LATERAL (SELECT 1 + coalesce(c.gamma_pct_per_c, 0) * (s.module_temp_c - 25) / 100 AS c_k) k
    WHERE i.time >= p_from AND i.time < p_to
    ON CONFLICT (method, version, plant_id, inverter_id, time) DO UPDATE SET
        slot = excluded.slot, interval_s = excluded.interval_s, energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw,
        h_meas_kwh_m2 = excluded.h_meas_kwh_m2, h_poa_kwh_m2 = excluded.h_poa_kwh_m2, yf_h = excluded.yf_h, yr_h = excluded.yr_h,
        pr = excluded.pr, module_temp_c = excluded.module_temp_c, c_k = excluded.c_k,
        pr_temp_corrected = excluded.pr_temp_corrected, run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;

    INSERT INTO calc.pr_interval (time, slot, interval_s, plant_id, inverter_id, method, version, energy_kwh, p0_kw,
                                  h_meas_kwh_m2, h_poa_kwh_m2, yf_h, yr_h, pr, module_temp_c, c_k, pr_temp_corrected, run_id)
    SELECT l.slot, l.slot, 300, l.plant_id, NULL, 'iec_61724_1', p_version, l.e_kwh, l.p0_kw, s.h_kwh_m2, s.h_kwh_m2,
           l.e_kwh / l.p0_kw, s.h_kwh_m2 / s.g_ref_kw_m2,
           CASE WHEN s.h_kwh_m2 > 0 THEN (l.e_kwh / l.p0_kw) / (s.h_kwh_m2 / s.g_ref_kw_m2) END,
           s.module_temp_c, k.c_k,
           CASE WHEN s.h_kwh_m2 > 0 AND k.c_k > 0 THEN (l.e_kwh / l.p0_kw) / (s.h_kwh_m2 / s.g_ref_kw_m2) / k.c_k END,
           p_run
    FROM _pl l JOIN _slot s USING (plant_id, slot)
    CROSS JOIN LATERAL (SELECT 1 + l.gamma * (s.module_temp_c - 25) / 100 AS c_k) k
    ON CONFLICT (method, version, plant_id, inverter_id, time) DO UPDATE SET
        energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw, h_meas_kwh_m2 = excluded.h_meas_kwh_m2,
        h_poa_kwh_m2 = excluded.h_poa_kwh_m2, yf_h = excluded.yf_h, yr_h = excluded.yr_h, pr = excluded.pr,
        module_temp_c = excluded.module_temp_c, c_k = excluded.c_k, pr_temp_corrected = excluded.pr_temp_corrected,
        run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;

    DROP TABLE _inv, _ps, _gm, _emi, _slot, _pl;
    RETURN n_total;
END $$;


-- ------------------------------------------------------------------------------------------------ module pr_neo_customer.interval
CREATE OR REPLACE FUNCTION calc.m_pr_customer_interval(p_from timestamptz, p_to timestamptz, p_version text, p_run bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n_total bigint := 0; n bigint;
BEGIN
    PERFORM calc.prepare_pr_inputs(p_from, p_to, true);

    INSERT INTO calc.pr_interval (time, slot, interval_s, plant_id, inverter_id, method, version, energy_kwh, p0_kw,
                                  h_meas_kwh_m2, h_poa_kwh_m2, yf_h, yr_h, pr, module_temp_c, grid_connected, power_limited,
                                  grid_import, meter_power_kw, ipz_threshold_kw, included, exclusion_reason, energy_xze_kwh,
                                  h_xze_kwh_m2, pr_xze, tmod_c, ck, tcf, pr_ck, pr_tcf, run_id)
    SELECT i.time, i.slot, extract(epoch FROM i.next_time - i.time)::int, i.plant_id, i.device_id, 'neo_customer', p_version,
           i.e_kwh, c.p0_kw, s.h_kwh_m2, s.h_kwh_m2 * f.f, i.e_kwh / c.p0_kw, s.h_kwh_m2 * f.f / s.g_ref_kw_m2,
           v.pr, s.module_temp_c, s.all_gc, s.pl, s.grid_import, s.meter_kw, s.ipz_kw, s.included, s.reason,
           CASE WHEN s.included THEN i.e_kwh ELSE 0 END, CASE WHEN s.included THEN s.h_kwh_m2 ELSE 0 END,
           v.pr_xze, t.tmod, t.ck, t.tcf,
           CASE WHEN t.ck = 0 THEN 0 ELSE v.pr_xze / t.ck END,
           CASE WHEN v.pr_xze = 0 THEN 0 ELSE v.pr_xze * t.tcf END,
           p_run
    FROM _inv i
    JOIN _slot s USING (plant_id, slot)
    JOIN asset.inverter_capacity c ON c.inverter_id = i.device_id AND c.p0_kw > 0
    LEFT JOIN asset.inverter_pr_param ip ON ip.device_id = i.device_id
    CROSS JOIN LATERAL (SELECT coalesce(c.poa_factor, 1) AS f) f
    CROSS JOIN LATERAL (SELECT CASE WHEN s.h_kwh_m2 * f.f > 0
                                    THEN (i.e_kwh / c.p0_kw) / (s.h_kwh_m2 * f.f / s.g_ref_kw_m2) ELSE 0 END AS pr) v0
    CROSS JOIN LATERAL (SELECT v0.pr, CASE WHEN s.included THEN v0.pr ELSE 0 END AS pr_xze) v
    CROSS JOIN LATERAL (SELECT CASE WHEN s.included AND s.h_kwh_m2 > 0 THEN s.module_temp_c ELSE 0 END AS tmod) t0
    CROSS JOIN LATERAL (
        SELECT t0.tmod,
               CASE WHEN t0.tmod = 0 THEN 0 ELSE 1 + ip.temp_coeff_pct_per_c * (t0.tmod - s.temp_ref_c) / 100 END AS ck,
               CASE WHEN t0.tmod = 0 THEN 0
                    ELSE (1 + ip.temp_coeff_pct_per_c * (s.temp_ref_c - 25) / 100)
                         / nullif(1 + ip.temp_coeff_pct_per_c * (t0.tmod - 25) / 100, 0) END AS tcf) t
    WHERE i.time >= p_from AND i.time < p_to AND s.temp_ref_c IS NOT NULL
    ON CONFLICT (method, version, plant_id, inverter_id, time) DO UPDATE SET
        slot = excluded.slot, interval_s = excluded.interval_s, energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw,
        h_meas_kwh_m2 = excluded.h_meas_kwh_m2, h_poa_kwh_m2 = excluded.h_poa_kwh_m2, yf_h = excluded.yf_h, yr_h = excluded.yr_h,
        pr = excluded.pr, module_temp_c = excluded.module_temp_c, grid_connected = excluded.grid_connected,
        power_limited = excluded.power_limited, grid_import = excluded.grid_import, meter_power_kw = excluded.meter_power_kw,
        ipz_threshold_kw = excluded.ipz_threshold_kw, included = excluded.included, exclusion_reason = excluded.exclusion_reason,
        energy_xze_kwh = excluded.energy_xze_kwh, h_xze_kwh_m2 = excluded.h_xze_kwh_m2, pr_xze = excluded.pr_xze,
        tmod_c = excluded.tmod_c, ck = excluded.ck, tcf = excluded.tcf, pr_ck = excluded.pr_ck, pr_tcf = excluded.pr_tcf,
        run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;

    INSERT INTO calc.pr_interval (time, slot, interval_s, plant_id, inverter_id, method, version, energy_kwh, p0_kw,
                                  h_meas_kwh_m2, h_poa_kwh_m2, yf_h, yr_h, pr, module_temp_c, grid_connected, power_limited,
                                  grid_import, meter_power_kw, ipz_threshold_kw, included, exclusion_reason, energy_xze_kwh,
                                  h_xze_kwh_m2, pr_xze, tmod_c, run_id)
    SELECT l.slot, l.slot, 300, l.plant_id, NULL, 'neo_customer', p_version, l.e_kwh, pp.string_cap_w / 1000.0,
           s.h_kwh_m2, g.h_g, l.e_kwh / (pp.string_cap_w / 1000.0), g.h_g / s.g_ref_kw_m2,
           v.pr, s.module_temp_c, s.all_gc, s.pl, s.grid_import, s.meter_kw, s.ipz_kw, s.included, s.reason,
           CASE WHEN s.included THEN l.e_kwh ELSE 0 END, CASE WHEN s.included THEN g.h_g ELSE 0 END,
           CASE WHEN s.included THEN v.pr ELSE 0 END,
           CASE WHEN s.included AND s.h_kwh_m2 > 0 THEN s.module_temp_c ELSE 0 END,
           p_run
    FROM _pl l JOIN _slot s USING (plant_id, slot)
    JOIN asset.plant_pr_param pp ON pp.plant_id = l.plant_id AND pp.string_cap_w > 0
    CROSS JOIN LATERAL (SELECT s.h_kwh_m2 * coalesce(pp.globinc_pct, 100) / 100 AS h_g) g
    CROSS JOIN LATERAL (SELECT CASE WHEN g.h_g > 0 THEN (l.e_kwh / (pp.string_cap_w / 1000.0)) / (g.h_g / s.g_ref_kw_m2)
                                    ELSE 0 END AS pr) v
    WHERE s.temp_ref_c IS NOT NULL
    ON CONFLICT (method, version, plant_id, inverter_id, time) DO UPDATE SET
        energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw, h_meas_kwh_m2 = excluded.h_meas_kwh_m2,
        h_poa_kwh_m2 = excluded.h_poa_kwh_m2, yf_h = excluded.yf_h, yr_h = excluded.yr_h, pr = excluded.pr,
        module_temp_c = excluded.module_temp_c, grid_connected = excluded.grid_connected, power_limited = excluded.power_limited,
        grid_import = excluded.grid_import, meter_power_kw = excluded.meter_power_kw, ipz_threshold_kw = excluded.ipz_threshold_kw,
        included = excluded.included, exclusion_reason = excluded.exclusion_reason, energy_xze_kwh = excluded.energy_xze_kwh,
        h_xze_kwh_m2 = excluded.h_xze_kwh_m2, pr_xze = excluded.pr_xze, tmod_c = excluded.tmod_c, run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;

    DROP TABLE _inv, _ps, _gm, _emi, _slot, _pl;
    RETURN n_total;
END $$;


-- ------------------------------------------------------------------------------------------------ module pr_iec_61724_1.daily
-- Local days (Asia/Bangkok) touched by [p_from, p_to): plant + inverter from the intervals, string level from DC power.
CREATE OR REPLACE FUNCTION calc.m_pr_iec_daily(p_from timestamptz, p_to timestamptz, p_version text, p_run bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    n_total bigint := 0; n bigint;
    d_from date := (p_from AT TIME ZONE 'Asia/Bangkok')::date;
    d_to   date := ((p_to - INTERVAL '1 microsecond') AT TIME ZONE 'Asia/Bangkok')::date;
    t_from timestamptz := (d_from::timestamp AT TIME ZONE 'Asia/Bangkok');
    t_to   timestamptz := ((d_to + 1)::timestamp AT TIME ZONE 'Asia/Bangkok');
BEGIN
    INSERT INTO calc.pr_daily (day, level, plant_id, inverter_id, method, version, energy_kwh, p0_kw, h_poa_kwh_m2, pr,
                               pr_temp_corrected, intervals, run_id)
    SELECT (x.time AT TIME ZONE 'Asia/Bangkok')::date, CASE WHEN x.inverter_id IS NULL THEN 'plant' ELSE 'inverter' END,
           x.plant_id, x.inverter_id, 'iec_61724_1', p_version, sum(x.energy_kwh), max(x.p0_kw), sum(x.h_poa_kwh_m2),
           sum(x.yf_h) FILTER (WHERE x.yr_h > 0) / nullif(sum(x.yr_h) FILTER (WHERE x.yr_h > 0), 0),
           sum(x.yf_h) FILTER (WHERE x.yr_h > 0 AND x.c_k > 0) / nullif(sum(x.yr_h * x.c_k) FILTER (WHERE x.yr_h > 0 AND x.c_k > 0), 0),
           count(*) FILTER (WHERE x.yr_h > 0), p_run
    FROM calc.pr_interval x
    WHERE x.method = 'iec_61724_1' AND x.version = p_version AND x.time >= t_from AND x.time < t_to
    GROUP BY 1, 2, 3, 4
    ON CONFLICT (method, version, level, plant_id, inverter_id, string_id, day) DO UPDATE SET
        energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw, h_poa_kwh_m2 = excluded.h_poa_kwh_m2, pr = excluded.pr,
        pr_temp_corrected = excluded.pr_temp_corrected, intervals = excluded.intervals, run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;

    INSERT INTO calc.pr_daily (day, level, plant_id, inverter_id, string_id, method, version, energy_kwh, p0_kw, h_poa_kwh_m2,
                               pr, intervals, run_id)
    SELECT e.day, 'string', v.plant_id, s.inverter_id, e.string_id, 'iec_61724_1', p_version, e.e_dc, s.stc_capacity_w / 1000.0,
           h.h, CASE WHEN h.h > 0 AND s.stc_capacity_w > 0
                     THEN (e.e_dc / (s.stc_capacity_w / 1000.0)) / (h.h / (p.g_ref_w_m2 / 1000.0)) END,
           e.samples, p_run
    FROM (SELECT (time AT TIME ZONE 'Asia/Bangkok')::date AS day, string_id,
                 sum(power_w * least(extract(epoch FROM coalesce(nt - time, INTERVAL '300 s')), 1800)) / 3.6e6 AS e_dc,
                 count(*) AS samples
          FROM (SELECT time, string_id, power_w, lead(time) OVER (PARTITION BY string_id ORDER BY time) AS nt
                FROM ts.dc_string WHERE time >= t_from AND time < t_to) q
          GROUP BY 1, 2) e
    JOIN asset.pv_string s ON s.string_id = e.string_id AND s.configured AND s.enabled
    JOIN asset.device v ON v.device_id = s.inverter_id
    JOIN asset.plant p ON p.plant_id = v.plant_id AND p.pr_active
    JOIN (SELECT (time AT TIME ZONE 'Asia/Bangkok')::date AS day, plant_id, sum(h_meas_kwh_m2) AS h
          FROM calc.pr_interval WHERE method = 'iec_61724_1' AND version = p_version AND inverter_id IS NULL
            AND time >= t_from AND time < t_to GROUP BY 1, 2) h ON h.plant_id = v.plant_id AND h.day = e.day
    ON CONFLICT (method, version, level, plant_id, inverter_id, string_id, day) DO UPDATE SET
        energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw, h_poa_kwh_m2 = excluded.h_poa_kwh_m2, pr = excluded.pr,
        intervals = excluded.intervals, run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;
    RETURN n_total;
END $$;


-- ------------------------------------------------------------------------------------------------ module pr_neo_customer.daily
-- Customer days (UTC date, 00:00-12:10 UTC, docs/METHODS.md §3.3) touched by [p_from, p_to).
CREATE OR REPLACE FUNCTION calc.m_pr_customer_daily(p_from timestamptz, p_to timestamptz, p_version text, p_run bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    n_total bigint := 0; n bigint;
    d_from date := (p_from AT TIME ZONE 'UTC')::date;
    d_to   date := ((p_to - INTERVAL '1 microsecond') AT TIME ZONE 'UTC')::date;
    c_day_end time := '12:10';
BEGIN
    DROP TABLE IF EXISTS _pd;
    CREATE TEMP TABLE _pd ON COMMIT DROP AS
    SELECT (x.time AT TIME ZONE 'UTC')::date AS day, x.plant_id,
           sum(x.energy_kwh) AS e, sum(x.energy_xze_kwh) AS e_xze, sum(x.h_poa_kwh_m2) AS h_g, sum(x.h_xze_kwh_m2) AS h_xze_g,
           sum(x.h_meas_kwh_m2) AS h_meas,
           sum(x.module_temp_c * x.h_xze_kwh_m2) / nullif(sum(x.h_xze_kwh_m2), 0) AS tmod,
           count(*) FILTER (WHERE x.h_poa_kwh_m2 > 0) / 12.0 AS daylight_h,
           count(*) FILTER (WHERE x.h_poa_kwh_m2 > 0) / 12.0 - count(*) FILTER (WHERE x.h_xze_kwh_m2 > 0) / 12.0 AS ze_h,
           count(*) AS intervals
    FROM calc.pr_interval x
    WHERE x.method = 'neo_customer' AND x.version = p_version AND x.inverter_id IS NULL
      AND x.time >= (d_from::timestamp AT TIME ZONE 'UTC') AND x.time < ((d_to + 1)::timestamp AT TIME ZONE 'UTC')
      AND (x.time AT TIME ZONE 'UTC')::time < c_day_end
    GROUP BY 1, 2;

    INSERT INTO calc.pr_daily (day, level, plant_id, method, version, energy_kwh, p0_kw, h_poa_kwh_m2, pr, tmod_c,
                               energy_xze_kwh, h_xze_kwh_m2, pr_xze, ck, tcf, pr_ck, pr_tcf, pr_epc_ck, pr_epc_tcf,
                               daylight_h, ze_h, intervals, run_id)
    SELECT d.day, 'plant', d.plant_id, 'neo_customer', p_version, d.e, cap.p0, d.h_g, r.pr, coalesce(d.tmod, 0),
           d.e_xze, d.h_xze_g, r.pr_xze, t.ck, t.tcf, a.pr_ck, a.pr_tcf,
           CASE WHEN a.pr_ck = 0 OR epc.div = 0 THEN 0 ELSE a.pr_ck / epc.div END,
           CASE WHEN a.pr_tcf = 0 OR epc.div = 0 THEN 0 ELSE a.pr_tcf / epc.div END,
           d.daylight_h, d.ze_h, d.intervals, p_run
    FROM _pd d
    JOIN asset.plant p ON p.plant_id = d.plant_id
    JOIN asset.plant_pr_param pp ON pp.plant_id = d.plant_id
    LEFT JOIN asset.plant_month_factor mf ON mf.plant_id = d.plant_id AND mf.month = date_trunc('month', d.day)::date
    CROSS JOIN LATERAL (SELECT pp.string_cap_w / 1000.0 AS p0, p.g_ref_w_m2 / 1000.0 AS g) cap
    CROSS JOIN LATERAL (SELECT CASE WHEN d.h_g > 0 THEN (d.e / cap.p0) / (d.h_g / cap.g) ELSE 0 END AS pr,
                               CASE WHEN d.h_xze_g > 0 THEN (d.e_xze / cap.p0) / (d.h_xze_g / cap.g) ELSE 0 END AS pr_xze) r
    CROSS JOIN LATERAL (
        SELECT CASE WHEN coalesce(d.tmod, 0) = 0 THEN 0 ELSE 1 + pp.temp_coeff_pct_per_c * (d.tmod - mf.temp_ref_c) / 100 END AS ck,
               CASE WHEN coalesce(d.tmod, 0) = 0 THEN 0
                    ELSE (1 + pp.temp_coeff_pct_per_c * (mf.temp_ref_c - 25) / 100)
                         / nullif(1 + pp.temp_coeff_pct_per_c * (d.tmod - 25) / 100, 0) END AS tcf) t
    CROSS JOIN LATERAL (SELECT CASE WHEN t.ck = 0 THEN 0 ELSE r.pr_xze / t.ck END AS pr_ck,
                               CASE WHEN r.pr_xze = 0 THEN 0 ELSE r.pr_xze * t.tcf END AS pr_tcf) a
    CROSS JOIN LATERAL (SELECT coalesce(mf.degrade_cap_pct * mf.availability_pct / 10000, 0) AS div) epc
    ON CONFLICT (method, version, level, plant_id, inverter_id, string_id, day) DO UPDATE SET
        energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw, h_poa_kwh_m2 = excluded.h_poa_kwh_m2, pr = excluded.pr,
        tmod_c = excluded.tmod_c, energy_xze_kwh = excluded.energy_xze_kwh, h_xze_kwh_m2 = excluded.h_xze_kwh_m2,
        pr_xze = excluded.pr_xze, ck = excluded.ck, tcf = excluded.tcf, pr_ck = excluded.pr_ck, pr_tcf = excluded.pr_tcf,
        pr_epc_ck = excluded.pr_epc_ck, pr_epc_tcf = excluded.pr_epc_tcf, daylight_h = excluded.daylight_h,
        ze_h = excluded.ze_h, intervals = excluded.intervals, run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;

    INSERT INTO calc.pr_daily (day, level, plant_id, inverter_id, method, version, energy_kwh, p0_kw, h_poa_kwh_m2, pr, tmod_c,
                               energy_xze_kwh, h_xze_kwh_m2, pr_xze, ck, tcf, pr_ck, pr_tcf, pr_epc_ck, pr_epc_tcf, intervals, run_id)
    SELECT x.day, 'inverter', x.plant_id, x.inverter_id, 'neo_customer', p_version, x.e, ip.string_cap_w / 1000.0, x.h_meas,
           r.pr, coalesce(pd.tmod, 0), x.e_xze, x.h_xze, r.pr_xze, t.ck, t.tcf, a.pr_ck, a.pr_tcf,
           CASE WHEN a.pr_ck = 0 OR epc.div = 0 THEN 0 ELSE a.pr_ck / epc.div END,
           CASE WHEN a.pr_tcf = 0 OR epc.div = 0 THEN 0 ELSE a.pr_tcf / epc.div END,
           x.intervals, p_run
    FROM (SELECT (time AT TIME ZONE 'UTC')::date AS day, plant_id, inverter_id, sum(energy_kwh) AS e,
                 sum(energy_xze_kwh) AS e_xze, sum(h_meas_kwh_m2) AS h_meas, sum(h_xze_kwh_m2) AS h_xze, count(*) AS intervals
          FROM calc.pr_interval
          WHERE method = 'neo_customer' AND version = p_version AND inverter_id IS NOT NULL
            AND time >= (d_from::timestamp AT TIME ZONE 'UTC') AND time < ((d_to + 1)::timestamp AT TIME ZONE 'UTC')
            AND (time AT TIME ZONE 'UTC')::time < c_day_end
          GROUP BY 1, 2, 3) x
    JOIN asset.inverter_pr_param ip ON ip.device_id = x.inverter_id AND ip.string_cap_w > 0
    LEFT JOIN _pd pd ON pd.plant_id = x.plant_id AND pd.day = x.day
    LEFT JOIN asset.plant_month_factor mf ON mf.plant_id = x.plant_id AND mf.month = date_trunc('month', x.day)::date
    CROSS JOIN LATERAL (SELECT ip.string_cap_w / 1000.0 AS p0, coalesce(ip.g_ref_w_m2, 1000) / 1000.0 AS g,
                               coalesce(ip.globinc_pct, 100) / 100 AS f) c
    CROSS JOIN LATERAL (SELECT CASE WHEN x.h_meas > 0 THEN (x.e / c.p0) / (x.h_meas * c.f / c.g) ELSE 0 END AS pr,
                               CASE WHEN x.h_xze > 0 THEN (x.e_xze / c.p0) / (x.h_xze * c.f / c.g) ELSE 0 END AS pr_xze) r
    CROSS JOIN LATERAL (
        SELECT CASE WHEN coalesce(pd.tmod, 0) = 0 THEN 0 ELSE 1 + ip.temp_coeff_pct_per_c * (pd.tmod - mf.temp_ref_c) / 100 END AS ck,
               CASE WHEN coalesce(pd.tmod, 0) = 0 THEN 0
                    ELSE (1 + ip.temp_coeff_pct_per_c * (mf.temp_ref_c - 25) / 100)
                         / nullif(1 + ip.temp_coeff_pct_per_c * (pd.tmod - 25) / 100, 0) END AS tcf) t
    CROSS JOIN LATERAL (SELECT CASE WHEN t.ck = 0 THEN 0 ELSE r.pr_xze / t.ck END AS pr_ck,
                               CASE WHEN r.pr_xze = 0 THEN 0 ELSE r.pr_xze * t.tcf END AS pr_tcf) a
    CROSS JOIN LATERAL (SELECT coalesce(mf.degrade_cap_pct * mf.availability_pct / 10000, 0) AS div) epc
    ON CONFLICT (method, version, level, plant_id, inverter_id, string_id, day) DO UPDATE SET
        energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw, h_poa_kwh_m2 = excluded.h_poa_kwh_m2, pr = excluded.pr,
        tmod_c = excluded.tmod_c, energy_xze_kwh = excluded.energy_xze_kwh, h_xze_kwh_m2 = excluded.h_xze_kwh_m2,
        pr_xze = excluded.pr_xze, ck = excluded.ck, tcf = excluded.tcf, pr_ck = excluded.pr_ck, pr_tcf = excluded.pr_tcf,
        pr_epc_ck = excluded.pr_epc_ck, pr_epc_tcf = excluded.pr_epc_tcf, intervals = excluded.intervals, run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;

    DROP TABLE _pd;
    RETURN n_total;
END $$;


-- ------------------------------------------------------------------------------------------------ registry
INSERT INTO meta.module (name, version, layer, entrypoint, grain, lookback, depends_on, inputs, outputs, description) VALUES
 ('asset_sync', 'v2', 'L1', NULL, 'sample', '0', '{}', '{pr_live_neodb}', '{asset.*}',
  'PR configuration -> asset model with validity periods (Python, every 6 h)'),
 ('l1_influx', 'v2', 'L1', NULL, 'sample', '30 min', '{}', '{Influx NEO_LIVE}', '{ts.inverter_ac,ts.dc_string,ts.irradiance,ts.grid_meter}',
  'Interim L1 source: Influx NEO_LIVE (Python). Used when L1_SOURCE=influx'),
 ('l1_huawei', 'v1', 'L1', 'l1.load_huawei', 'sample', '10 min', '{}', '{raw.api_response}', '{ts.inverter_ac,ts.dc_string,ts.irradiance,ts.grid_meter}',
  'L0 getDevRealKpi -> L1 (SQL). Used when L1_SOURCE=l0'),
 ('pr_iec_61724_1.interval', 'v2', 'L2', 'calc.m_pr_iec_interval', 'interval', '35 min', '{l1}', '{ts.*,asset.*}', '{calc.pr_interval}',
  'IEC 61724-1 PR per 5-min interval, inverter + plant'),
 ('pr_neo_customer.interval', 'v2', 'L2', 'calc.m_pr_customer_interval', 'interval', '35 min', '{l1}', '{ts.*,asset.*}', '{calc.pr_interval}',
  'Customer PR (xze, CK/TCF) per 5-min interval, inverter + plant; as-is input convention (missing = 0)'),
 ('pr_iec_61724_1.daily', 'v2', 'L2', 'calc.m_pr_iec_daily', 'day_local', '0', '{pr_iec_61724_1.interval,l1}', '{calc.pr_interval,ts.dc_string}', '{calc.pr_daily}',
  'IEC daily PR per local day: plant, inverter, string (DC)'),
 ('pr_neo_customer.daily', 'v2', 'L2', 'calc.m_pr_customer_daily', 'day_utc', '0', '{pr_neo_customer.interval}', '{calc.pr_interval}', '{calc.pr_daily}',
  'Customer daily PR (customer day UTC 00:00-12:10), plant + inverter, EPC');
