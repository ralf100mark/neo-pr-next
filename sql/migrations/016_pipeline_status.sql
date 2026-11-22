-- 016 the registry states the active L1 source (l1_huawei since 2026-11-22; l1_influx is the fallback, L1_SOURCE=influx), and
-- api_v1.pipeline_status reports only the enabled L1 module's watermark (calc.watermark job 'ingest' = module l1_influx).

UPDATE meta.module SET enabled = false WHERE name = 'l1_influx';

DROP VIEW api_v1.pipeline_status;
CREATE VIEW api_v1.pipeline_status AS
SELECT m.name AS module, w.until_ts AS loaded_until, now() - w.until_ts AS lag,
       (SELECT max(finished_at) FROM calc.run r WHERE r.status = 'ok') AS last_ok_run,
       (SELECT count(*) FROM calc.run r WHERE r.status = 'failed' AND r.started_at > now() - INTERVAL '1 day') AS failed_runs_24h,
       (SELECT count(*) FROM meta.dirty_window) AS dirty_windows
FROM calc.watermark w
JOIN meta.module m ON m.name = CASE w.job WHEN 'ingest' THEN 'l1_influx' ELSE w.job END AND m.enabled;
COMMENT ON VIEW api_v1.pipeline_status IS 'Freshness of the pipeline (for a status badge in the app): the active L1 module''s lag';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'neo_api') THEN
    GRANT SELECT ON api_v1.pipeline_status TO neo_api;
  END IF;
END $$;
