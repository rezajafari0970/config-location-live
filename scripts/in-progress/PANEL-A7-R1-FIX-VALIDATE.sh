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
B="$R/backups/PANEL-A7-R1-$TS"

mkdir -p "$B"

for F in \
"$SERVER" \
"$PUB_MODEL" \
"$PUB_UI" \
"$COUNTRY_UI" \
"$OPS_UI" \
"$DETAIL_UI"
do
    if [ -f "$F" ]; then
        cp -a "$F" "$B/$(basename "$F").before"
    fi
done

echo "BACKUP=$B"


echo
echo "=== 1. INSPECT REAL PUBLISH HANDLER ==="

grep -nE \
'api_publish_status|publish_status|/api/publish/status|def .*publish|async def .*publish' \
"$SERVER" \
| head -n 200 || true


echo
echo "=== 2. PATCH PUBLISH READ MODEL WITH HANDLER FALLBACK ==="

export PUB_MODEL SERVER

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["PUB_MODEL"]
)

s=p.read_text()

MARK="PANEL_A7_R1_HANDLER_FALLBACK"

if MARK in s:
    print("PUBLISH_MODEL_R1_ALREADY_PRESENT=YES")
    raise SystemExit(0)


needle='''def _discover_publish_status() -> dict[str, Any]:
'''

if needle not in s:
    raise SystemExit(
        "ERROR=PUBLISH_DISCOVERY_FUNCTION_NOT_FOUND"
    )


# Insert a safer handler-source fallback near function end.
old='''    # Fallback discovery from panel API helper.
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
'''

new='''    # PANEL_A7_R1_HANDLER_FALLBACK
    # Fallback: inspect the existing canonical panel handler.
    try:

        import app.panel.server as panel_server

        handler=getattr(
            panel_server,
            "api_publish_status",
            None,
        )

        source=(
            inspect.getsource(handler)
            if callable(handler)
            else ""
        )

    except Exception:

        handler=None
        source=""


    if callable(handler):

        # Try to discover zero-argument callable names used
        # inside the existing canonical handler.
        names=re.findall(
            r"([A-Za-z_][A-Za-z0-9_]*)\\s*\\(",
            source,
        )

        skip={
            "web",
            "json_response",
            "str",
            "int",
            "float",
            "bool",
            "dict",
            "list",
            "set",
            "tuple",
            "len",
        }

        for name in names:

            if name in skip:
                continue

            obj=getattr(
                panel_server,
                name,
                None,
            )

            if not callable(obj):
                continue

            try:
                value=obj()
            except TypeError:
                continue
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
                    "app.panel.server."
                    +name
                )

                return result


    return {
        "_source":
            "unresolved",

        "_note":
            "canonical status function not directly importable",

        "_api_handler_present":
            bool(source),
    }
'''

if old not in s:
    raise SystemExit(
        "ERROR=OLD_FALLBACK_BLOCK_NOT_FOUND"
    )

s=s.replace(
    old,
    new,
    1,
)

p.write_text(s)

print(
    "PUBLISH_MODEL_R1_PATCH=PASS"
)
PY


"$PY" -m py_compile "$PUB_MODEL"

echo "PUBLISH_MODEL_COMPILE=PASS"


echo
echo "=== 3. FLEXIBLE NAVIGATION PATCH ==="

export COUNTRY_UI OPS_UI DETAIL_UI

"$PY" <<'PY'
from pathlib import Path
import os
import re

files=[
    Path(os.environ["COUNTRY_UI"]),
    Path(os.environ["OPS_UI"]),
    Path(os.environ["DETAIL_UI"]),
]

for p in files:

    if not p.is_file():
        continue

    s=p.read_text()

    if "PANEL_A7_PUBLISH_NAV" in s:
        print(
            p.name,
            "NAV_ALREADY_PRESENT",
        )
        continue


    # Try to insert before Dashboard link, regardless of
    # whitespace/order/class attribute style.
    patterns=[
        r'(<a[^>]+href="/"\s*[^>]*>\s*(?:داشبورد|Dashboard)\s*</a>)',
        r'(<a[^>]*class="btn"[^>]*href="/"[^>]*>\s*(?:داشبورد|Dashboard)\s*</a>)',
    ]

    match=None

    for pattern in patterns:

        match=re.search(
            pattern,
            s,
            flags=re.S,
        )

        if match:
            break


    if not match:

        raise SystemExit(
            f"ERROR=NAV_INSERT_POINT_NOT_FOUND:{p}"
        )


    publish_link='''<a class="btn"
               href="/publish">
                Publish
            </a>

            <!-- PANEL_A7_PUBLISH_NAV -->

            '''

    s=(
        s[:match.start()]
        +publish_link
        +s[match.start():]
    )

    p.write_text(s)

    print(
        p.name,
        "NAV_PATCH=PASS",
    )


print(
    "PUBLISH_NAV_ALL=PASS"
)
PY


echo
echo "=== 4. COMPILE PANEL ==="

"$PY" -m py_compile \
"$SERVER" \
"$PUB_MODEL" \
"$PUB_UI" \
"$COUNTRY_UI" \
"$OPS_UI" \
"$DETAIL_UI"

echo "COMPILE=PASS"


echo
echo "=== 5. ROUTE CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import create_app

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
    ("GET","/publish"),
    ("GET","/api/publish/summary"),
    ("GET","/sub/all"),
    ("GET","/sub/{config_type}"),
}

print(
    "MISSING=",
    required-routes,
)

assert not (
    required-routes
)

print(
    "A7_ROUTE_CONTRACT=PASS"
)
PY


echo
echo "=== 6. PUBLISH MODEL AS CONFIGLOC ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
from app.panel.publish_read_model import publish_summary

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

assert "/sub/all" in s["routes"]

assert "/sub/{config_type}" in s["routes"]

print(
    "CONFIGLOC_PUBLISH_MODEL=PASS"
)
PY


echo
echo "=== 7. DIRECT PUBLISH PAGE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import asyncio

from aiohttp.test_utils import make_mocked_request
from app.panel.publish_ui import publish_page


async def main():

    response=await publish_page(
        make_mocked_request(
            "GET",
            "/publish",
        )
    )

    body=response.text

    print(
        "STATUS=",
        response.status,
    )

    print(
        "BODY_BYTES=",
        len(
            body.encode(
                "utf-8"
            )
        ),
    )

    assert response.status==200

    for item in [
        "Publish & Subscriptions",
        "/api/publish/summary",
        "Subscription Links",
        "Publish Status",
    ]:
        assert item in body


asyncio.run(main())

print(
    "DIRECT_PUBLISH_PAGE=PASS"
)
PY


echo
echo "=== 8. RESTART PANEL ONLY ==="

systemctl restart \
config-location-panel.service

sleep 4

test "$(
    systemctl is-active \
    config-location-panel.service
)" = active

echo "PANEL_RESTART=PASS"


echo
echo "=== 9. AUTH PROTECTION ==="

"$PY" <<'PY'
import http.client

for path in [
    "/publish",
    "/api/publish/summary",
]:

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
echo "=== 10. AUTHENTICATED PUBLISH HTTP ==="

"$PY" <<'PY'
import http.client
import json
import urllib.parse
from pathlib import Path

env={}

for line in Path(
    "/etc/config-location/panel.env"
).read_text().splitlines():

    line=line.strip()

    if (
        not line
        or line.startswith("#")
        or "=" not in line
    ):
        continue

    k,v=line.split(
        "=",
        1,
    )

    env[k.strip()]=(
        v.strip()
        .strip('"')
        .strip("'")
    )


body=urllib.parse.urlencode(
    {
        "username":
            env[
                "CONFIGLOC_ADMIN_USER"
            ],

        "password":
            env[
                "CONFIGLOC_ADMIN_PASSWORD"
            ],
    }
)


conn=http.client.HTTPConnection(
    "127.0.0.1",
    4040,
    timeout=15,
)

conn.request(
    "POST",
    "/login",
    body=body,
    headers={
        "Content-Type":
            "application/x-www-form-urlencoded",
    },
)

r=conn.getresponse()

headers=r.getheaders()

r.read()
conn.close()


cookie=None

for key,value in headers:

    if key.lower()=="set-cookie":

        cookie=value.split(
            ";",
            1,
        )[0]

        break

assert cookie


conn=http.client.HTTPConnection(
    "127.0.0.1",
    4040,
    timeout=30,
)

conn.request(
    "GET",
    "/api/publish/summary",
    headers={
        "Cookie":cookie,
        "Accept":
            "application/json",
        "Cache-Control":
            "no-cache",
    },
)

r=conn.getresponse()

raw=r.read().decode(
    "utf-8",
    errors="replace",
)

status=r.status

conn.close()

print(
    "HTTP_STATUS=",
    status,
)

print(
    "BODY=",
    raw[:10000],
)

assert status==200

data=json.loads(raw)

assert "/sub/all" in data[
    "routes"
]

print(
    "LIVE_PUBLISH_HTTP=PASS"
)
PY


echo
echo "=== 11. CORE SERVICES ==="

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
echo "PANEL_A7_R1=PASS"
echo "PUBLISH_UI=/publish"
echo "SUB_ALL=READY"
echo "TYPE_SUBSCRIPTIONS=READY"
echo "PUBLISH_NAV=READY"
echo "CANONICAL_STATUS_SOURCE=DISCOVERED_IF_IMPORTABLE"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A8"
echo "======================================================"
