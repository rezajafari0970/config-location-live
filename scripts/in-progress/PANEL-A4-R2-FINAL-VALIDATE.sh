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
echo "=== 2. AUTH PROTECTION ==="

for PATH in \
/country \
/api/country/summary \
/api/configs \
/api/country/unresolved
do

    RESULT=$(
        curl \
        -sS \
        --max-time 10 \
        -D - \
        -o /dev/null \
        -w $'\n__CODE__=%{http_code}\n' \
        "http://127.0.0.1:4040$PATH"
    )

    CODE=$(
        printf '%s\n' "$RESULT" \
        | sed -n \
        's/^__CODE__=//p' \
        | tail -n1
    )

    LOCATION=$(
        printf '%s\n' "$RESULT" \
        | awk '
            BEGIN {
                IGNORECASE=1
            }

            /^Location:/ {
                gsub("\r","",$2)
                print $2
            }
        ' \
        | tail -n1
    )

    echo "PATH=$PATH"
    echo "CODE=$CODE"
    echo "LOCATION=$LOCATION"

    test "$CODE" = 302
    test "$LOCATION" = /login
done

echo "AUTH_PROTECTION=PASS"


echo
echo "=== 3. LIVE PAGE ROUTE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import create_app

app=create_app()

routes={
    (
        r.method,
        getattr(
            r.resource,
            "canonical",
            "",
        ),
    )
    for r in app.router.routes()
}

required={
    ("GET","/country"),
    ("GET","/api/country/summary"),
    ("GET","/api/configs"),
    ("GET","/api/country/unresolved"),
}

print(
    "MISSING=",
    required-routes,
)

assert not (
    required-routes
)

print(
    "LIVE_ROUTE_CONTRACT=PASS"
)
PY


echo
echo "=== 4. READ MODEL LIVE ==="

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


r=query_configs(
    limit=50,
)

assert r["total"]>0
assert len(r["items"])<=50


u=query_configs(
    unresolved_only=True,
    limit=50,
)

assert u["total"]>0

for row in u["items"]:
    assert row[
        "country_unresolved"
    ] is True

print(
    "READ_MODEL_LIVE=PASS"
)
PY


echo
echo "=== 5. PANEL JOURNAL ==="

J=$(
    journalctl \
    -u config-location-panel.service \
    --since "10 minutes ago" \
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
echo "=== 6. CORE SERVICES ==="

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
echo "=== 7. COUNTRY CONSISTENCY ==="

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
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
        continue

    if not (
        ident.get("locked") is True
        and ident.get("country_code")
    ):
        continue

    cid=str(
        ident.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue

    try:
        pipe=json.loads(
            pp.read_text()
        )
    except Exception:
        continue

    checked+=1

    if (
        str(
            ident.get("country_code")
            or ""
        ).upper()
        !=
        str(
            pipe.get("country_code")
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
echo "PANEL_A4_R2=PASS"
echo "COUNTRY_UI=ACTIVE"
echo "COUNTRY_URL=/country"
echo "AUTH_PROTECTED=YES"
echo "READ_MODEL=LIVE"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A5-NAVIGATION-DETAIL"
echo "======================================================"
