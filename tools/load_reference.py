"""Load the PR results of PR as-is 0.2 (neo-dev, Influx PR_RESTORE) into schema ref of a test database, for tests/validate.sql.

  ref.inverter_interval  GetDevRealKpi_1: energy_asis, energy_xze, pr_asis_inv, pr_xze_inv, ck_inv, tcf_inv, pr_actual_ck/_tcf
  ref.string_interval    GetDevRealKpi_1: pr_asis_pv<N>
  ref.plant_interval     GetStationRealKpi: energy_asis, energy_xze, pr_asis, pr_xze, criteria_filtered_2, radiant_*_globinc
  ref.plant_daily        GetIoxDailyKpi_Plant
  ref.inverter_daily     GetIoxDailyKpi_1

Usage (env as for the service, PG_DB = the test database):
  load_reference.py 2026-11-05 2026-11-12          (local days, Asia/Bangkok)
"""

import io
import json
import re
import sys
from datetime import date, datetime, time as dtime, timedelta, timezone
from zoneinfo import ZoneInfo

import psycopg2
import requests

sys.path.insert(0, __file__.rsplit("/tools/", 1)[0] + "/service")
from neo_model import CFG, pg  # noqa: E402

TZ = ZoneInfo("Asia/Bangkok")
SPECS = {
    "inverter_interval": ("GetDevRealKpi_1", ["energy_asis", "energy_xze", "pr_asis_inv", "pr_xze_inv", "ck_inv", "tcf_inv",
                                              "pr_actual_ck", "pr_actual_tcf"]),
    "plant_interval": ("GetStationRealKpi", ["energy_asis", "energy_xze", "pr_asis", "pr_xze", "criteria_filtered_2",
                                             "radiant_asis_globinc", "radiant_xze_globinc"]),
    "plant_daily": ("GetIoxDailyKpi_Plant", ["energy_asis", "energy_xze", "pr_asis", "pr_xze", "tmod", "ck", "tcf", "pr_actual_ck",
                                             "pr_actual_tcf", "pr_epc_ck", "pr_epc_tcf", "daylight_hour", "ze_hour",
                                             "radiant_asis_globinc", "radiant_xze_globinc"]),
    "inverter_daily": ("GetIoxDailyKpi_1", ["energy_asis", "energy_xze", "pr_asis", "pr_xze", "ck_inv", "tcf_inv", "pr_actual_ck",
                                            "pr_actual_tcf", "pr_epc_ck", "pr_epc_tcf", "radiant_asis", "radiant_xze"]),
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


def copy(cur, table, cols, rows):
    buf = io.StringIO()
    for r in rows:
        buf.write("\t".join("\\N" if v is None else str(v) for v in r) + "\n")
    buf.seek(0)
    cur.copy_expert(f"COPY ref.{table} ({','.join(cols)}) FROM STDIN", buf)


def main():
    d_from, d_to = date.fromisoformat(sys.argv[1]), date.fromisoformat(sys.argv[2])
    t_from = datetime.combine(d_from, dtime(), TZ).astimezone(timezone.utc)
    t_to = datetime.combine(d_to + timedelta(days=1), dtime(), TZ).astimezone(timezone.utc)
    db = pg(CFG["db"]); cur = db.cursor()
    cur.execute("CREATE SCHEMA IF NOT EXISTS ref")
    for name, (_, fields) in SPECS.items():
        cur.execute(f"DROP TABLE IF EXISTS ref.{name}")
        cur.execute(f"CREATE TABLE ref.{name} (time timestamptz, sensor_id bigint, station_code text, "
                    + ", ".join(f"{f} double precision" for f in fields) + ")")
    cur.execute("DROP TABLE IF EXISTS ref.string_interval")
    cur.execute("CREATE TABLE ref.string_interval (time timestamptz, sensor_id bigint, string_no smallint, pr_asis double precision)")
    db.commit()
    for name, (meas, fields) in SPECS.items():
        rows, t = [], t_from
        while t < t_to:
            t1 = min(t + timedelta(days=1), t_to)
            for s in influx(f'SELECT {",".join(fields)} FROM "{meas}" WHERE time >= \'{t.isoformat()}\' AND time < \'{t1.isoformat()}\' '
                            f'GROUP BY "sensorId", "stationCode"'):
                sid = s["tags"].get("sensorId"); code = s["tags"].get("stationCode")
                for row in s["values"]:
                    rows.append([datetime.fromtimestamp(row[0], timezone.utc).isoformat(), int(sid) if sid and sid.isdigit() else None,
                                 code, *row[1:]])
            t = t1
        copy(cur, name, ["time", "sensor_id", "station_code", *fields], rows)
        db.commit()
        print(f"ref.{name}: {len(rows):,} rows")
    n, t = 0, t_from
    while t < t_to:
        t1 = min(t + timedelta(days=1), t_to); rows = []
        for s in influx(f'SELECT /^pr_asis_pv[0-9]+$/ FROM "GetDevRealKpi_1" WHERE time >= \'{t.isoformat()}\' AND time < \'{t1.isoformat()}\' '
                        f'GROUP BY "sensorId"'):
            sid = int(s["tags"]["sensorId"])
            for row in s["values"]:
                ts = datetime.fromtimestamp(row[0], timezone.utc).isoformat()
                for c, v in zip(s["columns"][1:], row[1:]):
                    if v is not None:
                        rows.append((ts, sid, int(re.sub(r"\D", "", c)), v))
        copy(cur, "string_interval", ["time", "sensor_id", "string_no", "pr_asis"], rows)
        db.commit(); n += len(rows); t = t1
    print(f"ref.string_interval: {n:,} rows")
    db.close()


if __name__ == "__main__":
    main()
