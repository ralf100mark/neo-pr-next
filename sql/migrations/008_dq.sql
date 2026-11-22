-- 008 dq: data quality. Findings that need a human (master-data fixes), as views over the model.

CREATE TABLE dq.unknown_sensor (                                -- written by the service: sensorIds in the source without a device
    vendor              text NOT NULL DEFAULT 'huawei',
    vendor_device_id    bigint NOT NULL,
    measurement         text NOT NULL,                          -- e.g. GetDevRealKpi_1
    station_code        text,
    first_seen          timestamptz NOT NULL DEFAULT now(),
    last_seen           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (vendor, vendor_device_id, measurement)
);

-- Plants whose recorded capacity disagrees with the string configuration or the measured peak power.
CREATE VIEW dq.plant_capacity AS
SELECT p.code, p.name, p.capacity_dc_kwp AS recorded_kwp,
       pp.string_cap_w / 1000.0 AS customer_param_kwp,
       (SELECT sum(c.p0_kw) FROM asset.inverter_capacity c JOIN asset.device d ON d.device_id = c.inverter_id
         WHERE d.plant_id = p.plant_id) AS strings_kwp,
       (SELECT max(x.p) FROM (SELECT sum(r.active_power_kw) AS p FROM rpt.plant_power_5min r JOIN asset.device d USING (device_id)
                               WHERE d.plant_id = p.plant_id GROUP BY r.slot) x) AS measured_peak_kw,
       p.latitude IS NULL OR p.longitude IS NULL AS missing_coordinates,
       p.capacity_dc_kwp IS NULL AS missing_capacity,
       p.pr_active
FROM asset.plant p LEFT JOIN asset.plant_pr_param pp USING (plant_id);
COMMENT ON VIEW dq.plant_capacity IS 'Compare: recorded kWp vs. string configuration vs. measured peak (peak > configured kWp is a red flag)';

-- Strings: configured but dead, delivering current but not configured, disabled.
CREATE VIEW dq.string_config AS
WITH m AS (SELECT string_id, max(current_a) AS max_current_a, count(*) AS samples
           FROM ts.dc_string WHERE time > now() - INTERVAL '7 days' GROUP BY 1)
SELECT p.code AS plant_code, v.name AS inverter, s.string_no, s.configured, s.enabled, s.stc_capacity_w, m.max_current_a, m.samples,
       CASE WHEN s.configured AND s.enabled AND coalesce(m.max_current_a, 0) < 1 THEN 'configured_but_no_current'
            WHEN NOT s.configured THEN 'current_but_not_configured'
            WHEN NOT s.enabled THEN 'disabled'
            ELSE 'ok' END AS finding,
       s.string_id, v.device_id AS inverter_id, p.plant_id
FROM asset.pv_string s
JOIN asset.device v ON v.device_id = s.inverter_id
JOIN asset.plant p ON p.plant_id = v.plant_id
LEFT JOIN m USING (string_id)
WHERE upper(s.valid) = 'infinity';

-- Devices without data in the last day (only devices that ever delivered data).
CREATE VIEW dq.silent_device AS
SELECT p.code AS plant_code, d.name, d.kind, d.vendor_device_id, last.t AS last_sample
FROM asset.device d JOIN asset.plant p USING (plant_id)
CROSS JOIN LATERAL (SELECT CASE d.kind
        WHEN 'inverter' THEN (SELECT max(time) FROM ts.inverter_ac a WHERE a.device_id = d.device_id AND a.time > now() - INTERVAL '30 days')
        WHEN 'irradiance_sensor' THEN (SELECT max(time) FROM ts.irradiance i WHERE i.device_id = d.device_id AND i.time > now() - INTERVAL '30 days')
        WHEN 'grid_meter' THEN (SELECT max(time) FROM ts.grid_meter g WHERE g.device_id = d.device_id AND g.time > now() - INTERVAL '30 days')
        END AS t) last
WHERE upper(d.valid) = 'infinity' AND last.t IS NOT NULL AND last.t < now() - INTERVAL '1 day';

-- Plants that cannot get a customer PR (and why).
CREATE VIEW dq.pr_prerequisites AS
SELECT p.code, p.name, p.pr_active,
       (SELECT count(*) FROM asset.device d WHERE d.plant_id = p.plant_id AND d.kind = 'irradiance_sensor' AND d.is_primary) AS primary_emi,
       (SELECT count(*) FROM asset.device d WHERE d.plant_id = p.plant_id AND d.kind = 'grid_meter' AND d.is_primary) AS primary_meter,
       EXISTS (SELECT 1 FROM asset.plant_month_factor m WHERE m.plant_id = p.plant_id AND m.month = date_trunc('month', now())::date) AS month_factor_now,
       EXISTS (SELECT 1 FROM asset.plant_import_power i WHERE i.plant_id = p.plant_id
                 AND i.month = (date_trunc('month', now()) - INTERVAL '1 month')::date) AS ipz_previous_month,
       (SELECT pp.string_cap_w FROM asset.plant_pr_param pp WHERE pp.plant_id = p.plant_id) IS NOT NULL AS plant_pr_param
FROM asset.plant p;
