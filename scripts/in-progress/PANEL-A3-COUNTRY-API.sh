#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
SERVER="$R/app/panel/server.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/PANEL-A3-$TS"

mkdir -p "$B"
cp -a "$SERVER" "$B/server.py.before"

echo "BACKUP=$B"

export SERVER

echo
echo "=== 1. PATCH COUNTRY API HANDLERS ==="

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["SERVER"])
s=p.read_text()

MARK="PANEL_A3_COUNTRY_API"

if MARK in s:
    print("COUNTRY_API_ALREADY_PRESENT=YES")
    raise SystemExit(0)

needle='''# ============================================================
# SELF TEST
# ============================================================
'''

handlers=r'''
# ============================================================
# PANEL_A3_COUNTRY_API
# Country / Config read-only APIs
# ============================================================

async def api_country_summary(
    request
):
    from app.panel.read_model import (
        dashboard_summary,
    )

    return web.json_response(
        dashboard_summary()
    )


async def api_configs(
    request
):
    from app.panel.read_model import (
        query_configs,
    )

    q=request.rel_url.query

    def as_int(
        key,
        default,
    ):
        try:
            return int(
                q.get(
                    key,
                    default,
                )
            )
        except (
            TypeError,
            ValueError,
        ):
            return default


    unresolved_raw=str(
        q.get(
            "unresolved",
            "",
        )
    ).strip().lower()

    unresolved_only=(
        unresolved_raw
        in {
            "1",
            "true",
            "yes",
            "on",
        }
    )


    result=query_configs(
        search=str(
            q.get(
                "q",
                "",
            )
        ),

        config_type=str(
            q.get(
                "type",
                "",
            )
        ),

        health_status=str(
            q.get(
                "health",
                "",
            )
        ),

        country_code=str(
            q.get(
                "country",
                "",
            )
        ),

        country_state=str(
            q.get(
                "state",
                "",
            )
        ),

        unresolved_only=
            unresolved_only,

        offset=as_int(
            "offset",
            0,
        ),

        limit=as_int(
            "limit",
            100,
        ),
    )

    return web.json_response(
        result
    )


async def api_country_unresolved(
    request
):
    from app.panel.read_model import (
        query_configs,
    )

    q=request.rel_url.query

    try:
        offset=int(
            q.get(
                "offset",
                0,
            )
        )
    except (
        TypeError,
        ValueError,
    ):
        offset=0

    try:
        limit=int(
            q.get(
                "limit",
                100,
            )
        )
    except (
        TypeError,
        ValueError,
    ):
        limit=100


    result=query_configs(
        search=str(
            q.get(
                "q",
                "",
            )
        ),

        config_type=str(
            q.get(
                "type",
                "",
            )
        ),

        health_status=str(
            q.get(
                "health",
                "",
            )
        ),

        country_state=str(
            q.get(
                "state",
                "",
            )
        ),

        unresolved_only=True,

        offset=offset,

        limit=limit,
    )

    return web.json_response(
        result
    )


'''

if needle not in s:
    raise SystemExit(
        "ERROR=HANDLER_INSERT_POINT_NOT_FOUND"
    )

s=s.replace(
    needle,
    handlers+needle,
    1,
)


route_needle='''    app.router.add_get(
        "/api/sources",
        api_sources
    )
'''

routes='''    app.router.add_get(
        "/api/sources",
        api_sources
    )

    # PANEL_A3_COUNTRY_API routes
    app.router.add_get(
        "/api/country/summary",
        api_country_summary
    )

    app.router.add_get(
        "/api/configs",
        api_configs
    )

    app.router.add_get(
        "/api/country/unresolved",
        api_country_unresolved
    )
'''

if route_needle not in s:
    raise SystemExit(
        "ERROR=ROUTE_INSERT_POINT_NOT_FOUND"
    )

s=s.replace(
    route_needle,
    routes,
    1,
)

p.write_text(s)

print(
    "COUNTRY_API_PATCH=PASS"
)
PY


echo
echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$SERVER"

echo "COMPILE=PASS"


echo
echo "=== 3. STATIC ROUTE CONTRACT ==="

for X in \
'/api/country/summary' \
'/api/configs' \
'/api/country/unresolved'
do
    grep -q "$X" "$SERVER"
    echo "$X=PASS"
done

grep -q \
'PANEL_A3_COUNTRY_API' \
"$SERVER"

echo "STATIC_ROUTES=PASS"


echo
echo "=== 4. CREATE_APP ROUTE AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import (
    create_app,
)

app=create_app()

routes=[]

for r in app.router.routes():

    try:
        path=r.resource.canonical
    except Exception:
        path=str(r.resource)

    routes.append(
        (
            r.method,
            path,
        )
    )


wanted={
    ("GET","/api/country/summary"),
    ("GET","/api/configs"),
    ("GET","/api/country/unresolved"),
}

print(
    "ROUTES_FOUND=",
    sorted(
        x
        for x in routes
        if x in wanted
    ),
)

missing=(
    wanted
    -set(routes)
)

print(
    "MISSING=",
    missing,
)

assert not missing

print(
    "CREATE_APP_ROUTE_AUDIT=PASS"
)
PY


echo
echo "=== 5. RESTART PANEL ONLY ==="

systemctl restart \
config-location-panel.service

sleep 4

test "$(
    systemctl is-active \
    config-location-panel.service
)" = active

echo "PANEL_RESTART=PASS"


echo
echo "=== 6. LOGIN-AUTH EXPECTATION ==="

# These APIs are intentionally protected by the existing
# panel auth middleware. Anonymous requests should redirect
# to /login rather than expose config/country state.

for URL in \
http://127.0.0.1:4040/api/country/summary \
http://127.0.0.1:4040/api/configs \
http://127.0.0.1:4040/api/country/unresolved
do

    CODE=$(
        curl -sS \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 10 \
        "$URL"
    )

    REDIR=$(
        curl -sSI \
        --max-time 10 \
        "$URL" \
        | awk '
            BEGIN{IGNORECASE=1}
            /^Location:/ {
                gsub("\r","",$2)
                print $2
            }
        ' \
        | tail -n1
    )

    echo "URL=$URL"
    echo "CODE=$CODE"
    echo "REDIRECT=$REDIR"

    test "$CODE" = 302
    test "$REDIR" = /login
done

echo "API_AUTH_PROTECTION=PASS"


echo
echo "=== 7. DIRECT HANDLER FUNCTIONAL TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import asyncio

from aiohttp.test_utils import (
    make_mocked_request,
)

from app.panel.server import (
    api_country_summary,
    api_configs,
    api_country_unresolved,
)


async def main():

    r1=await api_country_summary(
        make_mocked_request(
            "GET",
            "/api/country/summary",
        )
    )

    print(
        "SUMMARY_STATUS=",
        r1.status,
    )

    assert r1.status==200


    r2=await api_configs(
        make_mocked_request(
            "GET",
            "/api/configs?limit=10",
        )
    )

    print(
        "CONFIGS_STATUS=",
        r2.status,
    )

    assert r2.status==200


    r3=await api_country_unresolved(
        make_mocked_request(
            "GET",
            "/api/country/unresolved?limit=10",
        )
    )

    print(
        "UNRESOLVED_STATUS=",
        r3.status,
    )

    assert r3.status==200


asyncio.run(main())

print(
    "DIRECT_HANDLER_TEST=PASS"
)
PY


echo
echo "=== 8. NO CORE SERVICE RESTART ==="

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

echo "CORE_SERVICES=UNCHANGED"


echo
echo "=== 9. COUNTRY CONSISTENCY SMOKE ==="

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
echo "PANEL_A3=PASS"
echo "COUNTRY_SUMMARY_API=READY"
echo "CONFIG_QUERY_API=READY"
echo "UNRESOLVED_API=READY"
echo "AUTH_PROTECTED=YES"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A4-COUNTRY-UI"
echo "======================================================"
