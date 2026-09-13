#!/usr/bin/env bash
set -Eeu -o pipefail

PHASE="phase5-final-fresh-country-projection-fix"

PROJECT="/opt/config-location"
REPO="/root/project-log"

HTTP="$PROJECT/app/publish/http.py"
ADAPTER="$PROJECT/app/country/production_publish_projection.py"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"

BACKUP="/root/3245/${PHASE}-backup-${TS}"
LOG="$REPO/executions/$DATE/${PHASE}-${TS}.log"
REPORT="$REPO/reports/${PHASE}-${TS}.txt"
SUMMARY="$REPO/discovery/$DATE/${PHASE}-${TS}.json"

mkdir -p \
  "$BACKUP" \
  "$(dirname "$LOG")" \
  "$(dirname "$REPORT")" \
  "$(dirname "$SUMMARY")"

RESULT="SUCCESS"
ROLLED_BACK="NO"

exec > >(tee -a "$LOG") 2>&1

rollback() {
    echo "========== ROLLBACK =========="

    cp -a \
      "$BACKUP/http.py.before" \
      "$HTTP"

    systemctl restart \
      config-location-panel.service \
      || true

    ROLLED_BACK="YES"

    echo "ROLLBACK_DONE"
}

finish() {
    CODE=$?

    [ "$CODE" -eq 0 ] || RESULT="FAILED"

    cat > "$REPORT" <<REPORT
Phase:
$PHASE

Result:
$RESULT

Rollback:
$ROLLED_BACK

Fix:
Refresh production country projection once per Country request.

Config mutation:
NONE

Canonical country-store mutation:
NONE

Summary:
$SUMMARY

Log:
$LOG
REPORT

    cd "$REPO" || exit 1

    git add \
      "$LOG" \
      "$REPORT" \
      "$SUMMARY" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase5 final fresh country projection fix $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ]
}

trap finish EXIT


echo "================================================"
echo " PHASE 5 FINAL FIX"
echo " FRESH COUNTRY PROJECTION PER REQUEST"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/9] PRECHECK =========="

test -f "$HTTP"
test -f "$ADAPTER"
test -x "$PROJECT/venv/bin/python"

grep -q \
  'def refresh' \
  "$ADAPTER"

grep -q \
  'def _country_subscription_text' \
  "$HTTP"

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/9] BACKUP =========="

cp -a \
  "$HTTP" \
  "$BACKUP/http.py.before"

echo "BACKUP_OK"


################################################
# 3 PATCH
################################################

echo
echo "========== [3/9] PATCH =========="

"$PROJECT/venv/bin/python" \
- "$HTTP" <<'PY'
import ast
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
tree = ast.parse(source)


################################################
# Ensure refresh import exists
################################################

found_module = False
refresh_imported = False

for node in tree.body:

    if (
        isinstance(node, ast.ImportFrom)
        and node.module
        ==
        "app.country.production_publish_projection"
    ):

        found_module = True

        names = {
            alias.name
            for alias in node.names
        }

        if "refresh" in names:
            refresh_imported = True
        else:
            node.names.append(
                ast.alias(
                    name="refresh",
                    asname="refresh_country_projection",
                )
            )

            refresh_imported = True


if not found_module:

    tree.body.insert(
        0,
        ast.ImportFrom(
            module=(
                "app.country."
                "production_publish_projection"
            ),
            names=[
                ast.alias(
                    name="country_code_for_config",
                ),
                ast.alias(
                    name="refresh",
                    asname="refresh_country_projection",
                ),
            ],
            level=0,
        )
    )


################################################
# Find country subscription builder
################################################

target = None

for node in tree.body:

    if (
        isinstance(node, ast.FunctionDef)
        and node.name
        ==
        "_country_subscription_text"
    ):
        target = node
        break


if target is None:
    raise SystemExit(
        "_country_subscription_text not found"
    )


################################################
# Detect already-patched state
################################################

already = False

for node in ast.walk(target):

    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id
        ==
        "refresh_country_projection"
    ):
        already = True


if not already:

    refresh_call = ast.Expr(
        value=ast.Call(
            func=ast.Name(
                id="refresh_country_projection",
                ctx=ast.Load(),
            ),
            args=[],
            keywords=[],
        )
    )

    # Must happen before build_publish_snapshot()
    target.body.insert(
        0,
        refresh_call,
    )


ast.fix_missing_locations(tree)

path.write_text(
    ast.unparse(tree) + "\n",
    encoding="utf-8",
)

print(
    "REFRESH_IMPORT=READY"
)

print(
    "COUNTRY_REQUEST_REFRESH="
    + (
        "ALREADY_PRESENT"
        if already
        else "INSTALLED"
    )
)
PY


################################################
# 4 STATIC CONTRACT
################################################

echo
echo "========== [4/9] STATIC CONTRACT =========="

grep -n \
  'refresh_country_projection' \
  "$HTTP"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  "$HTTP" \
  "$ADAPTER"

echo "COMPILE_OK"


################################################
# 5 OFFLINE REQUEST CONTRACT
################################################

echo
echo "========== [5/9] OFFLINE CONTRACT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" <<'PY'
import app.publish.http as h
import app.country.production_publish_projection as pp

before = pp.projection.cache_info()

text, snapshot, count = (
    h._country_subscription_text("DE")
)

after = pp.projection.cache_info()

print("COUNT=", count)
print("PUBLISHABLE=", snapshot.publishable)
print("CACHE_BEFORE=", before)
print("CACHE_AFTER=", after)

assert isinstance(text, str)
assert count >= 0

print("OFFLINE_REFRESH_CONTRACT_OK")
PY


################################################
# 6 RESTART
################################################

echo
echo "========== [6/9] PANEL RESTART =========="

systemctl restart \
  config-location-panel.service

sleep 4

ACTIVE="$(
systemctl is-active \
  config-location-panel.service \
  || true
)"

echo "PANEL_ACTIVE=$ACTIVE"

if [ "$ACTIVE" != "active" ]; then
    rollback
    exit 1
fi


################################################
# 7 LIVE FRESHNESS RECONCILIATION
################################################

echo
echo "========== [7/9] LIVE FRESHNESS =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" <<'PY'
import urllib.request
from collections import Counter

from app.publish.filter import (
    build_publish_snapshot,
)

from app.country.projection import (
    build_projection,
)


BASE="http://127.0.0.1:4040"

snap=build_publish_snapshot()
projection=build_projection()

ids={
    str(r["id"])
    for r in snap.configs
    if (
        isinstance(r,dict)
        and r.get("id")
    )
}

counts=Counter()

for cid in ids:

    row=projection.get(
        "records",
        {}
    ).get(cid)

    if (
        isinstance(row,dict)
        and row.get("state")
        == "resolved"
    ):

        code=row.get(
            "country_code"
        )

        if (
            isinstance(code,str)
            and len(code.strip())==2
            and code.strip().isalpha()
        ):
            counts[
                code.strip().upper()
            ] += 1


fail=[]

for code, expected in sorted(
    counts.items()
):

    req=urllib.request.Request(
        BASE
        + "/sub/country/"
        + code,
        headers={
            "User-Agent":
                "phase5-final-freshness"
        },
    )

    with urllib.request.urlopen(
        req,
        timeout=15,
    ) as response:

        status=response.status

        header_count=int(
            response.headers[
                "X-Config-Country-Count"
            ]
        )

        source=response.headers[
            "X-Country-Source"
        ]

        contract=response.headers.get(
            "X-Country-Contract"
        )


    print(
        f"{code}: "
        f"expected={expected} "
        f"live={header_count} "
        f"http={status}"
    )


    if (
        status != 200
        or header_count != expected
        or source
        != "canonical-projection-v2"
        or contract != "healthy"
    ):
        fail.append(
            {
                "code":code,
                "expected":expected,
                "live":header_count,
            }
        )


print()
print(
    "COUNTRIES_TESTED=",
    len(counts),
)

print(
    "COUNTRIES_FAILED=",
    len(fail),
)


if fail:

    print(
        "FAILED=",
        fail,
    )

    raise SystemExit(2)


print(
    "ALL_COUNTRY_FRESHNESS_MATCH=YES"
)
PY


################################################
# 8 REGRESSION
################################################

echo
echo "========== [8/9] REGRESSION =========="

ALL_HTTP="$(
curl \
  -sS \
  --max-time 20 \
  -o /tmp/pass5-final-fix-all \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all
)"

INVALID_HTTP="$(
curl \
  -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/INVALID \
  || true
)"


echo "SUB_ALL_HTTP=$ALL_HTTP"
echo "INVALID_HTTP=$INVALID_HTTP"

[ "$ALL_HTTP" = "200" ] || {
    rollback
    exit 1
}

[ "$INVALID_HTTP" = "404" ] || {
    rollback
    exit 1
}


for UNIT in \
  config-location-panel.service \
  config-location-country-worker.service \
  config-location-country-event-consumer.service \
  config-location-country-publish-contract.timer
do

    ACTIVE="$(
        systemctl is-active \
        "$UNIT" \
        2>/dev/null || true
    )"

    echo "$UNIT=$ACTIVE"

    [ "$ACTIVE" = "active" ] || {
        rollback
        exit 1
    }

done

echo "REGRESSION_OK"


################################################
# 9 SUMMARY
################################################

echo
echo "========== [9/9] SUMMARY =========="

"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<PY
import json
import sys

data={
    "phase":
        "$PHASE",

    "result":
        "SUCCESS",

    "fix":
        "refresh canonical country projection once per country request",

    "country_route":
        "/sub/country/{country_code}",

    "country_route_mode":
        "DYNAMIC_ALL_DISCOVERED_COUNTRIES",

    "country_source":
        "CANONICAL_PROJECTION_V2",

    "stale_process_cache":
        "FIXED",

    "all_country_freshness_match":
        True,

    "sub_all_http":
        200,

    "invalid_country_http":
        404,

    "automatic_rollback":
        True,

    "rolled_back":
        False,

    "config_write":
        False,

    "canonical_country_store_write":
        False,
}

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        data,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")

print(
    json.dumps(
        data,
        ensure_ascii=False,
        indent=2,
    )
)
PY


echo
echo "STALE_PROJECTION_CACHE=FIXED"
echo "COUNTRY_ROUTE_MODE=DYNAMIC_ALL_DISCOVERED_COUNTRIES"
echo "ALL_COUNTRY_FRESHNESS_MATCH=YES"
echo "SUB_ALL_REGRESSION=PASS"
echo "AUTOMATIC_ROLLBACK=READY"
echo "ROLLED_BACK=NO"

echo
echo "PHASE5_FINAL_FRESHNESS_FIX_SUCCESS"

RESULT="SUCCESS"
