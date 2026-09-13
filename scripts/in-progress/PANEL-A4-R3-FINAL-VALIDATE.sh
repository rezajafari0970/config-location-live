#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. PANEL STATE ==="

test "$(
    systemctl is-active \
    config-location-panel.service
)" = active

echo "PANEL=active"


echo
echo "=== 2. AUTH PROTECTION WITHOUT CURL ==="

"$PY" <<'PY'
import http.client

paths=[
    "/country",
    "/api/country/summary",
    "/api/configs",
    "/api/country/unresolved",
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
        headers={
            "Accept":"text/html,application/json",
        },
    )

    response=conn.getresponse()

    status=response.status
    location=response.getheader(
        "Location"
    )

    response.read()
    conn.close()

    print(
        "PATH=",
        path,
    )

    print(
        "STATUS=",
        status,
    )

    print(
        "LOCATION=",
        location,
    )

    assert status==302
    assert location=="/login"


print(
    "AUTH_PROTECTION=PASS"
)
PY


echo
echo "=== 3. ROUTE CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import (
    create_app,
)

app=create_app()

routes=set()

for route in app.router.routes():

    try:
        path=route.resource.canonical
    except Exception:
        continue

    routes.add(
        (
            route.method,
            path,
        )
    )


required={
    ("GET","/country"),
    ("GET","/api/country/summary"),
    ("GET","/api/configs"),
    ("GET","/api/country/unresolved"),
}

missing=required-routes

print(
    "MISSING=",
    missing,
)

assert not missing

print(
    "ROUTE_CONTRACT=PASS"
)
PY


echo
echo "=== 4. DIRECT PAGE CONTRACT ==="

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
        "healthFilter",
        "stateFilter",
        "modeFilter",
    ]

    assert response.status==200

    for item in required:
        assert item in body


asyncio.run(main())

print(
    "DIRECT_PAGE_CONTRACT=PASS"
)
PY


echo
echo "=== 5. LIVE READ MODEL ==="

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

print(
    "HEALTH=",
    s["health"],
)

assert s["total_configs"]>0
assert s["country_known"]>0
assert s["country_unresolved"]>0


normal=query_configs(
    limit=50,
)

assert normal["total"]>0
assert len(normal["items"])<=50


unresolved=query_configs(
    unresolved_only=True,
    limit=50,
)

assert unresolved["total"]>0

for row in unresolved["items"]:

    assert row[
        "country_unresolved"
    ] is True


print(
    "READ_MODEL_LIVE=PASS"
)
PY


echo
echo "=== 6. PANEL RUNTIME ERRORS ==="

J=$(
    journalctl \
    -u config-location-panel.service \
    --since "15 minutes ago" \
    --no-pager \
    2>&1 || true
)

printf '%s\n' "$J" \
| tail -n 100


if printf '%s\n' "$J" \
| grep -Ei \
'Traceback|SyntaxError|ImportError|ModuleNotFoundError'
then

    echo "ERROR=PANEL_RUNTIME_EXCEPTION"
    exit 1
fi

echo "PANEL_RUNTIME=PASS"


echo
echo "=== 7. CORE SERVICES ==="

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
echo "=== 8. COUNTRY CONSISTENCY ==="

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
echo "PANEL_A4_R3=PASS"
echo "COUNTRY_UI=ACTIVE"
echo "COUNTRY_URL=/country"
echo "AUTH_PROTECTED=YES"
echo "CURL_REQUIRED=NO"
echo "READ_MODEL=LIVE"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A5-NAVIGATION-DETAIL"
echo "======================================================"
