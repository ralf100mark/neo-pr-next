-- 003 raw (L0) and ts (L1).

-- L0: every API response as received. Replayable: L1 can be rebuilt after a parser fix or an unannounced Huawei API change.
-- Planned writer: the Huawei consumer (replacing the Mongo cache). Not written by neo-model v2.
CREATE TABLE raw.api_response (
    fetched_at          timestamptz NOT NULL,
    source              text NOT NULL,                          -- huawei
    account             text NOT NULL,
    endpoint            text NOT NULL,                          -- /thirdData/getDevRealKpi …
    request             jsonb,
    response            jsonb NOT NULL,
    fail_code           integer,
    run_id              bigint
);
SELECT create_hypertable('raw.api_response', by_range('fetched_at', INTERVAL '1 day'));

-- L1. Source mapping (Huawei northbound API → column) is documented in docs/MODEL.md.
CREATE TABLE ts.inverter_ac (
    time                timestamptz NOT NULL,
    device_id           integer NOT NULL REFERENCES asset.device,
    active_power_kw     double precision,                       -- active_power
    reactive_power_kvar double precision,                       -- reactive_power
    power_factor        double precision,
    frequency_hz        double precision,                       -- elec_freq
    u_ab_v double precision, u_bc_v double precision, u_ca_v double precision,
    i_a_a double precision,  i_b_a double precision,  i_c_a double precision,
    energy_day_kwh      double precision,                       -- day_cap (cumulative, resets at local midnight)
    energy_total_kwh    double precision,                       -- total_cap
    dc_power_kw         double precision,                       -- mppt_power
    temperature_c       double precision,                       -- inverter internal temperature
    efficiency_pct      double precision,
    state               integer,                                -- inverter_state: 512 grid-connected, 513 power limited
    quality             smallint NOT NULL DEFAULT 0,            -- 0 ok; bit flags for suspect values (reserved)
    run_id              bigint,
    PRIMARY KEY (device_id, time)
);
SELECT create_hypertable('ts.inverter_ac', by_range('time', INTERVAL '7 days'));

CREATE TABLE ts.dc_string (
    time                timestamptz NOT NULL,
    string_id           integer NOT NULL REFERENCES asset.pv_string,
    voltage_v           double precision,                       -- pv<N>_u
    current_a           double precision,                       -- pv<N>_i
    power_w             double precision GENERATED ALWAYS AS (voltage_v * current_a) STORED,
    quality             smallint NOT NULL DEFAULT 0,
    run_id              bigint,
    PRIMARY KEY (string_id, time)
);
SELECT create_hypertable('ts.dc_string', by_range('time', INTERVAL '7 days'));

CREATE TABLE ts.irradiance (
    time                timestamptz NOT NULL,
    device_id           integer NOT NULL REFERENCES asset.device,
    poa_w_m2            double precision,                       -- radiant_line (plane of array)
    poa_total_kwh_m2    double precision,                       -- radiant_total (MJ/m², cumulative per day) / 3.6
    ghi_w_m2            double precision,                       -- horiz_radiant_line
    ghi_total_kwh_m2    double precision,                       -- horiz_radiant_total / 3.6
    module_temp_c       double precision,                       -- pv_temperature
    ambient_temp_c      double precision,                       -- temperature
    wind_speed_m_s      double precision,
    wind_direction_deg  double precision,
    quality             smallint NOT NULL DEFAULT 0,
    run_id              bigint,
    PRIMARY KEY (device_id, time)
);
SELECT create_hypertable('ts.irradiance', by_range('time', INTERVAL '7 days'));

CREATE TABLE ts.grid_meter (
    time                timestamptz NOT NULL,
    device_id           integer NOT NULL REFERENCES asset.device,
    active_power_kw     double precision,                       -- active_power (Huawei: W) / 1000; negative = export
    reactive_power_kvar double precision,                       -- reactive_power (var) / 1000
    power_factor        double precision,
    frequency_hz        double precision,                       -- grid_frequency
    energy_forward_kwh  double precision,                       -- active_cap (cumulative): energy drawn from the grid
    energy_reverse_kwh  double precision,                       -- reverse_active_cap (cumulative): energy fed to the grid
    quality             smallint NOT NULL DEFAULT 0,
    run_id              bigint,
    PRIMARY KEY (device_id, time)
);
SELECT create_hypertable('ts.grid_meter', by_range('time', INTERVAL '7 days'));
