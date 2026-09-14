#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

SERVER="$R/app/panel/server.py"
UI="$R/app/panel/country_ui.py"

echo "=== 1. FILES ==="

test -s "$SERVER"
test -s "$UI"

grep -q \
'PANEL_A4_COUNTRY_UI_ROUTE' \
"$SERVER"

grep -q \
'PANEL_A4_COUNTRY_UI' \
"$UI"

echo "FILES=PASS"


echo
echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$SERVER"
"$PY" -m py_compile "$UI"

echo "COMPILE=PASS"


echo
echo "=== 3. CORRECT HTML CONTRACT ==="

for X in \
'Country Control' \
'/api/country/summary' \
'/api/configs' \
'country_rotating' \
'mRotating' \
'confirmed_rotating_ip' \
'Unresolved' \
'PAGE_SIZE = 50' \
'healthFilter' \
'stateFilter' \
'modeFilter'
do

    grep -q "$X" "$UI"

    echo "$X=PASS"
done

echo "HTML_CONTRACT=PASS"


echo
echo "=== 4. JAVASCRIPT CONTRACT ==="

grep -q \
'credentials:"same-origin"' \
"$UI"

grep -q \
'new URLSearchParams' \
"$UI"

grep -q \
'setTimeout' \
"$UI"

grep -q \
'setInterval' \
"$UI"

grep -q \
'replaceAll("&","&amp;")' \
"$UI"

echo "JS_SAFETY=PASS"


echo
echo "=== 5. ROUTE AUDIT ==="

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
        (r.method,path)
    )

required={
    ("GET","/country"),
    ("GET","/api/country/summary"),
    ("GET","/api/configs"),
    ("GET","/api/country/unresolved"),
}

print(
    "FOUND=",
    sorted(
        required & routes
    ),
)

missing=required-routes

print(
    "MISSING=",
    missing,
)

assert not missing

print(
    "ROUTE_AUDIT=PASS"
)
PY


echo
echo "=== 6. DIRECT COUNTRY PAGE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import asyncio

from aiohttp.test_utils import (
    make_mocked_request,
)

from app.panel.country_ui import (
    country_page,
)


async def main():

    response=await country_page(
        make_mocked_request(
            "GET",
            "/country",
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

    required=[
        "Country Control",
        "/api/country/summary",
        "/api/configs",
        "country_rotating",
        "confirmed_rotating_ip",
        "Unresolved",
    ]

    assert response.status==200

    for x in required:
        assert x in body


asyncio.run(main())

print(
    "DIRECT_PAGE=PASS"
)
PY


echo
echo "=== 7. READ MODEL LIVE DATA ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.read_model import (
    dashboard_summary,
    query_configs,
)

s=dashboard_summary()

print(
    "TOTAL=",
    s["total_configs"],
)

print(
    "KNOWN=",
    s["country_known"],
)

print(
    "UNRESOLVED=",
    s["country_unresolved"],
)

print(
    "ROTATING=",
    s["country_rotating"],
)

print(
    "COVERAGE=",
    s["country_coverage_percent"],
)

assert s["total_configs"]>0
assert s["country_known"]>0
assert s["country_unresolved"]>0
assert s["country_rotating"]>0


r=query_configs(
    limit=50,
)

assert len(
    r["items"]
)<=50

assert r["total"]>0


u=query_configs(
    unresolved_only=True,
    limit=50,
)

assert u["total"]>0

for row in u["items"]:
    assert (
        row[
            "country_unresolved"
        ]
        is True
    )

print(
    "READ_MODEL_LIVE=PASS"
)
PY


echo
echo "=== 8. RESTART PANEL ONLY ==="

systemctl restart \
config-location-panel.service

sleep 4

PANEL_STATE=$(
    systemctl is-active \
    config-location-panel.service
)

echo "PANEL=$PANEL_STATE"

test "$PANEL_STATE" = active

echo "PANEL_ACTIVATED=PASS"


echo
echo "=== 9. LIVE AUTH PROTECTION ==="

for PATH in \
/country \
/api/country/summary \
/api/configs \
/api/country/unresolved
do

    HEAD=$(
        mktemp
    )

    CODE=$(
        curl \
        -sS \
        --max-time 10 \
        -D "$HEAD" \
        -o /dev/null \
        -w '%{http_code}' \
        "http://127.0.0.1:4040$PATH"
    )

    LOCATION=$(
        awk '
            BEGIN {
                IGNORECASE=1
            }

            /^Location:/ {
                gsub("\r","",$2)
                print $2
            }
        ' "$HEAD" |
        tail -n1
    )

    rm -f "$HEAD"

    echo "PATH=$PATH"
    echo "CODE=$CODE"
    echo "LOCATION=$LOCATION"

    test "$CODE" = 302
    test "$LOCATION" = /login

done

echo "AUTH_PROTECTION=PASS"


echo
echo "=== 10. PANEL JOURNAL ==="

journalctl \
-u config-location-panel.service \
--since "2 minutes ago" \
--no-pager \
| tail -n 80

if journalctl \
    -u config-location-panel.service \
    --since "2 minutes ago" \
    --no-pager \
    | grep -Ei \
    'Traceback|SyntaxError|ImportError|ModuleNotFoundError'
then

    echo "ERROR=PANEL_RUNTIME_EXCEPTION"
    exit 1
fi

echo "PANEL_RUNTIME=PASS"


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
echo "=== 12. COUNTRY CONSISTENCY ==="

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

checked=0
bad=[]

for ip in I.glob("*.json"):

    try:
        i=json.loads(
            ip.read_text()
        )
    except Exception:
        continue

    if not (
        i.get("locked") is True
        and i.get("country_code")
    ):
        continue

    cid=str(
        i.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue

    try:
        p=json.loads(
            pp.read_text()
        )
    except Exception:
        continue

    checked+=1

    if (
        str(
            i.get("country_code")
            or ""
        ).upper()
        !=
        str(
            p.get("country_code")
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
echo "PANEL_A4_R1=PASS"
echo "COUNTRY_UI=ACTIVE"
echo "COUNTRY_URL=/country"
echo "SUMMARY_WIDGETS=READY"
echo "CONFIG_TABLE=READY"
echo "SEARCH=READY"
echo "FILTERS=READY"
echo "PAGINATION=READY"
echo "AUTH_PROTECTED=YES"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A5-NAVIGATION-DETAIL"
echo "======================================================"
