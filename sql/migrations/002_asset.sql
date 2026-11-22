-- 002 asset: the physical plant model. Configuration rows carry a validity range (valid, tstzrange): a changed string
-- configuration closes the current row (upper = change time) and opens a new one, so every calculation can use the
-- configuration that was valid at that time. Current rows have upper(valid) = 'infinity'.

CREATE TABLE asset.plant (
    plant_id            serial PRIMARY KEY,
    code                text NOT NULL UNIQUE,                   -- Huawei stationCode, e.g. NE=52346167
    name                text NOT NULL,
    account             text,                                   -- Huawei account key (neo, kangwal)
    latitude            double precision,
    longitude           double precision,
    timezone            text NOT NULL DEFAULT 'Asia/Bangkok',
    capacity_dc_kwp     double precision,                       -- as recorded for the plant (contract value)
    cod_date            date,                                   -- commercial operation / TOC date
    guarantee_years     integer,
    g_ref_w_m2          double precision NOT NULL DEFAULT 1000, -- IEC 61724-1 reference irradiance
    pr_active           boolean NOT NULL DEFAULT false,         -- calculate PR for this plant
    source              text NOT NULL                           -- lineage: where the row came from
);
COMMENT ON TABLE asset.plant IS 'One PV plant (Huawei station)';

CREATE TABLE asset.plant_pr_param (                             -- plant-level parameters of the customer PR method
    plant_id            integer PRIMARY KEY REFERENCES asset.plant,
    string_cap_w        double precision,                       -- pi_plant_string_cap: P0 used by the customer plant PR
    panels              double precision,                       -- pi_plant_panel
    globinc_pct         double precision,                       -- pi_plant_globinc_pcnt (e.g. 97.03 = factor 0.9703)
    temp_coeff_pct_per_c double precision,                      -- pi_plant_temp_co_efficiency (gamma, negative)
    source              text NOT NULL
);

CREATE TYPE asset.device_kind AS ENUM ('inverter', 'irradiance_sensor', 'grid_meter', 'logger');

CREATE TABLE asset.device (
    device_id           serial PRIMARY KEY,
    plant_id            integer NOT NULL REFERENCES asset.plant,
    kind                asset.device_kind NOT NULL,
    vendor              text NOT NULL DEFAULT 'huawei',
    vendor_device_id    bigint NOT NULL,                        -- Huawei devId (= Influx tag sensorId)
    serial_no           text,                                   -- ESN
    name                text,
    model               text,
    is_primary          boolean NOT NULL DEFAULT false,         -- the device PR uses (one EMI and one grid meter per plant)
    valid               tstzrange NOT NULL DEFAULT tstzrange('-infinity', 'infinity'),
    source              text NOT NULL,
    EXCLUDE USING gist (vendor WITH =, vendor_device_id WITH =, valid WITH &&)
);
CREATE INDEX ON asset.device (plant_id, kind);

CREATE TABLE asset.inverter_pr_param (                          -- inverter-level parameters of the customer daily PR
    device_id           integer PRIMARY KEY REFERENCES asset.device,
    string_cap_w        double precision,                       -- ii_string_cap
    panels              double precision,                       -- ii_panel
    module_wp           double precision,                       -- ii_cap_wp
    globinc_pct         double precision,                       -- ii_glob_inc_pcnt
    temp_coeff_pct_per_c double precision,                      -- ii_temp_co_efficiency (used by CK/TCF)
    g_ref_w_m2          double precision,                       -- ii_gi_ref
    source              text NOT NULL
);

CREATE TABLE asset.module_type (
    module_type_id      serial PRIMARY KEY,
    pmax_stc_w          double precision NOT NULL,              -- module nameplate at STC
    gamma_pct_per_c     double precision NOT NULL,              -- power temperature coefficient (negative)
    noct_c              double precision,                       -- for thermal models (not known today)
    area_m2             double precision,
    manufacturer        text,
    model               text,
    description         text NOT NULL DEFAULT '',
    UNIQUE (pmax_stc_w, gamma_pct_per_c, description)
);

CREATE TABLE asset.pv_string (
    string_id           serial PRIMARY KEY,
    inverter_id         integer NOT NULL REFERENCES asset.device,
    string_no           smallint NOT NULL,                      -- Huawei pv<N>
    mppt_no             smallint,                               -- not known today
    module_type_id      integer REFERENCES asset.module_type,
    modules_count       double precision,
    stc_capacity_w      double precision,                       -- P0 of this string
    poa_factor          double precision,                       -- GlobInc correction as a factor (ic_glob_inc_pcnt / 100); NULL = 1
    tilt_deg            double precision,                       -- not known today (needed for a transposition model)
    azimuth_deg         double precision,
    enabled             boolean NOT NULL DEFAULT true,
    configured          boolean NOT NULL DEFAULT true,          -- false: delivers current but has no configuration
    valid               tstzrange NOT NULL DEFAULT tstzrange('-infinity', 'infinity'),
    source              text NOT NULL,
    EXCLUDE USING gist (inverter_id WITH =, string_no WITH =, valid WITH &&)
);
CREATE INDEX ON asset.pv_string (inverter_id) WHERE upper(valid) = 'infinity';

CREATE TABLE asset.plant_month_factor (                         -- PVsyst / contract values per month
    plant_id            integer NOT NULL REFERENCES asset.plant,
    month               date NOT NULL,                          -- first day of the month
    temp_ref_c          double precision,                       -- reference module temperature (customer CK/TCF)
    degradation_pct     double precision,
    degrade_cap_pct     double precision,                       -- used by the EPC PR
    warranty_pct        double precision,
    availability_pct    double precision,                       -- contracted system availability (EPC PR)
    PRIMARY KEY (plant_id, month)
);

CREATE TABLE asset.plant_import_power (                         -- monthly "import power zero" threshold (customer xze filter)
    plant_id            integer NOT NULL REFERENCES asset.plant,
    month               date NOT NULL,                          -- first day of the month the value describes
    value_kw            double precision NOT NULL,              -- mean grid-meter power while power-limited (negative = export)
    method              text,                                   -- AVG
    static              boolean NOT NULL DEFAULT false,         -- true: set by hand, not recalculated
    PRIMARY KEY (plant_id, month)
);
COMMENT ON TABLE asset.plant_import_power IS 'The xze filter of month M uses the value of month M-1 (as PR as-is 0.2)';

CREATE TABLE asset.pvsyst_reference (                           -- PVsyst monthly reference temperature
    plant_id            integer NOT NULL REFERENCES asset.plant,
    month_no            smallint NOT NULL CHECK (month_no BETWEEN 1 AND 12),
    temperature_c       double precision,
    PRIMARY KEY (plant_id, month_no)
);

-- Current configuration (convenience).
CREATE VIEW asset.pv_string_current AS
SELECT * FROM asset.pv_string WHERE upper(valid) = 'infinity';

CREATE VIEW asset.inverter_capacity AS
SELECT s.inverter_id,
       sum(s.stc_capacity_w) / 1000.0                                         AS p0_kw,
       sum(s.modules_count * coalesce(s.poa_factor, 1)) / nullif(sum(s.modules_count), 0) AS poa_factor,
       sum(s.stc_capacity_w * m.gamma_pct_per_c) / nullif(sum(s.stc_capacity_w), 0)       AS gamma_pct_per_c,
       count(*)                                                                AS strings
FROM asset.pv_string s LEFT JOIN asset.module_type m USING (module_type_id)
WHERE s.configured AND s.enabled AND upper(s.valid) = 'infinity'
GROUP BY 1;
COMMENT ON VIEW asset.inverter_capacity IS 'P0, panel-weighted GlobInc factor and capacity-weighted gamma per inverter (current configuration)';
