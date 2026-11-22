"""NEO data model service: keeps the Timescale model (database PG_DB) current. Specification: docs/OPERATIONS.md.

Every CYCLE_S seconds (at OFFSET_S after the 5-minute boundary):
  1. assets     sync from the PR configuration database (PG_ASSET_DB) at start and every ASSET_SYNC_H hours; a changed
                string configuration closes the current asset.pv_string row and opens a new one (validity ranges)
  2. ingest     L1 from InfluxDB (INFLUX_DB): inverter AC + DC strings, irradiance, grid meter, since the watermark
  3. intervals  L2 calc.compute_intervals() for the last PR_LOOKBACK_H hours (iec_61724_1 + neo_customer)
  4. daily      L2 calc.compute_daily() for today and yesterday (local days)

First start (no watermark): backfill BACKFILL_DAYS days, or BACKFILL_FROM..BACKFILL_TO (ISO dates) if set.
Reads only PG_ASSET_DB and InfluxDB; writes only PG_DB. A failed cycle is logged; the next one runs normally.
"""

import io
import json
import logging
import os
import re
import signal
import sys
import time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import psycopg2
import requests

LOG = logging.getLogger("neo_model")
VERSION = os.environ.get("CALC_VERSION", "v2")
LOCAL_TZ = ZoneInfo("Asia/Bangkok")
KIND = {1: "inverter", 10: "irradiance_sensor", 17: "grid_meter", 63: "logger"}
STRING_MIN_A = 1.0          # an unconfigured input becomes an (observed) string only above this current
STOP = False


def env(name, default=None, cast=str):
    v = os.environ.get(name, default)
    if v is None:
        sys.exit(f"missing environment variable {name}")
    return cast(v)


CFG = dict(
    pg=dict(host=env("PG_HOST"), port=env("PG_PORT", "5432"), user=env("PG_USER"), password=env("PG_PASSWORD")),
    db=env("PG_DB", "neo_model"), asset_db=env("PG_ASSET_DB", "pr_live_neodb"),
    influx_url=f"http://{env('INFLUX_HOST')}:{env('INFLUX_PORT', '8086')}/query",
    influx_auth=(env("INFLUX_USER"), env("INFLUX_PASSWORD")), influx_db=env("INFLUX_DB", "NEO_LIVE"),
    cycle_s=env("CYCLE_S", "300", int), offset_s=env("OFFSET_S", "90", int),
    lookback_h=env("PR_LOOKBACK_H", "3", float), backfill_days=env("BACKFILL_DAYS", "30", int),
    backfill_from=os.environ.get("BACKFILL_FROM"), backfill_to=os.environ.get("BACKFILL_TO"),
    asset_sync_h=env("ASSET_SYNC_H", "6", float), overlap_min=env("INGEST_OVERLAP_MIN", "30", int),
)


def pg(db):
    c = psycopg2.connect(dbname=db, connect_timeout=10, application_name="neo-model", **CFG["pg"])
    c.autocommit = False
    return c


def start_run(cur, kind, method, params):
    cur.execute("insert into calc.run (kind, method, version, params) values (%s,%s,%s,%s) returning run_id",
                (kind, method, VERSION, json.dumps(params, default=str)))
    return cur.fetchone()[0]


def end_run(cur, run_id, rows):
    cur.execute("update calc.run set finished_at=now(), status='ok', rows_written=%s where run_id=%s", (rows, run_id))


# ----------------------------------------------------------------------------------------------- 1. assets

STRING_FIELDS = ("module_type_id", "modules_count", "stc_capacity_w", "poa_factor", "enabled")


def sync_assets():
    src, dst = pg(CFG["asset_db"]), pg(CFG["db"])
    s, d = src.cursor(), dst.cursor()
    run_id = start_run(d, "assets", "sync", {"source": CFG["asset_db"]})
    changes = 0

    s.execute("""select pi_code, pi_name, pi_account, nullif(pi_latitude,'')::float, nullif(pi_longitude,'')::float, pi_capacity,
                        pi_toc_date, pi_guarantee_years, coalesce(pi_gi_ref, 1000), coalesce(pi_pr_calculate_active, false),
                        pi_plant_string_cap, pi_plant_panel, pi_plant_globinc_pcnt, pi_plant_temp_co_efficiency
                 from plant_information""")
    for r in s.fetchall():
        d.execute("""insert into asset.plant (code, name, account, latitude, longitude, capacity_dc_kwp, cod_date, guarantee_years,
                                              g_ref_w_m2, pr_active, source)
                     values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'plant_information')
                     on conflict (code) do update set name=excluded.name, account=excluded.account, latitude=excluded.latitude,
                        longitude=excluded.longitude, capacity_dc_kwp=excluded.capacity_dc_kwp, cod_date=excluded.cod_date,
                        guarantee_years=excluded.guarantee_years, g_ref_w_m2=excluded.g_ref_w_m2, pr_active=excluded.pr_active
                     returning plant_id""", r[:10])
        pid = d.fetchone()[0]
        d.execute("""insert into asset.plant_pr_param values (%s,%s,%s,%s,%s,'plant_information')
                     on conflict (plant_id) do update set string_cap_w=excluded.string_cap_w, panels=excluded.panels,
                        globinc_pct=excluded.globinc_pct, temp_coeff_pct_per_c=excluded.temp_coeff_pct_per_c""", (pid, *r[10:]))
    d.execute("select code, plant_id from asset.plant")
    plants = dict(d.fetchall())

    s.execute("""select pd_id, pd_pi_code, pd_mdt_type, pd_id_internal, pd_esn_code, pd_dev_name, pd_inv_type,
                        coalesce(pd_primary_device_flag, false)
                 from plant_devices where pd_id_internal is not null""")
    pd_map = {}
    for pd_id, code, mdt, devid, esn, name, model, prim in s.fetchall():
        if code not in plants:
            continue
        d.execute("select device_id from asset.device where vendor='huawei' and vendor_device_id=%s and upper(valid)='infinity'", (devid,))
        got = d.fetchone()
        if got:
            d.execute("update asset.device set plant_id=%s, name=%s, model=%s, serial_no=%s, is_primary=%s, kind=%s where device_id=%s",
                      (plants[code], name, model, esn, prim, KIND.get(mdt, "logger"), got[0]))
            pd_map[pd_id] = got[0]
        else:
            d.execute("""insert into asset.device (plant_id, kind, vendor_device_id, serial_no, name, model, is_primary, source)
                         values (%s,%s,%s,%s,%s,%s,%s,'plant_devices') returning device_id""",
                      (plants[code], KIND.get(mdt, "logger"), devid, esn, name, model, prim))
            pd_map[pd_id] = d.fetchone()[0]

    s.execute("""select ii_pd_id, ii_string_cap, ii_panel, ii_cap_wp, ii_glob_inc_pcnt, ii_temp_co_efficiency, ii_gi_ref
                 from inverter_information""")
    for pd_id, *vals in s.fetchall():
        if pd_id in pd_map:
            d.execute("""insert into asset.inverter_pr_param values (%s,%s,%s,%s,%s,%s,%s,'inverter_information')
                         on conflict (device_id) do update set string_cap_w=excluded.string_cap_w, panels=excluded.panels,
                            module_wp=excluded.module_wp, globinc_pct=excluded.globinc_pct,
                            temp_coeff_pct_per_c=excluded.temp_coeff_pct_per_c, g_ref_w_m2=excluded.g_ref_w_m2""",
                      (pd_map[pd_id], *vals))

    s.execute("""select ic_pd_id, ic_pv_string, ic_pv_cap_wp, ic_temp_co_efficiency, ic_pv_panel, ic_pv_string_cap, ic_glob_inc_pcnt,
                        coalesce(ic_disabled, false) from inverter_configurations""")
    for pd_id, no, wp, gamma, panels, cap, gi_pcnt, disabled in s.fetchall():
        inv = pd_map.get(pd_id)
        if inv is None:
            continue
        d.execute("""insert into asset.module_type (pmax_stc_w, gamma_pct_per_c, description) values (%s,%s,'from inverter_configurations')
                     on conflict (pmax_stc_w, gamma_pct_per_c, description) do update set pmax_stc_w=excluded.pmax_stc_w
                     returning module_type_id""", (wp or 0, gamma or 0))
        new = dict(module_type_id=d.fetchone()[0], modules_count=panels, stc_capacity_w=cap,
                   poa_factor=(gi_pcnt / 100.0) if gi_pcnt else None, enabled=not disabled)
        d.execute(f"""select string_id, configured, {','.join(STRING_FIELDS)} from asset.pv_string
                      where inverter_id=%s and string_no=%s and upper(valid)='infinity'""", (inv, no))
        row = d.fetchone()
        if row is None:
            d.execute("""insert into asset.pv_string (inverter_id, string_no, module_type_id, modules_count, stc_capacity_w, poa_factor,
                                                      enabled, configured, source)
                         values (%(inv)s,%(no)s,%(module_type_id)s,%(modules_count)s,%(stc_capacity_w)s,%(poa_factor)s,%(enabled)s,
                                 true, 'inverter_configurations')""", dict(new, inv=inv, no=no))
            continue
        sid, configured, *old = row
        if not configured:   # an observed-only string is now configured: fill it in place (no history to keep)
            d.execute("""update asset.pv_string set module_type_id=%(module_type_id)s, modules_count=%(modules_count)s,
                            stc_capacity_w=%(stc_capacity_w)s, poa_factor=%(poa_factor)s, enabled=%(enabled)s, configured=true,
                            source='inverter_configurations' where string_id=%(sid)s""", dict(new, sid=sid))
            changes += 1
        elif tuple(old) != tuple(new[f] for f in STRING_FIELDS):
            # configuration changed: close the current row, open a new one (history keeps the old values)
            d.execute("update asset.pv_string set valid=tstzrange(lower(valid), now()) where string_id=%s", (sid,))
            d.execute("""insert into asset.pv_string (inverter_id, string_no, module_type_id, modules_count, stc_capacity_w, poa_factor,
                                                      enabled, configured, valid, source)
                         values (%(inv)s,%(no)s,%(module_type_id)s,%(modules_count)s,%(stc_capacity_w)s,%(poa_factor)s,%(enabled)s,
                                 true, tstzrange(now(), 'infinity'), 'inverter_configurations')""", dict(new, inv=inv, no=no))
            LOG.info("string configuration changed: inverter %s pv%s %s -> %s", inv, no, old, [new[f] for f in STRING_FIELDS])
            changes += 1

    s.execute("""select pmfc_pi_code, date_trunc('month', pmfc_period)::date, pmfc_temp_pv_ref, pmfc_pv_degrade_pcnt,
                        pmfc_pv_degrade_cap_pcnt, pmfc_pv_warranty_pcnt, pmfc_sys_availability_pcnt
                 from plant_monthly_factor_configurations""")
    for code, month, *vals in s.fetchall():
        if code in plants:
            d.execute("""insert into asset.plant_month_factor values (%s,%s,%s,%s,%s,%s,%s)
                         on conflict (plant_id, month) do update set temp_ref_c=excluded.temp_ref_c,
                            degradation_pct=excluded.degradation_pct, degrade_cap_pct=excluded.degrade_cap_pct,
                            warranty_pct=excluded.warranty_pct, availability_pct=excluded.availability_pct""", (plants[code], month, *vals))

    s.execute("""select piph_pi_code, make_date(piph_year, piph_month, 1), piph_value / 1000.0, piph_mplm_code, coalesce(piph_static_flag, false)
                 from plant_import_power_history where piph_year is not null and piph_month is not null""")
    for code, month, kw, method, static in s.fetchall():
        if code in plants:
            d.execute("""insert into asset.plant_import_power values (%s,%s,%s,%s,%s)
                         on conflict (plant_id, month) do update set value_kw=excluded.value_kw, method=excluded.method,
                            static=excluded.static""", (plants[code], month, kw, method, static))

    s.execute("select ppr_pi_code, ppr_month, ppr_temperature from plant_pvsyst_reference where ppr_month between 1 and 12")
    for code, m, temp in s.fetchall():
        if code in plants:
            d.execute("""insert into asset.pvsyst_reference values (%s,%s,%s)
                         on conflict (plant_id, month_no) do update set temperature_c=excluded.temperature_c""", (plants[code], m, temp))

    d.execute("select (select count(*) from asset.plant), (select count(*) from asset.device), "
              "(select count(*) from asset.pv_string where upper(valid)='infinity')")
    counts = d.fetchone()
    end_run(d, run_id, changes)
    dst.commit()
    LOG.info("assets synced: plants=%s devices=%s strings=%s, configuration changes=%s", *counts, changes)
    src.close(); dst.close()


# ----------------------------------------------------------------------------------------------- 2. ingest (L1)

INV_FIELDS = ["active_power", "reactive_power", "power_factor", "elec_freq", "ab_u", "bc_u", "ca_u", "a_i", "b_i", "c_i",
              "day_cap", "total_cap", "mppt_power", "temperature", "efficiency", "inverter_state"]
EMI_FIELDS = ["radiant_line", "radiant_total", "horiz_radiant_line", "horiz_radiant_total", "pv_temperature", "temperature",
              "wind_speed", "wind_direction"]
GM_FIELDS = ["active_power", "reactive_power", "power_factor", "grid_frequency", "active_cap", "reverse_active_cap"]
L1 = {
    "ts.inverter_ac": ["time", "device_id", "active_power_kw", "reactive_power_kvar", "power_factor", "frequency_hz", "u_ab_v", "u_bc_v",
                       "u_ca_v", "i_a_a", "i_b_a", "i_c_a", "energy_day_kwh", "energy_total_kwh", "dc_power_kw", "temperature_c",
                       "efficiency_pct", "state", "run_id"],
    "ts.dc_string": ["time", "string_id", "voltage_v", "current_a", "run_id"],
    "ts.irradiance": ["time", "device_id", "poa_w_m2", "poa_total_kwh_m2", "ghi_w_m2", "ghi_total_kwh_m2", "module_temp_c",
                      "ambient_temp_c", "wind_speed_m_s", "wind_direction_deg", "run_id"],
    "ts.grid_meter": ["time", "device_id", "active_power_kw", "reactive_power_kvar", "power_factor", "frequency_hz",
                      "energy_forward_kwh", "energy_reverse_kwh", "run_id"],
}


def influx(q):
    r = requests.get(CFG["influx_url"], params={"db": CFG["influx_db"], "q": q, "epoch": "s", "chunked": "true", "chunk_size": "20000"},
                     auth=CFG["influx_auth"], stream=True, timeout=(10, 900))
    r.raise_for_status()
    for line in r.iter_lines():
        if line:
            res = json.loads(line)["results"][0]
            if "error" in res:
                raise RuntimeError(res["error"])
            yield from res.get("series", [])


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat()


def div(v, k):
    return v / k if v is not None else None


def copy_insert(cur, table, rows):
    if not rows:
        return 0
    cols = L1[table]
    stage = "stage_" + table.replace(".", "_")
    cur.execute(f"CREATE TEMP TABLE IF NOT EXISTS {stage} (LIKE {table} INCLUDING DEFAULTS)")
    cur.execute(f"TRUNCATE {stage}")
    buf = io.StringIO()
    for r in rows:
        buf.write("\t".join("\\N" if v is None else str(v) for v in r) + "\n")
    buf.seek(0)
    cur.copy_expert(f"COPY {stage} ({','.join(cols)}) FROM STDIN", buf)
    cur.execute(f"INSERT INTO {table} ({','.join(cols)}) SELECT {','.join(cols)} FROM {stage} ON CONFLICT DO NOTHING")
    return cur.rowcount


def ingest(since, until):
    db = pg(CFG["db"]); cur = db.cursor()
    cur.execute("select vendor_device_id::text, device_id from asset.device where upper(valid)='infinity'")
    dev = dict(cur.fetchall())
    cur.execute("select inverter_id, string_no, string_id from asset.pv_string where upper(valid)='infinity'")
    strings = {(i, n): s for i, n, s in cur.fetchall()}
    run_id = start_run(cur, "ingest", "influx", {"from": since, "to": until, "db": CFG["influx_db"]})
    totals, unknown = {t: 0 for t in L1}, {}

    def device(s, measurement):
        sid = s["tags"]["sensorId"]
        did = dev.get(sid)
        if did is None and sid.isdigit():
            unknown[(int(sid), measurement)] = s["tags"].get("stationCode")
        return did

    t0 = since
    while t0 < until:
        t1 = min(t0 + timedelta(days=1), until)
        where = f"time >= '{t0.isoformat()}' AND time < '{t1.isoformat()}'"
        rows = {t: [] for t in L1}
        for s in influx(f'SELECT {",".join(INV_FIELDS)}, /^pv[0-9]+_[ui]$/ FROM "GetDevRealKpi_1" WHERE {where} GROUP BY "sensorId", "stationCode"'):
            did = device(s, "GetDevRealKpi_1")
            if did is None:
                continue
            for row in s["values"]:
                r = dict(zip(s["columns"], row)); ts = iso(row[0]); st = r.get("inverter_state")
                rows["ts.inverter_ac"].append((ts, did, *[r.get(f) for f in INV_FIELDS[:-1]], int(st) if st is not None else None, run_id))
                for k, u in r.items():
                    m = re.match(r"^pv(\d+)_u$", k)
                    if not m or u is None:
                        continue
                    n = int(m.group(1)); a = r.get(f"pv{n}_i")
                    sid = strings.get((did, n))
                    if sid is None:
                        if not a or a < STRING_MIN_A:
                            continue
                        cur.execute("""insert into asset.pv_string (inverter_id, string_no, enabled, configured, source)
                                       values (%s,%s,true,false,'observed in data, not configured') returning string_id""", (did, n))
                        sid = strings[(did, n)] = cur.fetchone()[0]
                        LOG.warning("new observed string: device_id=%s pv%s (%.1f A), not in the configuration", did, n, a)
                    rows["ts.dc_string"].append((ts, sid, u, a, run_id))
        for s in influx(f'SELECT {",".join(EMI_FIELDS)} FROM "GetDevRealKpi_10" WHERE {where} GROUP BY "sensorId", "stationCode"'):
            did = device(s, "GetDevRealKpi_10")
            if did is None:
                continue
            for row in s["values"]:
                r = dict(zip(s["columns"], row))
                rows["ts.irradiance"].append((iso(row[0]), did, r.get("radiant_line"), div(r.get("radiant_total"), 3.6),
                                              r.get("horiz_radiant_line"), div(r.get("horiz_radiant_total"), 3.6), r.get("pv_temperature"),
                                              r.get("temperature"), r.get("wind_speed"), r.get("wind_direction"), run_id))
        for s in influx(f'SELECT {",".join(GM_FIELDS)} FROM "GetDevRealKpi_17" WHERE {where} GROUP BY "sensorId", "stationCode"'):
            did = device(s, "GetDevRealKpi_17")
            if did is None:
                continue
            for row in s["values"]:
                r = dict(zip(s["columns"], row))   # Huawei meter power is in W / var
                rows["ts.grid_meter"].append((iso(row[0]), did, div(r.get("active_power"), 1000), div(r.get("reactive_power"), 1000),
                                              r.get("power_factor"), r.get("grid_frequency"), r.get("active_cap"),
                                              r.get("reverse_active_cap"), run_id))
        for table, rs in rows.items():
            totals[table] += copy_insert(cur, table, rs)
        db.commit()
        t0 = t1
    for (vid, meas), code in unknown.items():
        cur.execute("""insert into dq.unknown_sensor (vendor_device_id, measurement, station_code) values (%s,%s,%s)
                       on conflict (vendor, vendor_device_id, measurement) do update set last_seen=now(),
                          station_code=excluded.station_code""", (vid, meas, code))
    n = sum(totals.values())
    end_run(cur, run_id, n)
    cur.execute("""insert into calc.watermark values ('ingest', %s, now())
                   on conflict (job) do update set until_ts=excluded.until_ts, updated_at=now()""", (until,))
    db.commit(); db.close()
    LOG.info("ingest %s .. %s: %s new rows %s%s", since.isoformat(timespec="minutes"), until.isoformat(timespec="minutes"), n,
             {k.split(".")[1]: v for k, v in totals.items()}, f", {len(unknown)} unknown sensors" if unknown else "")


# ----------------------------------------------------------------------------------------------- 3./4. calc (L2)

def compute(since, until, day_from, day_to):
    db = pg(CFG["db"]); cur = db.cursor()
    cur.execute("SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0")   # recalculation may touch compressed chunks
    run_id = start_run(cur, "intervals", "iec_61724_1+neo_customer", {"from": since, "to": until})
    n_int, t0 = 0, since
    while t0 < until:                       # one day per call keeps the temp tables small during a backfill
        t1 = min(t0 + timedelta(days=1), until)
        cur.execute("select calc.compute_intervals(%s, %s, %s, %s)", (t0, t1, VERSION, run_id))
        n_int += cur.fetchone()[0]
        db.commit()
        t0 = t1
    end_run(cur, run_id, n_int)
    run_id = start_run(cur, "daily", "iec_61724_1+neo_customer", {"from": day_from, "to": day_to})
    cur.execute("select calc.compute_daily(%s, %s, %s, %s)", (day_from, day_to, VERSION, run_id))
    n_day = cur.fetchone()[0]
    end_run(cur, run_id, n_day)
    db.commit(); db.close()
    LOG.info("calc %s: intervals from %s: %s rows, daily %s..%s: %s rows", VERSION, since.isoformat(timespec="minutes"), n_int,
             day_from, day_to, n_day)


# ----------------------------------------------------------------------------------------------- loop

def watermark(job):
    db = pg(CFG["db"]); cur = db.cursor()
    cur.execute("select until_ts from calc.watermark where job=%s", (job,))
    r = cur.fetchone(); db.close()
    return r[0] if r else None


def local_day(t):
    return t.astimezone(LOCAL_TZ).date()


def cycle():
    now = datetime.now(timezone.utc)
    wm = watermark("ingest")
    if wm is None:          # first start: backfill
        if CFG["backfill_from"]:
            since = datetime.combine(date.fromisoformat(CFG["backfill_from"]), datetime.min.time(), LOCAL_TZ).astimezone(timezone.utc)
            until = (datetime.combine(date.fromisoformat(CFG["backfill_to"]) + timedelta(days=1), datetime.min.time(), LOCAL_TZ)
                     .astimezone(timezone.utc) if CFG["backfill_to"] else now)
        else:
            since, until = now - timedelta(days=CFG["backfill_days"]), now
        LOG.info("first start: backfill %s .. %s", since.isoformat(timespec="minutes"), until.isoformat(timespec="minutes"))
        ingest(since, until)
        compute(since, until, local_day(since), local_day(until - timedelta(seconds=1)))
        return
    ingest(wm - timedelta(minutes=CFG["overlap_min"]), now)
    compute(now - timedelta(hours=CFG["lookback_h"]), now, local_day(now) - timedelta(days=1), local_day(now))


def main():
    logging.basicConfig(level=os.environ.get("LOGLEVEL", "INFO"), stream=sys.stdout,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    def stop(*_):
        global STOP
        STOP = True
        LOG.info("stopping after the current cycle")
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)

    LOG.info("neo-model %s: db=%s assets=%s influx=%s/%s cycle=%ss", VERSION, CFG["db"], CFG["asset_db"], CFG["influx_url"],
             CFG["influx_db"], CFG["cycle_s"])
    last_assets = 0.0
    while not STOP:
        try:
            if time.time() - last_assets > CFG["asset_sync_h"] * 3600:
                sync_assets(); last_assets = time.time()
            cycle()
        except Exception:
            LOG.exception("cycle failed; retrying next cycle")
        if os.environ.get("ONCE"):
            break
        wait = CFG["cycle_s"] - (time.time() % CFG["cycle_s"]) + CFG["offset_s"]
        while wait > 0 and not STOP:
            time.sleep(min(wait, 5)); wait -= 5


if __name__ == "__main__":
    main()
