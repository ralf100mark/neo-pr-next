-- 001 base: extensions, schemas, migration bookkeeping.
-- Layers: asset (physical model) | raw (L0 API as received) | ts (L1 measured) | calc (L2 derived) | rpt (L3 reporting)
--         | dq (data quality) | compat (old field names for the transition) | meta (schema bookkeeping).
-- Conventions: units are part of every measured/derived column name (_kw, _kwh, _w, _v, _a, _w_m2, _kwh_m2, _c, _pct, _hz, _h);
-- all timestamps are timestamptz (UTC stored); local days are Asia/Bangkok.

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS btree_gist;          -- exclusion constraints on validity ranges

CREATE SCHEMA IF NOT EXISTS meta;
CREATE SCHEMA IF NOT EXISTS asset;
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS ts;
CREATE SCHEMA IF NOT EXISTS calc;
CREATE SCHEMA IF NOT EXISTS rpt;
CREATE SCHEMA IF NOT EXISTS dq;
CREATE SCHEMA IF NOT EXISTS compat;

CREATE TABLE IF NOT EXISTS meta.schema_migration (
    version         text PRIMARY KEY,               -- file name without .sql, e.g. 001_base
    applied_at      timestamptz NOT NULL DEFAULT now(),
    checksum        text NOT NULL                   -- sha256 of the file at apply time
);

COMMENT ON SCHEMA asset  IS 'Physical model of the plants: plant, device, string, module type, configuration valid over time';
COMMENT ON SCHEMA raw    IS 'L0: API responses as received (replayable)';
COMMENT ON SCHEMA ts     IS 'L1: measured values, typed, with units, referenced to the asset model';
COMMENT ON SCHEMA calc   IS 'L2: derived values (PR etc.), each row with method + version + run';
COMMENT ON SCHEMA rpt    IS 'L3: aggregates and views for reporting and the dashboard app';
COMMENT ON SCHEMA dq     IS 'Data quality: master-data contradictions, unknown sensors, gaps';
COMMENT ON SCHEMA compat IS 'Views with the old Influx field names (PR as-is 0.2) for the transition';
