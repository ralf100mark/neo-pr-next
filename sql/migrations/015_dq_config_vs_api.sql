-- 015 dq: devices of the configuration (asset.device, from the PR configuration) that the vendor API no longer delivers,
-- with the device that probably replaced them (same plant and type, same name or serial number). Found 2026-11-22:
-- NE=78142560 (PRC) is configured with EMI 1000000078252784 and meter 1000000078142594; the API delivers the same EMI under
-- 1000000100508270 and a new meter 1000000100484292, so the plant gets no PR at all. Also: publish IEC v3 (migration 014).

CREATE VIEW dq.config_device_missing AS
WITH kind_type(kind, dev_type_id) AS (VALUES ('inverter', 1), ('irradiance_sensor', 10), ('grid_meter', 17), ('logger', 63))
SELECT p.code AS plant_code, p.pr_active, d.kind::text AS kind, d.name, d.vendor_device_id AS configured_dev_id, d.is_primary,
       c.dev_id AS api_candidate_dev_id, c.name AS api_candidate_name, c.esn AS api_candidate_esn,
       CASE WHEN c.dev_id IS NULL THEN 'not delivered, no candidate'
            WHEN c.name = d.name THEN 'same name, new devId'
            ELSE 'same type, other device' END AS finding
FROM asset.device d
JOIN asset.plant p USING (plant_id)
JOIN kind_type kt ON kt.kind = d.kind::text
LEFT JOIN LATERAL (
    SELECT s.dev_id, s.name, s.esn FROM src.device s
    WHERE s.active AND s.station_code = p.code AND s.dev_type_id = kt.dev_type_id
      AND NOT EXISTS (SELECT 1 FROM asset.device x WHERE x.vendor_device_id = s.dev_id AND upper(x.valid) = 'infinity')
    ORDER BY (s.name = d.name) DESC, (s.esn = d.serial_no) DESC, s.dev_id
    LIMIT 1) c ON true
WHERE upper(d.valid) = 'infinity'
  AND EXISTS (SELECT 1 FROM src.station st WHERE st.station_code = p.code AND st.active)          -- the API delivers the plant
  AND NOT EXISTS (SELECT 1 FROM src.device s WHERE s.dev_id = d.vendor_device_id AND s.active);
COMMENT ON VIEW dq.config_device_missing IS 'Configured devices the API no longer delivers, with the likely replacement (fix the PR configuration)';

CREATE VIEW api_v1.dq_config_device_missing AS SELECT * FROM dq.config_device_missing;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'neo_api') THEN
    GRANT SELECT ON api_v1.dq_config_device_missing TO neo_api;
  END IF;
END $$;

UPDATE meta.api_published SET version = 'v3', since = now(), note = 'period PR = sum Yf / sum Yr over all intervals (014)'
WHERE method = 'iec_61724_1';
