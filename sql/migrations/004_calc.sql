-- 004 calc (L2): run lineage, service state, PR per interval and per day. Methods live side by side (method + version):
--   iec_61724_1   IEC 61724-1: PR = Yf / Yr; temperature-corrected PR with C_k = 1 + gamma (T_mod - 25 °C)
--   neo_customer  the NEO customer method of PR as-is 0.2 (pr_asis / pr_xze, CK, TCF, EPC), see docs/METHODS.md

CREATE TABLE calc.run (
    run_id              bigserial PRIMARY KEY,
    kind                text NOT NULL,                          -- ingest | intervals | daily | assets
    method              text,
    version             text,
    params              jsonb,
    started_at          timestamptz NOT NULL DEFAULT now(),
    finished_at         timestamptz,
    status              text NOT NULL DEFAULT 'running',        -- running | ok | failed
    rows_written        bigint,
    error               text
);

CREATE TABLE calc.watermark (                                   -- service state per job
    job                 text PRIMARY KEY,
    until_ts            timestamptz NOT NULL,
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- PR per 5-minute interval, at inverter level (inverter_id set) and plant level (inverter_id NULL).
-- An interval STARTS at the sample time; its energy / irradiation is next sample minus this sample (as PR as-is 0.2).
CREATE TABLE calc.pr_interval (
    time                timestamptz NOT NULL,                   -- sample time = interval start
    slot                timestamptz NOT NULL,                   -- 5-minute bucket of time
    interval_s          integer,                                -- real length until the next sample
    plant_id            integer NOT NULL REFERENCES asset.plant,
    inverter_id         integer REFERENCES asset.device,        -- NULL: plant level
    method              text NOT NULL,
    version             text NOT NULL,
    energy_kwh          double precision,                       -- AC energy in the interval (plant: sum of inverters)
    p0_kw               double precision,                       -- STC capacity in scope
    h_meas_kwh_m2       double precision,                       -- measured POA irradiation of the interval (primary EMI)
    h_poa_kwh_m2        double precision,                       -- irradiation used for Yr (customer: h_meas * GlobInc factor)
    yf_h                double precision,                       -- final yield E / P0
    yr_h                double precision,                       -- reference yield H / G_ref
    pr                  double precision,                       -- Yf / Yr (customer: pr_asis)
    module_temp_c       double precision,                       -- measured module temperature (primary EMI)
    -- IEC temperature correction
    c_k                 double precision,                       -- 1 + gamma (T_mod - 25) / 100
    pr_temp_corrected   double precision,                       -- PR / C_k
    -- customer filter (xze = exclude zero export) and temperature factors
    grid_connected      boolean,                                -- all primary inverters state 512 in previous, this and next slot
    power_limited       boolean,                                -- any primary inverter state 513 in this slot
    grid_import         boolean,                                -- grid-meter forward energy (next - this) > 0
    meter_power_kw      double precision,
    ipz_threshold_kw    double precision,                       -- import power zero of the previous month
    included            boolean,                                -- criteria_filtered_2: counts for pr_xze
    exclusion_reason    text,                                   -- not_grid_connected | grid_import | zero_export_limit
    energy_xze_kwh      double precision,
    h_xze_kwh_m2        double precision,
    pr_xze              double precision,
    tmod_c              double precision,                       -- module temperature, 0 when the interval is excluded
    ck                  double precision,                       -- 1 + gamma (T_mod - T_ref,month) / 100
    tcf                 double precision,                       -- (1 + gamma (T_ref - 25)/100) / (1 + gamma (T_mod - 25)/100)
    pr_ck               double precision,                       -- pr_actual_ck  = pr_xze / CK
    pr_tcf              double precision,                       -- pr_actual_tcf = pr_xze * TCF
    run_id              bigint NOT NULL REFERENCES calc.run
);
SELECT create_hypertable('calc.pr_interval', by_range('time', INTERVAL '7 days'));
CREATE UNIQUE INDEX pr_interval_key ON calc.pr_interval (method, version, plant_id, inverter_id, time) NULLS NOT DISTINCT;
CREATE INDEX ON calc.pr_interval (plant_id, slot);

-- PR per local day (Asia/Bangkok) at plant, inverter and string level.
CREATE TABLE calc.pr_daily (
    day                 date NOT NULL,
    level               text NOT NULL CHECK (level IN ('plant', 'inverter', 'string')),
    plant_id            integer NOT NULL REFERENCES asset.plant,
    inverter_id         integer REFERENCES asset.device,
    string_id           integer REFERENCES asset.pv_string,
    method              text NOT NULL,
    version             text NOT NULL,
    energy_kwh          double precision,                       -- AC (plant, inverter) or DC (string)
    p0_kw               double precision,
    h_poa_kwh_m2        double precision,
    pr                  double precision,                       -- customer: pr_asis
    pr_temp_corrected   double precision,                       -- IEC: sum(Yf) / sum(Yr * C_k)
    tmod_c              double precision,                       -- customer: irradiance-weighted module temperature
    energy_xze_kwh      double precision,
    h_xze_kwh_m2        double precision,
    pr_xze              double precision,
    ck                  double precision,
    tcf                 double precision,
    pr_ck               double precision,
    pr_tcf              double precision,
    pr_epc_ck           double precision,                       -- pr_ck / (degrade_cap % * availability % / 10 000)
    pr_epc_tcf          double precision,
    daylight_h          double precision,                       -- slots with irradiation / 12
    ze_h                double precision,                       -- daylight hours excluded by the xze filter
    intervals           integer,
    run_id              bigint NOT NULL REFERENCES calc.run
);
CREATE UNIQUE INDEX pr_daily_key ON calc.pr_daily (method, version, level, plant_id, inverter_id, string_id, day) NULLS NOT DISTINCT;
CREATE INDEX ON calc.pr_daily (day, plant_id);
