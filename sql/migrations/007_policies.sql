-- 007 Timescale policies: compression and continuous-aggregate refresh.
-- L1 compresses after 7 days (recent chunks stay writable for late data), L2 after 14, L0 after 3.

ALTER TABLE ts.inverter_ac SET (timescaledb.compress, timescaledb.compress_segmentby = 'device_id', timescaledb.compress_orderby = 'time');
ALTER TABLE ts.dc_string   SET (timescaledb.compress, timescaledb.compress_segmentby = 'string_id', timescaledb.compress_orderby = 'time');
ALTER TABLE ts.irradiance  SET (timescaledb.compress, timescaledb.compress_segmentby = 'device_id', timescaledb.compress_orderby = 'time');
ALTER TABLE ts.grid_meter  SET (timescaledb.compress, timescaledb.compress_segmentby = 'device_id', timescaledb.compress_orderby = 'time');
ALTER TABLE calc.pr_interval SET (timescaledb.compress,
      timescaledb.compress_segmentby = 'method, version, plant_id, inverter_id', timescaledb.compress_orderby = 'time');
ALTER TABLE raw.api_response SET (timescaledb.compress, timescaledb.compress_segmentby = 'endpoint', timescaledb.compress_orderby = 'fetched_at');

SELECT add_compression_policy('ts.inverter_ac', INTERVAL '7 days');
SELECT add_compression_policy('ts.dc_string',   INTERVAL '7 days');
SELECT add_compression_policy('ts.irradiance',  INTERVAL '7 days');
SELECT add_compression_policy('ts.grid_meter',  INTERVAL '7 days');
SELECT add_compression_policy('calc.pr_interval', INTERVAL '14 days');
SELECT add_compression_policy('raw.api_response', INTERVAL '3 days');

SELECT add_continuous_aggregate_policy('rpt.inverter_energy_daily', start_offset => INTERVAL '3 days', end_offset => INTERVAL '5 minutes',
                                       schedule_interval => INTERVAL '15 minutes');
SELECT add_continuous_aggregate_policy('rpt.string_daily', start_offset => INTERVAL '3 days', end_offset => INTERVAL '5 minutes',
                                       schedule_interval => INTERVAL '15 minutes');
SELECT add_continuous_aggregate_policy('rpt.irradiation_daily', start_offset => INTERVAL '3 days', end_offset => INTERVAL '5 minutes',
                                       schedule_interval => INTERVAL '15 minutes');
SELECT add_continuous_aggregate_policy('rpt.plant_power_5min', start_offset => INTERVAL '1 day', end_offset => INTERVAL '5 minutes',
                                       schedule_interval => INTERVAL '5 minutes');
