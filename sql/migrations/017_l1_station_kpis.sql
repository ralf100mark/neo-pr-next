-- 017 L1 for the station and daily KPIs of the Huawei API (module l1_huawei, docs/PIPELINE.md §2.2). Without Mongo they are kept
-- here for good (the 31-day L0 is only the cache). Units as the Huawei northbound API documents them (kWh, kWh/m², %).
--   getStationRealKpi -> ts.station_real   (running day/month/total counters, every 5 min)
--   getKpiStationHour -> ts.station_period (period 'hour'), getKpiStationDay -> ts.station_period (period 'day')
--   getDevKpiDay      -> ts.device_day     (inverter daily yield)
-- Hour and day values can be revised by Huawei after the period: the latest delivery wins (DO UPDATE), raw_id = lineage.

CREATE TABLE ts.station_real (
    time                timestamptz NOT NULL,                   -- request collectTime (as in Influx)
    plant_id            integer NOT NULL REFERENCES asset.plant,
    energy_day_kwh      double precision,                       -- day_power
    energy_month_kwh    double precision,                       -- month_power
    energy_total_kwh    double precision,                       -- total_power
    grid_feed_day_kwh   double precision,                       -- day_on_grid_energy
    consumption_day_kwh double precision,                       -- day_use_energy
    income_day          double precision,                       -- day_income (plant currency)
    income_total        double precision,                       -- total_income
    health_state        smallint,                               -- real_health_state: 1 disconnected, 2 faulty, 3 healthy
    raw_id              bigint,
    run_id              bigint,
    PRIMARY KEY (plant_id, time)
);
SELECT create_hypertable('ts.station_real', by_range('time', INTERVAL '30 days'));

CREATE TABLE ts.station_period (
    period              text NOT NULL CHECK (period IN ('hour', 'day')),
    time                timestamptz NOT NULL,                   -- start of the period (item collectTime)
    plant_id            integer NOT NULL REFERENCES asset.plant,
    pv_yield_kwh        double precision,                       -- PVYield
    inverter_yield_kwh  double precision,                       -- inverterYield
    inverter_energy_kwh double precision,                       -- inverter_power
    grid_feed_kwh       double precision,                       -- ongrid_power
    consumption_kwh     double precision,                       -- use_power
    self_use_kwh        double precision,                       -- selfUsePower
    self_provide_kwh    double precision,                       -- selfProvide
    purchase_kwh        double precision,                       -- buyPower
    charge_kwh          double precision,                       -- chargeCap
    discharge_kwh       double precision,                       -- dischargeCap
    irradiation_kwh_m2  double precision,                       -- radiation_intensity
    theoretical_kwh     double precision,                       -- theory_power
    pr_vendor_pct       double precision,                       -- performance_ratio (Huawei's own PR)
    equivalent_hours_h  double precision,                       -- perpower_ratio
    installed_kwp       double precision,                       -- installed_capacity
    income              double precision,                       -- power_profit
    co2_avoided_t       double precision,                       -- reduction_total_co2
    coal_saved_t        double precision,                       -- reduction_total_coal
    trees_planted       double precision,                       -- reduction_total_tree
    raw_id              bigint,
    run_id              bigint,
    PRIMARY KEY (period, plant_id, time)
);
SELECT create_hypertable('ts.station_period', by_range('time', INTERVAL '90 days'));

CREATE TABLE ts.device_day (
    day                 date NOT NULL,                          -- local day (Asia/Bangkok) of the item collectTime
    device_id           integer NOT NULL REFERENCES asset.device,
    time                timestamptz NOT NULL,                   -- item collectTime
    energy_kwh          double precision,                       -- product_power
    equivalent_hours_h  double precision,                       -- perpower_ratio
    installed_kwp       double precision,                       -- installed_capacity
    raw_id              bigint,
    run_id              bigint,
    PRIMARY KEY (device_id, day)
);

-- The station/daily part of the loader.
CREATE OR REPLACE FUNCTION l1.load_huawei_station(p_from timestamptz, p_to timestamptz, p_run bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE n_real bigint; n_period bigint; n_dday bigint;
BEGIN
    CREATE TEMP TABLE _s ON COMMIT DROP AS
    SELECT r.raw_id, r.endpoint, to_timestamp(floor((r.response #>> '{params,collectTime}')::numeric / 1000)) AS req_time,
           e ->> 'stationCode' AS station_code, (e ->> 'devId')::bigint AS dev_id,
           to_timestamp((e ->> 'collectTime')::numeric / 1000) AS item_time, e -> 'dataItemMap' AS m
    FROM raw.api_response r
    CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r.response -> 'data') = 'array' THEN r.response -> 'data' ELSE '[]' END) e
    WHERE r.endpoint IN ('getStationRealKpi', 'getKpiStationHour', 'getKpiStationDay', 'getDevKpiDay') AND r.success
      AND r.fetched_at >= p_from AND r.fetched_at < p_to AND jsonb_typeof(e -> 'dataItemMap') = 'object'
      AND EXISTS (SELECT 1 FROM jsonb_each(e -> 'dataItemMap') kv WHERE kv.value <> 'null'::jsonb);

    INSERT INTO ts.station_real (time, plant_id, energy_day_kwh, energy_month_kwh, energy_total_kwh, grid_feed_day_kwh,
                                 consumption_day_kwh, income_day, income_total, health_state, raw_id, run_id)
    SELECT DISTINCT ON (p.plant_id, s.req_time) s.req_time, p.plant_id, l1.num(m->'day_power'), l1.num(m->'month_power'),
           l1.num(m->'total_power'), l1.num(m->'day_on_grid_energy'), l1.num(m->'day_use_energy'), l1.num(m->'day_income'),
           l1.num(m->'total_income'), l1.num(m->'real_health_state')::smallint, s.raw_id, p_run
    FROM _s s JOIN asset.plant p ON p.code = s.station_code
    WHERE s.endpoint = 'getStationRealKpi' AND s.req_time IS NOT NULL
    ORDER BY p.plant_id, s.req_time, s.raw_id DESC
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n_real = ROW_COUNT;

    INSERT INTO ts.station_period (period, time, plant_id, pv_yield_kwh, inverter_yield_kwh, inverter_energy_kwh, grid_feed_kwh,
                                   consumption_kwh, self_use_kwh, self_provide_kwh, purchase_kwh, charge_kwh, discharge_kwh,
                                   irradiation_kwh_m2, theoretical_kwh, pr_vendor_pct, equivalent_hours_h, installed_kwp, income,
                                   co2_avoided_t, coal_saved_t, trees_planted, raw_id, run_id)
    SELECT DISTINCT ON (per, p.plant_id, s.item_time) per, s.item_time, p.plant_id, l1.num(m->'PVYield'), l1.num(m->'inverterYield'),
           l1.num(m->'inverter_power'), l1.num(m->'ongrid_power'), l1.num(m->'use_power'), l1.num(m->'selfUsePower'),
           l1.num(m->'selfProvide'), l1.num(m->'buyPower'), l1.num(m->'chargeCap'), l1.num(m->'dischargeCap'),
           l1.num(m->'radiation_intensity'), l1.num(m->'theory_power'), l1.num(m->'performance_ratio'), l1.num(m->'perpower_ratio'),
           l1.num(m->'installed_capacity'), l1.num(m->'power_profit'), l1.num(m->'reduction_total_co2'),
           l1.num(m->'reduction_total_coal'), l1.num(m->'reduction_total_tree'), s.raw_id, p_run
    FROM _s s JOIN asset.plant p ON p.code = s.station_code
    CROSS JOIN LATERAL (SELECT CASE s.endpoint WHEN 'getKpiStationHour' THEN 'hour' ELSE 'day' END AS per) x
    WHERE s.endpoint IN ('getKpiStationHour', 'getKpiStationDay') AND s.item_time IS NOT NULL
    ORDER BY per, p.plant_id, s.item_time, s.raw_id DESC
    ON CONFLICT (period, plant_id, time) DO UPDATE SET
        pv_yield_kwh = excluded.pv_yield_kwh, inverter_yield_kwh = excluded.inverter_yield_kwh,
        inverter_energy_kwh = excluded.inverter_energy_kwh, grid_feed_kwh = excluded.grid_feed_kwh,
        consumption_kwh = excluded.consumption_kwh, self_use_kwh = excluded.self_use_kwh, self_provide_kwh = excluded.self_provide_kwh,
        purchase_kwh = excluded.purchase_kwh, charge_kwh = excluded.charge_kwh, discharge_kwh = excluded.discharge_kwh,
        irradiation_kwh_m2 = excluded.irradiation_kwh_m2, theoretical_kwh = excluded.theoretical_kwh,
        pr_vendor_pct = excluded.pr_vendor_pct, equivalent_hours_h = excluded.equivalent_hours_h,
        installed_kwp = excluded.installed_kwp, income = excluded.income, co2_avoided_t = excluded.co2_avoided_t,
        coal_saved_t = excluded.coal_saved_t, trees_planted = excluded.trees_planted, raw_id = excluded.raw_id, run_id = excluded.run_id
    WHERE excluded.raw_id >= ts.station_period.raw_id;
    GET DIAGNOSTICS n_period = ROW_COUNT;

    INSERT INTO ts.device_day (day, device_id, time, energy_kwh, equivalent_hours_h, installed_kwp, raw_id, run_id)
    SELECT DISTINCT ON (d.device_id, day) (s.item_time AT TIME ZONE 'Asia/Bangkok')::date AS day, d.device_id, s.item_time,
           l1.num(m->'product_power'), l1.num(m->'perpower_ratio'), l1.num(m->'installed_capacity'), s.raw_id, p_run
    FROM _s s JOIN asset.device d ON d.vendor = 'huawei' AND d.vendor_device_id = s.dev_id AND upper(d.valid) = 'infinity'
    WHERE s.endpoint = 'getDevKpiDay' AND s.item_time IS NOT NULL
    ORDER BY d.device_id, day, s.raw_id DESC
    ON CONFLICT (device_id, day) DO UPDATE SET
        time = excluded.time, energy_kwh = excluded.energy_kwh, equivalent_hours_h = excluded.equivalent_hours_h,
        installed_kwp = excluded.installed_kwp, raw_id = excluded.raw_id, run_id = excluded.run_id
    WHERE excluded.raw_id >= ts.device_day.raw_id;
    GET DIAGNOSTICS n_dday = ROW_COUNT;

    DROP TABLE _s;
    RETURN jsonb_build_object('station_real', n_real, 'station_period', n_period, 'device_day', n_dday);
END $$;

-- l1.load_huawei = devices (011) + stations/daily (this migration).
ALTER FUNCTION l1.load_huawei(timestamptz, timestamptz, bigint) RENAME TO load_huawei_devices;
CREATE FUNCTION l1.load_huawei(p_from timestamptz, p_to timestamptz, p_run bigint) RETURNS jsonb LANGUAGE sql AS $$
  SELECT l1.load_huawei_devices(p_from, p_to, p_run) || l1.load_huawei_station(p_from, p_to, p_run) $$;
COMMENT ON FUNCTION l1.load_huawei IS 'Module l1_huawei: L0 responses fetched in [from, to) -> ts.* (devices, stations, daily KPIs), idempotent';

UPDATE meta.module SET version = 'v2', outputs = '{ts.inverter_ac,ts.dc_string,ts.irradiance,ts.grid_meter,ts.station_real,ts.station_period,ts.device_day}',
       description = 'L0 -> L1 (SQL): getDevRealKpi, getStationRealKpi, getKpiStationHour/Day, getDevKpiDay. Used when L1_SOURCE=l0'
WHERE name = 'l1_huawei';

-- Station/daily KPIs already in L0 (before this migration).
DO $$
DECLARE rid bigint;
BEGIN
  INSERT INTO calc.run (kind, method, version, params) VALUES ('l1', 'l1_huawei station backfill', 'v2', '{"migration": "017"}')
  RETURNING run_id INTO rid;
  PERFORM l1.load_huawei_station('-infinity', now(), rid);
  UPDATE calc.run SET status = 'ok', finished_at = now() WHERE run_id = rid;
END $$;

-- API
CREATE VIEW api_v1.station_kpi AS
SELECT s.period, s.time, CASE s.period WHEN 'day' THEN (s.time AT TIME ZONE 'Asia/Bangkok')::date END AS day, p.code AS plant_code,
       s.inverter_energy_kwh, s.grid_feed_kwh, s.consumption_kwh, s.irradiation_kwh_m2, s.theoretical_kwh, s.pr_vendor_pct,
       s.equivalent_hours_h, s.installed_kwp, s.income, s.co2_avoided_t, s.pv_yield_kwh, s.inverter_yield_kwh, s.self_use_kwh,
       s.purchase_kwh, s.charge_kwh, s.discharge_kwh
FROM ts.station_period s JOIN asset.plant p USING (plant_id);
COMMENT ON VIEW api_v1.station_kpi IS 'Huawei station KPIs per hour or local day (vendor values, incl. Huawei''s own PR)';

CREATE VIEW api_v1.station_today AS
SELECT DISTINCT ON (p.code) p.code AS plant_code, r.time, r.energy_day_kwh, r.energy_month_kwh, r.energy_total_kwh,
       r.grid_feed_day_kwh, r.consumption_day_kwh, r.health_state
FROM ts.station_real r JOIN asset.plant p USING (plant_id)
WHERE r.time > now() - INTERVAL '2 days'
ORDER BY p.code, r.time DESC;
COMMENT ON VIEW api_v1.station_today IS 'Latest running counters per plant (energy today / month / total, health state)';

CREATE VIEW api_v1.inverter_kpi_daily AS
SELECT p.code AS plant_code, d.device_id AS inverter_id, v.name AS inverter, d.day, d.energy_kwh, d.equivalent_hours_h, d.installed_kwp
FROM ts.device_day d JOIN asset.device v USING (device_id) JOIN asset.plant p ON p.plant_id = v.plant_id;
COMMENT ON VIEW api_v1.inverter_kpi_daily IS 'Huawei daily yield per inverter (vendor value)';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'neo_api') THEN
    GRANT SELECT ON api_v1.station_kpi, api_v1.station_today, api_v1.inverter_kpi_daily TO neo_api;
  END IF;
END $$;
