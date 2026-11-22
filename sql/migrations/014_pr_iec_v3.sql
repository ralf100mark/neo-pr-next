-- 014 pr_iec_61724_1 v3: the daily IEC PR sums ALL intervals of the day (sum Yf / sum Yr), as IEC 61724-1 defines the period PR.
-- v2 summed only intervals with Yr > 0. The EMI's cumulative irradiation counter has a coarse resolution, so on dull days many
-- 5-min intervals show H = 0 while the inverters produce; v2 dropped that energy but no irradiation and came out too low
-- (NE=51345970 on 2026-11-21: v2 0.608, v3 0.678). The interval module is unchanged (new version label only, so the daily
-- module reads its own version). v2 rows stay; api_v1 switches to v3 via meta.api_published once the backfill is checked.

CREATE OR REPLACE FUNCTION calc.m_pr_iec_daily_v3(p_from timestamptz, p_to timestamptz, p_version text, p_run bigint)
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
           sum(x.yf_h) / nullif(sum(x.yr_h), 0),
           sum(x.yf_h) FILTER (WHERE x.c_k > 0) / nullif(sum(x.yr_h * x.c_k) FILTER (WHERE x.c_k > 0), 0),
           count(*), p_run
    FROM calc.pr_interval x
    WHERE x.method = 'iec_61724_1' AND x.version = p_version AND x.time >= t_from AND x.time < t_to
      AND x.yf_h IS NOT NULL AND x.yr_h IS NOT NULL
    GROUP BY 1, 2, 3, 4
    ON CONFLICT (method, version, level, plant_id, inverter_id, string_id, day) DO UPDATE SET
        energy_kwh = excluded.energy_kwh, p0_kw = excluded.p0_kw, h_poa_kwh_m2 = excluded.h_poa_kwh_m2, pr = excluded.pr,
        pr_temp_corrected = excluded.pr_temp_corrected, intervals = excluded.intervals, run_id = excluded.run_id;
    GET DIAGNOSTICS n = ROW_COUNT; n_total := n_total + n;

    -- String level (DC) as in v2.
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
COMMENT ON FUNCTION calc.m_pr_iec_daily_v3 IS 'Module pr_iec_61724_1.daily v3: period PR = sum Yf / sum Yr over all intervals';

UPDATE meta.module SET version = 'v3' WHERE name = 'pr_iec_61724_1.interval';
UPDATE meta.module SET version = 'v3', entrypoint = 'calc.m_pr_iec_daily_v3',
       description = 'IEC daily PR per local day (sum Yf / sum Yr over all intervals): plant, inverter, string (DC)'
WHERE name = 'pr_iec_61724_1.daily';

-- Backfill v3 over the L1 history; the daily module follows through the dirty windows.
INSERT INTO meta.dirty_window (module, win, reason)
SELECT 'pr_iec_61724_1.interval', tstzrange(min(time), now()), 'v3 backfill' FROM ts.inverter_ac HAVING min(time) IS NOT NULL;
