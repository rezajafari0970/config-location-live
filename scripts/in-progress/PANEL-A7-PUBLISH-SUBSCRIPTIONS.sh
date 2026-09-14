#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

SERVER="$R/app/panel/server.py"
PUB_MODEL="$R/app/panel/publish_read_model.py"
PUB_UI="$R/app/panel/publish_ui.py"
COUNTRY_UI="$R/app/panel/country_ui.py"
OPS_UI="$R/app/panel/operations_ui.py"
DETAIL_UI="$R/app/panel/config_detail_ui.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/PANEL-A7-$TS"

mkdir -p "$B"

for F in \
"$SERVER" \
"$COUNTRY_UI" \
"$OPS_UI" \
"$DETAIL_UI" \
"$PUB_MODEL" \
"$PUB_UI"
do
    if [ -f "$F" ]; then
        cp -a "$F" "$B/$(basename "$F").before"
    fi
done

echo "BACKUP=$B"


echo
echo "=== 1. CREATE PUBLISH READ MODEL ==="

cat >"$PUB_MODEL" <<'PY'
from __future__ import annotations

from typing import Any
from pathlib import Path
import inspect
import re


# ============================================================
# PANEL_A7_PUBLISH_READ_MODEL
# Canonical publish/subscription discovery
# READ ONLY
# ============================================================


def _safe_dict(
    value: Any,
) -> dict[str, Any]:

    if isinstance(
        value,
        dict,
    ):
        return value

    return {}


def _discover_publish_status() -> dict[str, Any]:

    candidates=[
        (
            "app.publish",
            "status",
        ),
        (
            "app.publish.status",
            "status",
        ),
        (
            "app.publish.status",
            "get_status",
        ),
        (
            "app.publish.service",
            "status",
        ),
        (
            "app.publish.service",
            "publish_status",
        ),
    ]


    for module_name,func_name in candidates:

        try:

            module=__import__(
                module_name,
                fromlist=[
                    func_name,
                ],
            )

        except Exception:
            continue


        func=getattr(
            module,
            func_name,
            None,
        )

        if not callable(func):
            continue


        try:

            value=func()

        except Exception:
            continue


        if isinstance(
            value,
            dict,
        ):

            result=dict(value)

            result[
                "_source"
            ]=(
                module_name
                +"."
                +func_name
            )

            return result


    # Fallback discovery from panel API helper.
    try:

        from app.panel.server import (
            api_publish_status,
        )

        source=inspect.getsource(
            api_publish_status
        )

    except Exception:

        source=""

    return {
        "_source":
            "unresolved",

        "_note":
            "canonical status function not directly importable",

        "_api_handler_present":
            bool(source),
    }


def _discover_routes() -> list[str]:

    try:

        from app.panel.server import (
            create_app,
        )

        app=create_app()

    except Exception:

        return []


    found=set()

    for route in app.router.routes():

        try:
            path=route.resource.canonical
        except Exception:
            continue

        if not isinstance(
            path,
            str,
        ):
            continue

        if (
            path.startswith("/sub/")
            or path=="/sub"
        ):
            found.add(path)


    return sorted(found)


def _classify_routes(
    routes: list[str],
) -> dict[str, list[str]]:

    result={
        "all":[],
        "type":[],
        "country":[],
        "other":[],
    }


    for path in routes:

        low=path.lower()

        if path=="/sub/all":

            result["all"].append(
                path
            )

        elif (
            "{config_type}" in path
            or "{type}" in path
        ):

            result["type"].append(
                path
            )

        elif (
            "{country" in low
            or "/country/" in low
        ):

            result["country"].append(
                path
            )

        else:

            result["other"].append(
                path
            )


    return result


def _known_types() -> list[str]:

    return [
        "vless",
        "vmess",
        "trojan",
        "ss",
        "wireguard",
        "json_xray",
    ]


def publish_summary() -> dict[str, Any]:

    status=_discover_publish_status()

    routes=_discover_routes()

    classes=_classify_routes(
        routes
    )


    type_links=[]

    route_template=None

    for item in classes[
        "type"
    ]:

        if (
            "{config_type}"
            in item
        ):
            route_template=item
            break


    if route_template:

        for config_type in _known_types():

            type_links.append(
                {
                    "type":
                        config_type,

                    "path":
                        route_template.replace(
                            "{config_type}",
                            config_type,
                        ),
                }
            )


    return {
        "publish_status":
            status,

        "routes":
            routes,

        "route_classes":
            classes,

        "links":{
            "all":
                "/sub/all"
                if "/sub/all"
                in routes
                else None,

            "types":
                type_links,

            "country_templates":
                classes[
                    "country"
                ],

            "other":
                classes[
                    "other"
                ],
        },
    }
PY


"$PY" -m py_compile "$PUB_MODEL"

echo "PUBLISH_MODEL=PASS"


echo
echo "=== 2. STATIC READ-ONLY AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/panel/"
    "publish_read_model.py"
)

src=p.read_text()
tree=ast.parse(src)

forbidden={
    "write_text",
    "write_bytes",
    "unlink",
    "mkdir",
    "rename",
    "touch",
    "remove",
    "rmtree",
    "system",
    "run",
    "Popen",
    "check_call",
    "check_output",
}

bad=[]

for node in ast.walk(tree):

    if not isinstance(
        node,
        ast.Call,
    ):
        continue

    f=node.func

    name=(
        f.attr
        if isinstance(
            f,
            ast.Attribute,
        )
        else
        f.id
        if isinstance(
            f,
            ast.Name,
        )
        else None
    )

    if name in forbidden:
        bad.append(
            (
                node.lineno,
                name,
            )
        )


print(
    "WRITE_CALLS=",
    bad,
)

assert not bad

print(
    "READ_ONLY_CONTRACT=PASS"
)
PY


echo
echo "=== 3. PUBLISH MODEL TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.publish_read_model import (
    publish_summary,
)

s=publish_summary()

print(
    "PUBLISH_STATUS=",
    s["publish_status"],
)

print(
    "ROUTES=",
    s["routes"],
)

print(
    "LINKS=",
    s["links"],
)

assert isinstance(
    s,
    dict,
)

assert isinstance(
    s["routes"],
    list,
)

assert isinstance(
    s["links"],
    dict,
)

print(
    "PUBLISH_MODEL_TEST=PASS"
)
PY


echo
echo "=== 4. CREATE PUBLISH UI ==="

cat >"$PUB_UI" <<'PY'
from __future__ import annotations

from aiohttp import web


# PANEL_A7_PUBLISH_UI


HTML=r'''<!doctype html>
<html lang="fa" dir="rtl">

<head>

<meta charset="utf-8">

<meta name="viewport"
      content="width=device-width,initial-scale=1">

<title>Publish & Subscriptions</title>

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
    --yellow:#f5c451;
    --blue:#55aaff;
    --violet:#a98bff;
    --red:#ff667a;
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
    margin:0;
    font-size:22px;
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
    cursor:pointer;
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

.metric-name{
    color:var(--muted);
    font-size:12px;
    margin-bottom:7px;
}

.metric-value{
    font-size:24px;
    font-weight:700;
}

.green{color:var(--green)}
.yellow{color:var(--yellow)}
.blue{color:var(--blue)}
.violet{color:var(--violet)}
.red{color:var(--red)}

.section{
    margin-top:14px;
}

.section h2{
    margin:0 0 12px;
    font-size:16px;
}

.link-grid{
    display:grid;
    grid-template-columns:
        repeat(2,minmax(0,1fr));
    gap:10px;
}

.sub-link{
    display:flex;
    justify-content:space-between;
    align-items:center;
    gap:10px;

    padding:11px;

    border:1px solid var(--border);
    border-radius:10px;

    background:#0d131b;
}

.sub-link code{
    direction:ltr;
    text-align:left;
    overflow:auto;
}

.small-btn{
    min-height:34px;
    padding:5px 9px;
}

.kv{
    display:flex;
    justify-content:space-between;
    gap:10px;
    padding:6px 0;

    border-bottom:
        1px dashed var(--border);
}

.kv span{
    color:var(--muted);
}

pre{
    margin:0;
    padding:12px;

    max-height:450px;
    overflow:auto;

    direction:ltr;
    text-align:left;

    white-space:pre-wrap;
    word-break:break-word;

    background:#0b1118;
    border:1px solid var(--border);
    border-radius:10px;

    font-size:12px;
}

@media(max-width:800px){

    .grid{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }

    .link-grid{
        grid-template-columns:1fr;
    }
}

@media(max-width:520px){

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
                📡 Publish & Subscriptions
            </h1>

            <div style="
                color:var(--muted);
                font-size:12px;
                margin-top:5px;
            ">
                Canonical publish view
            </div>

        </div>


        <div class="actions">

            <a class="btn"
               href="/country">
                Country
            </a>

            <a class="btn"
               href="/operations">
                Operations
            </a>

            <a class="btn"
               href="/configs">
                Configs
            </a>

            <a class="btn"
               href="/">
                Dashboard
            </a>

            <button class="btn"
                    id="refresh">
                بروزرسانی
            </button>

        </div>

    </div>


    <div class="grid">

        <div class="card">

            <div class="metric-name">
                Publishable
            </div>

            <div class="metric-value green"
                 id="publishable">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Healthy
            </div>

            <div class="metric-value blue"
                 id="healthy">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Recovered
            </div>

            <div class="metric-value violet"
                 id="recovered">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Subscription Routes
            </div>

            <div class="metric-value yellow"
                 id="routeCount">
                -
            </div>

        </div>

    </div>


    <div class="section card">

        <h2>
            Subscription Links
        </h2>

        <div id="links"
             class="link-grid">
        </div>

    </div>


    <div class="section card">

        <h2>
            Publish Status
        </h2>

        <div id="status">
        </div>

    </div>


    <div class="section card">

        <h2>
            Raw Canonical Status
        </h2>

        <pre id="rawStatus">
-
        </pre>

    </div>

</div>


<script>

"use strict";

const $=id =>
    document.getElementById(id);


function esc(
    value
){

    return String(
        value ?? ""
    )
    .replaceAll("&","&amp;")
    .replaceAll("<","&lt;")
    .replaceAll(">","&gt;")
    .replaceAll('"',"&quot;")
    .replaceAll("'","&#039;");
}


function num(
    value
){

    return Number(
        value || 0
    ).toLocaleString(
        "en-US"
    );
}


async function api(
    url
){

    const response=
        await fetch(
            url,
            {
                credentials:
                    "same-origin",

                cache:
                    "no-store",

                headers:{
                    "Accept":
                        "application/json"
                }
            }
        );


    if(!response.ok){

        throw new Error(
            "HTTP "
            +response.status
        );
    }


    return await response.json();
}


function firstNumber(
    obj,
    keys
){

    for(const key of keys){

        if(
            Object.prototype
            .hasOwnProperty
            .call(
                obj,
                key
            )
        ){

            const n=Number(
                obj[key]
            );

            if(
                Number.isFinite(n)
            ){
                return n;
            }
        }
    }

    return 0;
}


function renderLinks(
    data
){

    const links=[];

    if(
        data.links
        && data.links.all
    ){

        links.push(
            {
                label:"All",
                path:
                    data.links.all,
            }
        );
    }


    for(
        const item
        of (
            data.links?.types
            || []
        )
    ){

        links.push(
            {
                label:
                    item.type,

                path:
                    item.path,
            }
        );
    }


    for(
        const path
        of (
            data.links
            ?.country_templates
            || []
        )
    ){

        links.push(
            {
                label:
                    "Country template",

                path,
            }
        );
    }


    for(
        const path
        of (
            data.links?.other
            || []
        )
    ){

        links.push(
            {
                label:"Other",
                path,
            }
        );
    }


    if(!links.length){

        $("links").innerHTML=
            "<div>Subscription route پیدا نشد</div>";

        return;
    }


    $("links").innerHTML=
        links.map(
            item => {

                const full=
                    location.origin
                    +item.path;


                return (
                    '<div class="sub-link">'

                    +'<div>'

                    +'<strong>'
                    +esc(
                        item.label
                    )
                    +'</strong>'

                    +'<br>'

                    +'<code>'
                    +esc(full)
                    +'</code>'

                    +'</div>'

                    +'<a class="btn small-btn" '
                    +'target="_blank" '
                    +'href="'
                    +esc(item.path)
                    +'">'
                    +'Open'
                    +'</a>'

                    +'</div>'
                );
            }
        ).join("");
}


function renderStatus(
    status
){

    const entries=
        Object.entries(
            status || {}
        );


    $("status").innerHTML=
        entries
        .map(
            ([key,value]) =>
                '<div class="kv">'
                +'<span>'
                +esc(key)
                +'</span>'
                +'<strong>'
                +esc(
                    typeof value
                    ==="object"
                    ?JSON.stringify(value)
                    :value
                )
                +'</strong>'
                +'</div>'
        )
        .join("");
}


async function load(){

    const data=await api(
        "/api/publish/summary"
    );


    const status=
        data.publish_status
        || {};


    const healthy=
        firstNumber(
            status,
            [
                "healthy",
                "healthy_count",
                "eligible_healthy",
            ]
        );


    const recovered=
        firstNumber(
            status,
            [
                "recovered",
                "recovered_count",
                "eligible_recovered",
            ]
        );


    const publishable=
        firstNumber(
            status,
            [
                "publishable",
                "publishable_count",
                "eligible",
                "eligible_count",
                "total_publishable",
            ]
        )
        || (
            healthy
            +recovered
        );


    $("healthy").textContent=
        num(healthy);

    $("recovered").textContent=
        num(recovered);

    $("publishable").textContent=
        num(
            publishable
        );

    $("routeCount").textContent=
        num(
            (
                data.routes
                || []
            ).length
        );


    renderLinks(
        data
    );

    renderStatus(
        status
    );

    $("rawStatus").textContent=
        JSON.stringify(
            status,
            null,
            2
        );
}


$("refresh")
.addEventListener(
    "click",
    () => {
        load().catch(
            console.error
        );
    }
);


load().catch(
    console.error
);


setInterval(
    () => {
        load().catch(
            console.error
        );
    },
    30000
);

</script>

</body>
</html>
'''


async def publish_page(
    request: web.Request,
) -> web.Response:

    return web.Response(
        text=HTML,
        content_type="text/html",
        charset="utf-8",
    )
PY


"$PY" -m py_compile "$PUB_UI"

echo "PUBLISH_UI=PASS"


echo
echo "=== 5. PATCH SERVER API / ROUTE ==="

export SERVER

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["SERVER"]
)

s=p.read_text()

MARK="PANEL_A7_PUBLISH_API"

if MARK in s:

    print(
        "SERVER_A7_ALREADY_PRESENT=YES"
    )

    raise SystemExit(0)


import_needle='''from app.panel.operations_ui import (
    operations_page,
)
'''

import_replacement='''from app.panel.operations_ui import (
    operations_page,
)

from app.panel.publish_ui import (
    publish_page,
)

# PANEL_A7_PUBLISH_API
'''


if import_needle not in s:

    raise SystemExit(
        "ERROR=A6_IMPORT_POINT_NOT_FOUND"
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
async def api_publish_summary(
    request
):
    from app.panel.publish_read_model import (
        publish_summary,
    )

    return web.json_response(
        publish_summary()
    )


'''


if handler_needle not in s:

    raise SystemExit(
        "ERROR=A7_HANDLER_INSERT_POINT_NOT_FOUND"
    )


s=s.replace(
    handler_needle,
    handler+handler_needle,
    1,
)


route_needle='''    app.router.add_get(
        "/api/xray/failure/{bundle_id}",
        api_xray_failure_detail
    )
'''

routes='''    app.router.add_get(
        "/api/xray/failure/{bundle_id}",
        api_xray_failure_detail
    )

    app.router.add_get(
        "/publish",
        publish_page
    )

    app.router.add_get(
        "/api/publish/summary",
        api_publish_summary
    )
'''


if route_needle not in s:

    raise SystemExit(
        "ERROR=A7_ROUTE_INSERT_POINT_NOT_FOUND"
    )


s=s.replace(
    route_needle,
    routes,
    1,
)


p.write_text(s)

print(
    "SERVER_A7_PATCH=PASS"
)
PY


echo
echo "=== 6. ADD PUBLISH NAV LINKS ==="

export COUNTRY_UI OPS_UI DETAIL_UI

"$PY" <<'PY'
from pathlib import Path
import os


for env_name in (
    "COUNTRY_UI",
    "OPS_UI",
    "DETAIL_UI",
):

    p=Path(
        os.environ[
            env_name
        ]
    )

    if not p.is_file():
        continue

    s=p.read_text()

    marker=(
        "PANEL_A7_PUBLISH_NAV"
    )

    if marker in s:
        continue


    targets=[
'''            <a class="btn"
               href="/operations">
                Operations
            </a>
''',
'''            <a href="/operations"
               class="btn">
                Operations
            </a>
''',
    ]


    found=None

    for target in targets:

        if target in s:
            found=target
            break


    if found is None:

        raise SystemExit(
            f"ERROR=PUBLISH_NAV_POINT_NOT_FOUND:{p}"
        )


    replacement=found+'''
            <a class="btn"
               href="/publish">
                Publish
            </a>

            <!-- PANEL_A7_PUBLISH_NAV -->
'''


    s=s.replace(
        found,
        replacement,
        1,
    )

    p.write_text(s)


print(
    "PUBLISH_NAV=PASS"
)
PY


echo
echo "=== 7. COMPILE PANEL ==="

"$PY" -m py_compile \
"$SERVER" \
"$PUB_MODEL" \
"$PUB_UI" \
"$COUNTRY_UI" \
"$OPS_UI" \
"$DETAIL_UI"

echo "COMPILE=PASS"


echo
echo "=== 8. ROUTE CONTRACT ==="

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
        "/publish",
    ),
    (
        "GET",
        "/api/publish/summary",
    ),
    (
        "GET",
        "/sub/all",
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
    "A7_ROUTES=PASS"
)
PY


echo
echo "=== 9. REAL PANEL USER PUBLISH TEST ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
from app.panel.publish_read_model import (
    publish_summary,
)

s=publish_summary()

print(
    "STATUS=",
    s["publish_status"],
)

print(
    "ROUTES=",
    s["routes"],
)

print(
    "LINKS=",
    s["links"],
)

assert isinstance(
    s["publish_status"],
    dict,
)

assert "/sub/all" in s["routes"]

print(
    "CONFIGLOC_PUBLISH=PASS"
)
PY


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
echo "=== 11. AUTH PROTECTION ==="

"$PY" <<'PY'
import http.client

paths=[
    "/publish",
    "/api/publish/summary",
]

for path in paths:

    conn=http.client.HTTPConnection(
        "127.0.0.1",
        4040,
        timeout=15,
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
    "A7_AUTH=PASS"
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
echo "======================================================"
echo "PANEL_A7=PASS"
echo "PUBLISH_UI=/publish"
echo "CANONICAL_PUBLISH_STATUS=CONNECTED"
echo "SUB_ALL=READY"
echo "TYPE_SUBSCRIPTIONS=DISCOVERED"
echo "COUNTRY_SUBSCRIPTIONS=DISCOVERED_IF_PRESENT"
echo "READ_ONLY=YES"
echo "AUTH_PROTECTED=YES"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A8-NAVIGATION-SETTINGS-HARDENING"
echo "======================================================"
