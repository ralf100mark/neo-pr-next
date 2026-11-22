-- 010 L0 and src: the Huawei consumer lands every API response unchanged (JSONB, 31 days) and keeps the master data and its
-- operating state here. This replaces the consumer's MongoDB (docs/PIPELINE.md §2.1). Writer: the consumer (role neo_ingest).

-- raw.api_response from 003 never had a writer (empty): rebuilt in its final shape.
DROP TABLE raw.api_response;
CREATE TABLE raw.api_response (
    raw_id       bigint GENERATED ALWAYS AS IDENTITY,
    fetched_at   timestamptz NOT NULL DEFAULT now(),        -- when the response arrived
    source       text NOT NULL DEFAULT 'huawei',
    account      text NOT NULL,                             -- API user (quota owner)
    endpoint     text NOT NULL,                             -- e.g. getDevRealKpi
    dev_type_id  smallint,                                  -- 1 inverter, 10 EMI, 17 meter … (request devTypeId)
    collect_time timestamptz,                               -- request collectTime (the time the data is for)
    request      jsonb NOT NULL,                            -- request body as sent
    http_status  smallint NOT NULL,
    fail_code    integer,                                   -- Huawei failCode (0 ok, 305 token, 407 quota)
    success      boolean,
    response     jsonb,                                     -- body as received (NULL if not JSON, then response_text)
    response_text text,
    elapsed_ms   integer,
    job          text,                                      -- scheduler job, if known
    PRIMARY KEY (raw_id, fetched_at)
);
SELECT create_hypertable('raw.api_response', by_range('fetched_at', INTERVAL '1 day'));
CREATE INDEX ON raw.api_response (endpoint, fetched_at DESC);
ALTER TABLE raw.api_response SET (timescaledb.compress, timescaledb.compress_segmentby = 'endpoint',
                                  timescaledb.compress_orderby = 'fetched_at, raw_id');
SELECT add_compression_policy('raw.api_response', INTERVAL '3 days');
SELECT add_retention_policy('raw.api_response', INTERVAL '31 days');
COMMENT ON TABLE raw.api_response IS 'L0: every vendor API response unchanged, 31 days (replaces the Mongo cache)';

CREATE SCHEMA IF NOT EXISTS src;
COMMENT ON SCHEMA src IS 'Master data and operating state as the vendor API delivers them (written by the consumer)';

CREATE TABLE src.station (                                  -- Huawei getStationList / stations
    source       text NOT NULL DEFAULT 'huawei',
    station_code text NOT NULL,                             -- plantCode, e.g. NE=51345970
    account      text NOT NULL,
    name         text,
    doc          jsonb NOT NULL,                            -- the API document (+ account), as the consumer used it in Mongo
    active       boolean NOT NULL DEFAULT true,             -- false: not in the account's last full sync
    first_seen   timestamptz NOT NULL DEFAULT now(),
    last_seen    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, station_code, account)
);

CREATE TABLE src.device (                                   -- Huawei getDevList
    source       text NOT NULL DEFAULT 'huawei',
    dev_id       bigint NOT NULL,                           -- devId = sensorId in Influx
    account      text NOT NULL,
    dev_type_id  smallint,
    station_code text,
    name         text,
    esn          text,
    doc          jsonb NOT NULL,
    active       boolean NOT NULL DEFAULT true,
    first_seen   timestamptz NOT NULL DEFAULT now(),
    last_seen    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, dev_id, account)
);
CREATE INDEX ON src.device (account, dev_type_id) WHERE active;

CREATE TABLE src.sync_state (                               -- was talegur.lastSensorValueUpdate: last value per sensor
    source       text NOT NULL DEFAULT 'huawei',
    sensor_id    bigint NOT NULL,                           -- devId, or the numeric part of the station code
    kind         text NOT NULL,                             -- device_real, station_real, station_hour
    last_value   jsonb NOT NULL,
    saved_at     text,
    updated_at   timestamptz NOT NULL,
    PRIMARY KEY (source, sensor_id, kind)
);

CREATE TABLE src.alarm_notification (                       -- was Mongo NotificationHistory
    station_code  text NOT NULL,
    alarm_id      text NOT NULL,
    last_notified timestamptz NOT NULL,
    dev_names     text[] NOT NULL,
    PRIMARY KEY (station_code, alarm_id)
);

-- The consumer's role (created outside the migrations, docs/OPERATIONS.md): append L0, maintain src.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'neo_ingest') THEN
    GRANT USAGE ON SCHEMA raw, src TO neo_ingest;
    GRANT INSERT ON raw.api_response TO neo_ingest;
    GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA src TO neo_ingest;
  END IF;
END $$;
