#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

SERVER="$R/app/panel/server.py"
MODEL="$R/app/panel/read_model.py"
COUNTRY_UI="$R/app/panel/country_ui.py"
DETAIL_UI="$R/app/panel/config_detail_ui.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/PANEL-A5-$TS"

mkdir -p "$B"

cp -a "$SERVER" "$B/server.py.before"
cp -a "$MODEL" "$B/read_model.py.before"
cp -a "$COUNTRY_UI" "$B/country_ui.py.before"

if [ -f "$DETAIL_UI" ]; then
    cp -a "$DETAIL_UI" "$B/config_detail_ui.py.before"
fi

echo "BACKUP=$B"


echo
echo "=== 1. EXTEND READ MODEL WITH DETAIL VIEW ==="

export MODEL

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["MODEL"])
s=p.read_text()

MARK="PANEL_A5_CONFIG_DETAIL_MODEL"

if MARK in s:
    print("DETAIL_MODEL_ALREADY_PRESENT=YES")
    raise SystemExit(0)

addition=r'''

# ============================================================
# PANEL_A5_CONFIG_DETAIL_MODEL
# ============================================================

RESULTS_ROOT = (
    COUNTRY_ROOT
    / "results"
    / "latest"
)


def _config_record_by_id(
    config_id: str,
) -> dict[str, Any] | None:

    direct=(
        CONFIG_ROOT
        / f"{config_id}.json"
    )

    if direct.exists():
        value=_read_json(direct)

        if value is not None:
            return value

    for cid,record in iter_config_records():

        if cid==config_id:
            return record

    return None


def config_detail(
    config_id: str,
) -> dict[str, Any] | None:

    config_id=str(
        config_id
        or ""
    ).strip()

    if not config_id:
        return None

    config=_config_record_by_id(
        config_id
    )

    if config is None:
        return None


    health=_first_existing(
        HEALTH_ROOT,
        config_id,
    )

    lifecycle=_first_existing(
        LIFECYCLE_ROOT,
        config_id,
    )

    identity=_first_existing(
        IDENTITY_ROOT,
        config_id,
    )

    pipeline=_first_existing(
        PIPELINE_ROOT,
        config_id,
    )

    result=_first_existing(
        RESULTS_ROOT,
        config_id,
    )


    summary=build_config_view(
        config_id,
        config,
    )


    raw=(
        config.get("raw")
        or config.get("source")
        or config.get("config")
    )


    return {
        "config_id":
            config_id,

        "summary":
            summary,

        "config":{
            "config_type":
                config.get("config_type")
                or config.get("type"),

            "first_seen_at":
                config.get("first_seen_at")
                or config.get("first_seen"),

            "last_seen_at":
                config.get("last_seen_at")
                or config.get("last_seen"),

            "source_ids":
                config.get("source_ids")
                or [],

            "raw":
                raw,
        },

        "health":
            health,

        "lifecycle":
            lifecycle,

        "country_identity":
            identity,

        "country_pipeline":
            pipeline,

        "country_result":
            result,
    }
'''

p.write_text(
    s+addition
)

print(
    "DETAIL_MODEL_PATCH=PASS"
)
PY


"$PY" -m py_compile "$MODEL"

echo "READ_MODEL_COMPILE=PASS"


echo
echo "=== 2. CREATE DETAIL UI ==="

cat >"$DETAIL_UI" <<'PY'
from __future__ import annotations

from aiohttp import web


# PANEL_A5_CONFIG_DETAIL_UI


HTML = r'''<!doctype html>
<html lang="fa" dir="rtl">

<head>

<meta charset="utf-8">

<meta name="viewport"
      content="width=device-width,initial-scale=1">

<title>Config Detail</title>

<style>

:root{
    color-scheme:dark;

    --bg:#0b0f14;
    --panel:#111821;
    --panel2:#161f2b;
    --border:#273342;

    --text:#eef4fb;
    --muted:#94a5b8;

    --green:#39d98a;
    --red:#ff667a;
    --yellow:#f5c451;
    --blue:#55aaff;
    --violet:#a98bff;
}

*{
    box-sizing:border-box;
}

body{
    margin:0;
    background:var(--bg);
    color:var(--text);

    font-family:
        system-ui,
        -apple-system,
        BlinkMacSystemFont,
        "Segoe UI",
        sans-serif;
}

.shell{
    width:min(1450px,96%);
    margin:0 auto;
    padding:18px 0 50px;
}

.topbar{
    display:flex;
    justify-content:space-between;
    align-items:flex-start;
    gap:12px;
    margin-bottom:15px;
}

.topbar h1{
    margin:0 0 5px;
    font-size:21px;
}

.actions{
    display:flex;
    gap:8px;
    flex-wrap:wrap;
}

.btn{
    display:inline-flex;
    align-items:center;
    justify-content:center;

    min-height:40px;
    padding:8px 13px;

    border:1px solid var(--border);
    border-radius:10px;

    background:var(--panel);
    color:var(--text);

    text-decoration:none;
}

.btn:hover{
    background:var(--panel2);
}

.mono{
    direction:ltr;
    text-align:left;

    font-family:
        ui-monospace,
        SFMono-Regular,
        Menlo,
        Consolas,
        monospace;
}

.muted{
    color:var(--muted);
}

.grid{
    display:grid;
    grid-template-columns:
        repeat(4,minmax(0,1fr));
    gap:12px;
}

.card{
    background:var(--panel);
    border:1px solid var(--border);
    border-radius:14px;
    padding:15px;
}

.metric-title{
    color:var(--muted);
    font-size:12px;
    margin-bottom:7px;
}

.metric-value{
    font-size:20px;
    font-weight:700;
    word-break:break-word;
}

.section{
    margin-top:14px;
}

.section h2{
    margin:0 0 12px;
    font-size:16px;
}

.detail-grid{
    display:grid;
    grid-template-columns:
        repeat(2,minmax(0,1fr));
    gap:12px;
}

pre{
    margin:0;

    padding:12px;

    min-height:120px;
    max-height:520px;
    overflow:auto;

    direction:ltr;
    text-align:left;

    background:#0b1118;

    border:1px solid var(--border);
    border-radius:10px;

    white-space:pre-wrap;
    word-break:break-word;

    font-family:
        ui-monospace,
        SFMono-Regular,
        Menlo,
        Consolas,
        monospace;

    font-size:12px;
    line-height:1.5;
}

.badge{
    display:inline-flex;
    padding:4px 9px;

    border-radius:999px;
    border:1px solid var(--border);

    font-size:12px;
}

.good{
    color:var(--green);
}

.bad{
    color:var(--red);
}

.warn{
    color:var(--yellow);
}

.info{
    color:var(--blue);
}

.violet{
    color:var(--violet);
}

.error{
    display:none;

    padding:12px;
    margin-bottom:12px;

    border:
        1px solid rgba(255,102,122,.5);

    border-radius:10px;

    background:
        rgba(255,102,122,.08);

    color:#ff9cab;
}

@media(max-width:900px){

    .grid{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }

    .detail-grid{
        grid-template-columns:1fr;
    }
}

@media(max-width:600px){

    .grid{
        grid-template-columns:1fr;
    }

    .topbar{
        flex-direction:column;
    }
}

</style>

</head>

<body>

<div class="shell">

    <div class="topbar">

        <div>

            <h1>
                🔎 Config Detail
            </h1>

            <div id="configId"
                 class="mono muted">
                -
            </div>

        </div>

        <div class="actions">

            <a href="/country"
               class="btn">
                Country
            </a>

            <a href="/configs"
               class="btn">
                Configs
            </a>

            <a href="/"
               class="btn">
                Dashboard
            </a>

        </div>

    </div>


    <div id="errorBox"
         class="error">
    </div>


    <div class="grid">

        <div class="card">

            <div class="metric-title">
                Type
            </div>

            <div id="type"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Health
            </div>

            <div id="health"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Country
            </div>

            <div id="country"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Country State
            </div>

            <div id="countryState"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Exit IP
            </div>

            <div id="exitIp"
                 class="metric-value mono">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Lifecycle
            </div>

            <div id="lifecycleState"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Sources
            </div>

            <div id="sources"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Last Seen
            </div>

            <div id="lastSeen"
                 class="metric-value mono">
                -
            </div>

        </div>

    </div>


    <div class="section detail-grid">

        <div class="card">

            <h2>
                Country Identity
            </h2>

            <pre id="identity">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Country Pipeline
            </h2>

            <pre id="pipeline">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Health
            </h2>

            <pre id="healthJson">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Lifecycle
            </h2>

            <pre id="lifecycleJson">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Country Evidence / Result
            </h2>

            <pre id="resultJson">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Source IDs
            </h2>

            <pre id="sourceIds">
-
            </pre>

        </div>

    </div>


    <div class="section card">

        <h2>
            Raw Config
        </h2>

        <pre id="raw">
-
        </pre>

    </div>

</div>


<script>

"use strict";

const CONFIG_ID =
    decodeURIComponent(
        location.pathname
        .split("/")
        .filter(Boolean)
        .pop()
        || ""
    );


const $ = id =>
    document.getElementById(id);


function escText(
    value
){
    return String(
        value ?? "-"
    );
}


function pretty(
    value
){

    if(
        value===null
        || value===undefined
    ){
        return "-";
    }

    try{
        return JSON.stringify(
            value,
            null,
            2
        );
    }catch(_){
        return String(value);
    }
}


async function api(
    url
){

    const response=await fetch(
        url,
        {
            credentials:
                "same-origin",

            headers:{
                "Accept":
                    "application/json"
            }
        }
    );


    if(
        response.status===401
        || response.status===403
        || response.status===302
    ){
        location.href="/login";
        throw new Error(
            "authentication required"
        );
    }


    if(response.status===404){
        throw new Error(
            "Config not found"
        );
    }


    if(!response.ok){
        throw new Error(
            "HTTP "
            +response.status
        );
    }


    return await response.json();
}


function showError(
    error
){

    const box=$(
        "errorBox"
    );

    box.style.display=
        "block";

    box.textContent=
        String(
            error?.message
            || error
        );
}


async function load(){

    $("configId").textContent=
        CONFIG_ID;


    try{

        const data=await api(
            "/api/config/"
            +encodeURIComponent(
                CONFIG_ID
            )
        );


        const summary=
            data.summary || {};

        const config=
            data.config || {};


        $("type").textContent=
            escText(
                summary.config_type
            );


        $("health").textContent=
            escText(
                summary.health_status
            );


        $("country").textContent=
            summary.country_code
            ?(
                summary.country_code
                +(
                    summary.country_name
                    ?" · "
                    +summary.country_name
                    :""
                )
            )
            :"Unresolved";


        $("countryState").textContent=
            escText(
                summary.country_state
            );


        $("exitIp").textContent=
            escText(
                summary.exit_ip
            );


        $("lifecycleState").textContent=
            escText(
                summary.lifecycle_state
            );


        $("sources").textContent=
            Number(
                summary.source_count
                || 0
            ).toLocaleString();


        $("lastSeen").textContent=
            escText(
                summary.last_seen
            );


        $("identity").textContent=
            pretty(
                data.country_identity
            );


        $("pipeline").textContent=
            pretty(
                data.country_pipeline
            );


        $("healthJson").textContent=
            pretty(
                data.health
            );


        $("lifecycleJson").textContent=
            pretty(
                data.lifecycle
            );


        $("resultJson").textContent=
            pretty(
                data.country_result
            );


        $("sourceIds").textContent=
            pretty(
                config.source_ids
            );


        $("raw").textContent=
            escText(
                config.raw
            );


    }catch(error){

        console.error(error);
        showError(error);
    }
}


load();

</script>

</body>
</html>
'''


async def config_detail_page(
    request: web.Request,
) -> web.Response:

    return web.Response(
        text=HTML,
        content_type="text/html",
        charset="utf-8",
    )
PY


"$PY" -m py_compile "$DETAIL_UI"

echo "DETAIL_UI=PASS"


echo
echo "=== 3. PATCH SERVER DETAIL API / ROUTE ==="

export SERVER

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["SERVER"]
)

s=p.read_text()

MARK="PANEL_A5_CONFIG_DETAIL_API"

if MARK in s:
    print(
        "SERVER_A5_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


import_needle='''from app.panel.country_ui import (
    country_page,
)
'''

import_replacement='''from app.panel.country_ui import (
    country_page,
)

from app.panel.config_detail_ui import (
    config_detail_page,
)

# PANEL_A5_CONFIG_DETAIL_API
'''

if import_needle not in s:
    raise SystemExit(
        "ERROR=COUNTRY_UI_IMPORT_NOT_FOUND"
    )

s=s.replace(
    import_needle,
    import_replacement,
    1,
)


handler_needle='''# ============================================================
# SELF TEST
# ============================================================
'''

handler=r'''
async def api_config_detail(
    request
):
    from app.panel.read_model import (
        config_detail,
    )

    config_id=str(
        request.match_info.get(
            "config_id",
            "",
        )
    ).strip()

    data=config_detail(
        config_id
    )

    if data is None:
        return web.json_response(
            {
                "error":
                    "config_not_found",

                "config_id":
                    config_id,
            },
            status=404,
        )

    return web.json_response(
        data
    )


'''

if handler_needle not in s:
    raise SystemExit(
        "ERROR=HANDLER_INSERT_POINT_NOT_FOUND"
    )

s=s.replace(
    handler_needle,
    handler+handler_needle,
    1,
)


route_needle='''    app.router.add_get(
        "/country",
        country_page
    )
'''

route_replacement='''    app.router.add_get(
        "/country",
        country_page
    )

    app.router.add_get(
        "/config/{config_id}",
        config_detail_page
    )

    app.router.add_get(
        "/api/config/{config_id}",
        api_config_detail
    )
'''

if route_needle not in s:
    raise SystemExit(
        "ERROR=COUNTRY_ROUTE_NOT_FOUND"
    )

s=s.replace(
    route_needle,
    route_replacement,
    1,
)

p.write_text(s)

print(
    "SERVER_DETAIL_PATCH=PASS"
)
PY


echo
echo "=== 4. MAKE COUNTRY TABLE IDS CLICKABLE ==="

export COUNTRY_UI

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["COUNTRY_UI"]
)

s=p.read_text()

MARK="PANEL_A5_DETAIL_LINK"

if MARK in s:
    print(
        "COUNTRY_DETAIL_LINK_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


needle='''                    +"<td class='mono' "
                    +"title='"
                    +esc(id)
                    +"'>"
                    +esc(shortId)
                    +"</td>"
'''

replacement='''                    +"<td class='mono' "
                    +"title='"
                    +esc(id)
                    +"'>"
                    +"<a "
                    +"href='/config/"
                    +encodeURIComponent(id)
                    +"' "
                    +"style='color:inherit;"
                    +"text-decoration:none'>"
                    +esc(shortId)
                    +"</a>"
                    +"</td>"
                    // PANEL_A5_DETAIL_LINK
'''

if needle not in s:
    raise SystemExit(
        "ERROR=COUNTRY_CONFIG_CELL_NOT_FOUND"
    )

s=s.replace(
    needle,
    replacement,
    1,
)

p.write_text(s)

print(
    "COUNTRY_DETAIL_LINK_PATCH=PASS"
)
PY


echo
echo "=== 5. COMPILE ALL PANEL MODULES ==="

"$PY" -m py_compile \
"$MODEL" \
"$COUNTRY_UI" \
"$DETAIL_UI" \
"$SERVER"

echo "COMPILE=PASS"


echo
echo "=== 6. DETAIL MODEL LIVE TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.read_model import (
    query_configs,
    config_detail,
)

q=query_configs(
    limit=20,
)

assert q["items"]

cid=q["items"][0][
    "config_id"
]

print(
    "TEST_CONFIG_ID=",
    cid,
)

detail=config_detail(
    cid
)

assert detail is not None

assert detail[
    "config_id"
]==cid

assert "summary" in detail
assert "config" in detail
assert "health" in detail
assert "lifecycle" in detail
assert "country_identity" in detail
assert "country_pipeline" in detail
assert "country_result" in detail

print(
    "DETAIL_KEYS=",
    sorted(
        detail.keys()
    ),
)

print(
    "DETAIL_MODEL=PASS"
)
PY


echo
echo "=== 7. ROUTE CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import (
    create_app,
)

app=create_app()

routes=set()

for r in app.router.routes():

    try:
        path=r.resource.canonical
    except Exception:
        continue

    routes.add(
        (
            r.method,
            path,
        )
    )


required={
    (
        "GET",
        "/config/{config_id}",
    ),
    (
        "GET",
        "/api/config/{config_id}",
    ),
    (
        "GET",
        "/country",
    ),
}

print(
    "MISSING=",
    required-routes,
)

assert not (
    required-routes
)

print(
    "DETAIL_ROUTES=PASS"
)
PY


echo
echo "=== 8. DIRECT DETAIL HANDLER TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import asyncio

from aiohttp.test_utils import (
    make_mocked_request,
)

from app.panel.read_model import (
    query_configs,
)

from app.panel.server import (
    api_config_detail,
)

from app.panel.config_detail_ui import (
    config_detail_page,
)


async def main():

    q=query_configs(
        limit=1,
    )

    cid=q[
        "items"
    ][0][
        "config_id"
    ]


    req=make_mocked_request(
        "GET",
        "/api/config/"+cid,
        match_info={
            "config_id":cid,
        },
    )

    response=await api_config_detail(
        req
    )

    print(
        "API_STATUS=",
        response.status,
    )

    assert response.status==200


    page=await config_detail_page(
        make_mocked_request(
            "GET",
            "/config/"+cid,
        )
    )

    print(
        "PAGE_STATUS=",
        page.status,
    )

    assert page.status==200

    body=page.text

    for x in [
        "Config Detail",
        "Country Identity",
        "Country Pipeline",
        "Country Evidence",
        "Raw Config",
        "/api/config/",
    ]:
        assert x in body


asyncio.run(main())

print(
    "DIRECT_DETAIL_TEST=PASS"
)
PY


echo
echo "=== 9. STATIC READ-ONLY CONTRACT ==="

if grep -nE \
'systemctl|subprocess|rmtree|unlink\(|write_text|write_bytes|remove\(' \
"$DETAIL_UI"
then
    echo "ERROR=DETAIL_UI_MUTATION_FOUND"
    exit 1
fi

echo "DETAIL_UI_READ_ONLY=PASS"


echo
echo "=== 10. RESTART PANEL ONLY ==="

systemctl restart \
config-location-panel.service

sleep 4

test "$(
    systemctl is-active \
    config-location-panel.service
)" = active

echo "PANEL_RESTART=PASS"


echo
echo "=== 11. LIVE AUTH PROTECTION ==="

"$PY" <<'PY'
import http.client

paths=[
    "/country",
    "/config/test-config",
    "/api/config/test-config",
]

for path in paths:

    conn=http.client.HTTPConnection(
        "127.0.0.1",
        4040,
        timeout=10,
    )

    conn.request(
        "GET",
        path,
    )

    r=conn.getresponse()

    status=r.status
    location=r.getheader(
        "Location"
    )

    r.read()
    conn.close()

    print(
        path,
        status,
        location,
    )

    assert status==302
    assert location=="/login"


print(
    "DETAIL_AUTH=PASS"
)
PY


echo
echo "=== 12. CORE SERVICES ==="

for S in \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$S" 2>/dev/null || true
    )

    echo "$S=$X"

    test "$X" = active
done

echo "CORE_SERVICES=PASS"


echo
echo "=== 13. COUNTRY CONSISTENCY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

I=Path(
    "/var/lib/config-location/"
    "country/country-identity"
)

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

bad=[]
checked=0

for ip in I.glob("*.json"):

    try:
        identity=json.loads(
            ip.read_text()
        )
    except Exception:
        continue

    if not (
        identity.get("locked") is True
        and identity.get("country_code")
    ):
        continue

    cid=str(
        identity.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue

    try:
        pipeline=json.loads(
            pp.read_text()
        )
    except Exception:
        continue

    checked+=1

    if (
        str(
            identity.get(
                "country_code"
            )
            or ""
        ).upper()
        !=
        str(
            pipeline.get(
                "country_code"
            )
            or ""
        ).upper()
    ):
        bad.append(cid)


print(
    "CHECKED=",
    checked,
)

print(
    "COUNTRY_CONFLICTS=",
    len(bad),
)

assert not bad

print(
    "COUNTRY_CONSISTENCY=PASS"
)
PY


echo
echo "======================================================"
echo "PANEL_A5=PASS"
echo "CONFIG_DETAIL_API=READY"
echo "CONFIG_DETAIL_PAGE=READY"
echo "COUNTRY_TABLE_LINKS=READY"
echo "DETAIL_READ_ONLY=YES"
echo "AUTH_PROTECTED=YES"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A6-EVENTBUS-FORENSIC"
echo "======================================================"
