"""NEO backend: one consolidated API for the NEO apps (repo neo-pr-next, backend/).

Phase 1 (2026-11-24): the **v2-compat layer**. It serves the legacy paths and response shapes the existing Angular app
`iox.neo.app.v2` calls, so v2 runs unchanged on local data as the benchmark for the v3 rewrite. Every compat route is
a thin adapter over our own data (no NEO prod access):

  POST /api/User/Login                         accounts in neo_live_core_iox (bcrypt), JWT like IOX4 auth (HS256, aud IOX4)
  POST /auth/auth/verify_token                 token check used by the legacy iox-admin-api
  GET  /api/Sensor                             sensors + categories + state from neo_live_core_iox (IOX4 core shape)
  GET  /express/js/sensorValues/lastUpdate     latest raw Huawei record per device/station from neo_model.raw.api_response
  GET  /app-config/by_name/{app}               talegur.app_config (Mongo copy), server/Grafana key rewritten for this host
  GET  /translator-api/app-translations/by_name/{app}/{locale}
  *    /auth/api/v1/accounts..., /core/api/v1/gateways   user admin (neo_live_core_iox)
  POST /iox-compute-service/api/v1/performance_ratio/calculation/actual/daterange   PR per inverter from neo_model calc.pr_interval

Clean v3 endpoints go under /v1 (not in phase 1). Legacy compat routes are tagged "v2-compat" in the OpenAPI doc (/docs).
"""

import json
import os
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

import bcrypt
import jwt
import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pymongo import MongoClient

BKK = ZoneInfo("Asia/Bangkok")


def env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None:
        raise RuntimeError(f"missing env {name}")
    return v


PG = dict(host=env("PG_HOST", "postgres"), port=int(env("PG_PORT", "5432")), user=env("PG_USER"), password=env("PG_PASSWORD"))
JWT_SECRET = env("JWT_SECRET")
JWT_AUDIENCE = env("JWT_AUDIENCE", "IOX4")
JWT_TTL_S = int(env("JWT_TTL_S", "43200"))
TENANT = env("TENANT", "NEOVISION")
PUBLIC_URL = env("PUBLIC_URL", "https://aiiot.ait.co.th")
GRAFANA_API_KEY = env("GRAFANA_API_KEY", "")
MONGO_URI = env("MONGO_URI", "")
DB_CORE = env("DB_CORE", "neo_live_core_iox")
DB_MODEL = env("DB_MODEL", "neo_model")
DB_TRANSLATOR = env("DB_TRANSLATOR", "neo_live_translator_api_db")
LASTUPDATE_LOOKBACK_H = int(env("LASTUPDATE_LOOKBACK_H", "24"))

_pools: dict[str, ConnectionPool] = {}


def pool(db: str) -> ConnectionPool:
    if db not in _pools:
        _pools[db] = ConnectionPool(conninfo=psycopg.conninfo.make_conninfo(dbname=db, **PG), min_size=1, max_size=8,
                                    kwargs={"row_factory": dict_row, "autocommit": True}, open=True)
    return _pools[db]


@contextmanager
def cur(db: str):
    with pool(db).connection() as c:
        with c.cursor() as k:
            yield k


app = FastAPI(title="NEO backend", version="0.1.0",
              description="Consolidated NEO API. Phase 1: v2-compat layer for iox.neo.app.v2 (benchmark).")


@app.get("/health", tags=["ops"])
def health():
    with cur(DB_CORE) as k:
        k.execute("select 1")
    return {"status": "ok"}


# ------------------------------------------------------------------------------------------------ auth (IOX4-compatible JWT)

def _account(where: str, arg) -> dict | None:
    with cur(DB_CORE) as k:
        k.execute(f"""select a.*, r.r_code as role_code, gp.gpri_id, gp.gpri_name
                      from accounts a
                      left join account_group_privileges agp on agp.agp_acc_id = a.acc_id
                      left join group_privileges gp on gp.gpri_id = agp.agp_gpri_id
                      left join role_group_privileges rgp on rgp.rgp_gpri_id = gp.gpri_id
                      left join roles r on r.r_id = rgp.rgp_r_id
                      where {where} order by gp.gpri_id limit 1""", (arg,))
        return k.fetchone()


def issue_token(acc: dict) -> str:
    now = int(time.time())
    role = acc.get("role_code") or "R_USER"
    claims = {"sub": acc["acc_username"], "username": acc["acc_username"], "acc_id": acc["acc_id"],
              "tenant": acc.get("acc_key") or TENANT, "authorities": [role], "aud": JWT_AUDIENCE,
              "iat": now, "exp": now + JWT_TTL_S}
    return jwt.encode(claims, JWT_SECRET, algorithm="HS256")


def decode(token: str) -> dict:
    return jwt.decode(token, JWT_SECRET, algorithms=["HS256"], audience=JWT_AUDIENCE, options={"verify_iat": False}, leeway=10)


def bearer(authorization: str | None) -> str | None:
    if not authorization:
        return None
    parts = authorization.strip().split(" ", 1)
    t = parts[1] if len(parts) == 2 and parts[0].lower() == "bearer" else parts[0]
    return None if t in ("", "null", "undefined") else t.strip()


def user(authorization: str | None = Header(default=None)) -> dict:
    t = bearer(authorization)
    if not t:
        raise HTTPException(401, "Authentication Token is missing!")
    try:
        return decode(t)
    except jwt.PyJWTError as e:
        raise HTTPException(401, f"Invalid Authentication token! ({e.__class__.__name__})")


def admin(u: dict = Depends(user)) -> dict:
    if not set(u.get("authorities", [])) & {"R_ADMIN", "R_SUPERADMIN"}:
        raise HTTPException(403, "admin only")
    return u


@app.post("/api/User/Login", tags=["v2-compat"])
async def login(req: Request):
    body = await req.json()
    username, password = str(body.get("username", "")), str(body.get("password", ""))
    acc = _account("lower(a.acc_username) = lower(%s)", username)
    ok = bool(acc and not acc["acc_disabled"] and acc["acc_password"]
              and bcrypt.checkpw(password.encode(), acc["acc_password"].encode()))
    if not ok:
        return JSONResponse({"message": "Invalid username or password"}, status_code=401)
    with cur(DB_CORE) as k:
        k.execute("update accounts set acc_last_login = now() where acc_id = %s", (acc["acc_id"],))
    tok = issue_token(acc)
    return {"access_token": tok, "refresh_token": tok, "token_type": "Bearer", "expires_in": JWT_TTL_S}


@app.post("/auth/auth/verify_token", tags=["v2-compat"])
def verify_token(authorization: str | None = Header(default=None)):
    u = user(authorization)
    return {"tenant": u.get("tenant", TENANT), "username": u.get("username"), "authorities": u.get("authorities", [])}


# ------------------------------------------------------------------------------------------------ sensors (IOX4 core shape)

def _customer_gateways(u: dict) -> set[int] | None:
    if "R_CUSTOMER" not in u.get("authorities", []):
        return None
    with cur(DB_CORE) as k:
        k.execute("select gwa_gw_id from gateway_accountability where gwa_acc_id = %s", (u.get("acc_id"),))
        return {r["gwa_gw_id"] for r in k.fetchall()}


@app.get("/api/Sensor", tags=["v2-compat"])
def sensors(u: dict = Depends(user)):
    gws = _customer_gateways(u)
    with cur(DB_CORE) as k:
        k.execute("select * from sensors where not coalesce(s_disabled, false) order by s_id")
        rows = k.fetchall()
        k.execute("select scat_s_id, scat_key, scat_value from sensor_categories")
        cats: dict[int, dict] = {}
        for r in k.fetchall():
            cats.setdefault(r["scat_s_id"], {})[r["scat_key"]] = r["scat_value"]
        k.execute("select * from sensor_state")
        states = {r["sst_s_id"]: r for r in k.fetchall()}
        k.execute("select sprp_s_id, sprp_key, sprp_value from sensor_properties")
        props: dict[int, list] = {}
        for r in k.fetchall():
            props.setdefault(r["sprp_s_id"], []).append({"propName": r["sprp_key"], "propValue": r["sprp_value"]})
    out = []
    for s in rows:
        if gws is not None and s["s_gw_id"] not in gws:
            continue
        st = states.get(s["s_id"]) or {}
        loc = s["s_location"]
        out.append({
            "id": s["s_sensorid"], "internalId": s["s_id"], "gatewayId": s["s_gw_id"], "tenantId": s["s_key"],
            "name": s["s_name"], "type": s["s_type"], "clazz": s["s_clazz"], "oemId": s["s_oemid"],
            "appState": s["s_appstate"], "appStateMachine": s["s_appstatemachine"],
            "minValue": s["s_minvalue"], "maxValue": s["s_maxvalue"], "valueUnit": s["s_valueunit"],
            "resolution": s["s_resolution"], "resolutionUnit": s["s_resolutionunit"],
            "samplingRate": s["s_samplingrate"], "samplingRateUnit": s["s_samplingrateunit"],
            "lag": s["s_lag"], "lagUnit": s["s_lagunit"],
            "smartExpression": s["s_smartexpression"], "smartExpressionLayer": s["s_smartexpressionlayer"],
            "smartScript": s["s_smartscript"], "smartScriptLayer": s["s_smartscriptlayer"],
            "timeZone": s["s_timezone"], "saveAt": s["s_saveat"],
            "location": loc if isinstance(loc, str) else json.dumps(loc) if loc is not None else "",
            "inCompoundSensor": s["s_incompoundsensor"], "disabled": s["s_disabled"],
            "categories": cats.get(s["s_id"], {}),
            "sensorProperties": props.get(s["s_id"], []),
            "deviceState": {"state": st.get("sst_state"), "command": st.get("sst_command"),
                            "deviceEvent": st.get("sst_deviceevent"), "errCode": st.get("sst_errcode"),
                            "message": st.get("sst_message")},
            "createdBy": s["s_createdby"], "createdAt": s["s_createdat"], "updatedBy": s["s_updatedby"],
            "updatedAt": s["s_updatedat"],
        })
    return {"sensors": out}


# ------------------------------------------------------------------------------------------------ last value per sensor

@app.get("/express/js/sensorValues/lastUpdate", tags=["v2-compat"])
def last_update(u: dict = Depends(user)):
    """Same shape as v1's talegur.lastSensorValueUpdate: [{sensorId, savedAt, lastSensorValue}], built from the newest raw
    getDevRealKpi / getStationRealKpi responses (pipeline B L0) instead of Mongo."""
    out: dict[int, dict] = {}
    with cur(DB_MODEL) as k:
        k.execute("select dev_id::text id, name dev_name, station_code from src.device")
        meta = {r["id"]: r for r in k.fetchall()}
        # every request of the newest round per (endpoint, account, device type): the consumer asks for <= 100 devices per call
        k.execute("""with r as (select endpoint, account, dev_type_id, fetched_at, collect_time, response,
                                       max(fetched_at) over (partition by endpoint, account, dev_type_id) newest
                                from raw.api_response
                                where endpoint in ('getDevRealKpi','getStationRealKpi') and success
                                  and fetched_at > now() - make_interval(hours => %s))
                     select * from r where fetched_at > newest - interval '4 minutes' order by fetched_at""", (LASTUPDATE_LOOKBACK_H,))
        for r in k.fetchall():
            ct = r["collect_time"] or r["fetched_at"]
            ct_utc = ct.astimezone(timezone.utc)
            saved = ct_utc.strftime("%Y-%m-%dT%H:%M:%S")
            for item in (r["response"] or {}).get("data") or []:
                if r["endpoint"] == "getDevRealKpi":
                    sid = int(item["devId"])
                    m = meta.get(str(sid), {})
                    v = {**item, "sensorId": sid, "account": r["account"], "devName": m.get("dev_name"),
                         "stationCode": m.get("station_code"), "collectTime": ct_utc.isoformat(),
                         "collectTimeMs": int(ct_utc.timestamp() * 1000), "devTypeId": str(r["dev_type_id"])}
                else:
                    sid = int("".join(ch for ch in item["stationCode"] if ch.isdigit()))
                    v = {**item, "sensorId": sid, "account": r["account"], "collectTime": ct_utc.isoformat(),
                         "collectTimeMs": int(ct_utc.timestamp() * 1000)}
                prev = out.get(sid)
                if not prev or prev["savedAt"] <= saved:
                    out[sid] = {"sensorId": sid, "savedAt": saved, "lastSensorValue": v}
    return list(out.values())


# ------------------------------------------------------------------------------------------------ app config + translations

_appcfg: dict[str, Any] = {}


@app.get("/app-config/by_name/{app_name}", tags=["v2-compat"])
def app_config(app_name: str):
    if app_name not in _appcfg or time.time() - _appcfg[app_name][0] > 300:
        docs = []
        if MONGO_URI:
            with MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000) as mc:
                docs = list(mc["talegur"]["app_config"].find({"app_name": app_name}))
        for d in docs:
            d["_id"] = str(d["_id"])
            d["server_ip"] = PUBLIC_URL                    # every API of the app hangs off this host
            if GRAFANA_API_KEY:
                d["gf_api_key"] = GRAFANA_API_KEY          # local Grafana service account (Viewer)
            if isinstance(d.get("created_at"), datetime):
                d["created_at"] = d["created_at"].isoformat()
        _appcfg[app_name] = (time.time(), docs)
    return _appcfg[app_name][1]


@app.get("/translator-api/app-translations/by_name/{app_name}/{locale}", tags=["v2-compat"])
def translations(app_name: str, locale: str):
    with cur(DB_TRANSLATOR) as k:
        k.execute("""select t.label, t.translation from translations t join languages l on l.id = t.languages_id
                     where lower(l.locale) = lower(%s) order by t.id""", (locale,))
        return k.fetchall()


@app.get("/translator-api/languages", tags=["v2-compat"])
def languages():
    with cur(DB_TRANSLATOR) as k:
        k.execute("select id, locale, name_en, name, flag from languages order by id")
        return k.fetchall()


# ------------------------------------------------------------------------------------------------ users (IOX4 auth v1 shape)

def _user_row(a: dict) -> dict:
    return {"id": a["acc_id"], "username": a["acc_username"], "firstname": a["acc_firstname"], "lastname": a["acc_lastname"],
            "email": a["acc_email"], "phone": a["acc_phone"], "disable": a["acc_disabled"], "disabled": a["acc_disabled"],
            "createdAt": a["acc_createdat"], "last_login": a["acc_last_login"],
            "roles": [{"role_id": a.get("gpri_id"), "name": a.get("gpri_name"), "code": a.get("role_code")}] if a.get("gpri_id") else []}


@app.get("/auth/api/v1/accounts", tags=["v2-compat"])
def accounts(u: dict = Depends(admin)):
    with cur(DB_CORE) as k:
        k.execute("""select distinct on (a.acc_id) a.*, gp.gpri_id, gp.gpri_name, r.r_code role_code from accounts a
                     left join account_group_privileges agp on agp.agp_acc_id = a.acc_id
                     left join group_privileges gp on gp.gpri_id = agp.agp_gpri_id
                     left join role_group_privileges rgp on rgp.rgp_gpri_id = gp.gpri_id
                     left join roles r on r.r_id = rgp.rgp_r_id order by a.acc_id, gp.gpri_id""")
        return [_user_row(a) for a in k.fetchall()]


@app.post("/auth/api/v1/accounts", tags=["v2-compat"])
async def account_create(req: Request, u: dict = Depends(admin)):
    b = await req.json()
    pw = bcrypt.hashpw(str(b.get("password", "")).encode(), bcrypt.gensalt(14)).decode()
    with cur(DB_CORE) as k:
        k.execute("""insert into accounts (acc_id, acc_key, acc_username, acc_password, acc_firstname, acc_lastname, acc_email,
                                           acc_phone, acc_disabled, acc_createdat)
                     values ((select coalesce(max(acc_id),0)+1 from accounts), %s, %s, %s, %s, %s, %s, %s, false, now())
                     returning acc_id""",
                  (TENANT, b.get("username"), pw, b.get("firstname"), b.get("lastname"), b.get("email"), b.get("phone")))
        return {"id": k.fetchone()["acc_id"]}


@app.put("/auth/api/v1/accounts", tags=["v2-compat"])
async def account_update(req: Request, u: dict = Depends(admin)):
    b = await req.json()
    with cur(DB_CORE) as k:
        k.execute("""update accounts set acc_firstname = coalesce(%s, acc_firstname), acc_lastname = coalesce(%s, acc_lastname),
                            acc_email = coalesce(%s, acc_email), acc_phone = coalesce(%s, acc_phone),
                            acc_disabled = coalesce(%s, acc_disabled) where acc_id = %s""",
                  (b.get("firstname"), b.get("lastname"), b.get("email"), b.get("phone"),
                   b.get("disabled", b.get("disable")), b.get("id")))
    return {"updated": b.get("id")}


@app.get("/auth/api/v1/group_privileges", tags=["v2-compat"])
def group_privileges(u: dict = Depends(user)):
    with cur(DB_CORE) as k:
        k.execute("select gpri_id privilege_id, gpri_name name, gpri_description description from group_privileges order by 1")
        return k.fetchall()


@app.patch("/auth/api/v1/accounts/{acc_id}/group_privilege", tags=["v2-compat"])
async def account_privilege(acc_id: int, req: Request, u: dict = Depends(admin)):
    ids = (await req.json()).get("group_ids") or []
    with cur(DB_CORE) as k:
        k.execute("delete from account_group_privileges where agp_acc_id = %s", (acc_id,))
        for g in ids:
            k.execute("insert into account_group_privileges (agp_acc_id, agp_gpri_id) values (%s, %s)", (acc_id, int(g)))
    return {"updated": acc_id}


@app.get("/auth/api/v1/accounts/feature-addon/accountability/{acc_id}/gateways", tags=["v2-compat"])
@app.get("/auth/api/v1/accounts/feature-addon/accountability//{acc_id}/gateways", include_in_schema=False)
def account_gateways(acc_id: int, u: dict = Depends(user)):
    with cur(DB_CORE) as k:
        k.execute("""select g.gw_id "gatewayId", g.gw_name "gatewayName" from gateway_accountability a
                     join gateways g on g.gw_id = a.gwa_gw_id where a.gwa_acc_id = %s order by 2""", (acc_id,))
        return k.fetchall()


@app.patch("/auth/api/v1/accounts/feature-addon/accountability/{acc_id}/gateways", tags=["v2-compat"])
async def account_gateways_set(acc_id: int, req: Request, u: dict = Depends(admin)):
    ids = (await req.json()).get("gateway_ids") or []
    with cur(DB_CORE) as k:
        k.execute("delete from gateway_accountability where gwa_acc_id = %s", (acc_id,))
        for g in ids:
            k.execute("insert into gateway_accountability (gwa_acc_id, gwa_gw_id, gwa_key) values (%s, %s, %s)", (acc_id, int(g), TENANT))
    return {"updated": acc_id}


@app.patch("/auth/api/v1/profile/change_password", tags=["v2-compat"])
async def change_password(req: Request, u: dict = Depends(user)):
    b = await req.json()
    pw = b.get("password") or b.get("newPassword")
    if not pw or pw != (b.get("confirmpassword") or b.get("confirmedNewPassword") or pw):
        raise HTTPException(400, "passwords do not match")
    with cur(DB_CORE) as k:
        k.execute("update accounts set acc_password = %s where acc_id = %s",
                  (bcrypt.hashpw(pw.encode(), bcrypt.gensalt(14)).decode(), u.get("acc_id")))
    return {"message": "password changed"}


@app.get("/core/api/v1/gateways", tags=["v2-compat"])
def gateways(u: dict = Depends(user)):
    with cur(DB_CORE) as k:
        k.execute("select gw_id id, gw_name name, gw_default \"default\", gw_location location, gw_key key from gateways order by gw_id")
        return {"gateways": k.fetchall()}


# ------------------------------------------------------------------------------------------------ PR per inverter (layout overlay)

@app.post("/iox-compute-service/api/v1/performance_ratio/calculation/actual/daterange", tags=["v2-compat"])
async def pr_daterange(req: Request, u: dict = Depends(user)):
    """PR per inverter over [start, end) (Bangkok local strings), from neo_model's customer method (neo_customer):
    pr_actual_ck / pr_actual_tcf = sum(E) / sum(E / pr_x) over the included intervals (= energy-weighted)."""
    b = await req.json()
    parse = lambda s: datetime.fromisoformat(str(s).replace(" ", "T")).replace(tzinfo=BKK)
    t0, t1 = parse(b["start_datetime"]), parse(b["end_datetime"])
    with cur(DB_MODEL) as k:
        k.execute("""select d.vendor_device_id::text "sensorId",
                            sum(i.energy_kwh) filter (where i.pr_ck > 0) / nullif(sum(i.energy_kwh / i.pr_ck) filter (where i.pr_ck > 0), 0) pr_actual_ck,
                            sum(i.energy_kwh) filter (where i.pr_tcf > 0) / nullif(sum(i.energy_kwh / i.pr_tcf) filter (where i.pr_tcf > 0), 0) pr_actual_tcf,
                            sum(i.energy_kwh) filter (where i.pr > 0) / nullif(sum(i.energy_kwh / i.pr) filter (where i.pr > 0), 0) pr_actual,
                            sum(i.energy_kwh) energy_kwh, count(*) intervals
                     from calc.pr_interval i join asset.device d on d.device_id = i.inverter_id and upper(d.valid) = 'infinity'
                     join asset.plant p on p.plant_id = i.plant_id
                     where i.method = 'neo_customer' and i.time >= %s and i.time < %s and p.code = %s
                     group by 1 order by 1""", (t0, t1, b["station_code"]))
        inv = k.fetchall()
    return {"result": {"result": {"station_code": b["station_code"], "start_datetime": b["start_datetime"],
                                  "end_datetime": b["end_datetime"], "inverters": inv}}}
