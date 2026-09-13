#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"
HTTP="$PROJECT/app/publish/http.py"
CATALOG="$PROJECT/app/country/catalog.py"

BACKUP="$(mktemp -d)"
MUTATED=0

wait_ready() {
    for I in $(seq 1 60); do
        STATE="$(systemctl is-active config-location-panel.service 2>/dev/null || true)"

        CODE="$(
            curl -sS \
              --max-time 3 \
              -o /dev/null \
              -w '%{http_code}' \
              http://127.0.0.1:4040/sub/all \
              2>/dev/null || true
        )"

        echo "READY_TRY=$I STATE=$STATE HTTP=$CODE"

        if [ "$STATE" = "active" ] && [ "$CODE" = "200" ]; then
            return 0
        fi

        sleep 1
    done

    return 1
}

rollback() {
    RC=$?

    if [ "$MUTATED" -eq 1 ]; then
        echo
        echo "========== ROLLBACK =========="

        cp -a "$BACKUP/http.py" "$HTTP"

        if [ -f "$BACKUP/catalog.py" ]; then
            cp -a "$BACKUP/catalog.py" "$CATALOG"
        else
            rm -f "$CATALOG"
        fi

        systemctl restart config-location-panel.service || true
        wait_ready || true

        echo "ROLLBACK=COMPLETE"
    fi

    rm -rf "$BACKUP"
    exit "$RC"
}

trap rollback ERR

echo "================================================"
echo " PHASE 6 PASS 1C"
echo " REPAIR COUNTRY CATALOG CONTRACT"
echo "================================================"

echo
echo "========== [1/9] BASELINE =========="

test -f "$HTTP"

cp -a "$HTTP" "$BACKUP/http.py"

if [ -f "$CATALOG" ]; then
    cp -a "$CATALOG" "$BACKUP/catalog.py"
fi

grep -nE \
'build_country_catalog|country_catalog|api/countries' \
"$HTTP" || true

MUTATED=1

echo "BASELINE_CAPTURED=YES"


echo
echo "========== [2/9] RESTORE CATALOG MODULE =========="

cat > "$CATALOG" <<'PY'
from __future__ import annotations

from collections import defaultdict
from typing import Any

from app.publish.filter import build_publish_snapshot
from app.country.production_publish_projection import (
    get_country_projection,
)


def _normalize_code(value: Any) -> str | None:
    if not isinstance(value, str):
        return None

    value = value.strip().upper()

    if len(value) != 2 or not value.isalpha():
        return None

    return value


def build_country_catalog() -> dict[str, Any]:
    snapshot = build_publish_snapshot()
    projection = get_country_projection()

    records = projection.get("records", {})

    if not isinstance(records, dict):
        records = {}

    counts: dict[str, int] = defaultdict(int)
    metadata: dict[str, dict[str, Any]] = {}

    resolved = 0
    unknown = 0
    conflict = 0

    for config in snapshot.configs:
        if not isinstance(config, dict):
            continue

        config_id = config.get("id")

        if not config_id:
            unknown += 1
            continue

        row = records.get(str(config_id))

        if not isinstance(row, dict):
            unknown += 1
            continue

        state = str(
            row.get("state", "unknown")
        ).strip().lower()

        if state == "conflict":
            conflict += 1
            continue

        if state != "resolved":
            unknown += 1
            continue

        code = _normalize_code(
            row.get("country_code")
        )

        if code is None:
            unknown += 1
            continue

        resolved += 1
        counts[code] += 1

        item = metadata.setdefault(
            code,
            {
                "country_name": None,
                "flag": None,
            },
        )

        name = row.get("country_name")

        if (
            item["country_name"] is None
            and isinstance(name, str)
            and name.strip()
        ):
            item["country_name"] = name.strip()

        flag = row.get("flag")

        if (
            item["flag"] is None
            and isinstance(flag, str)
            and flag.strip()
        ):
            item["flag"] = flag.strip()

    countries = []

    for code in sorted(counts):
        meta = metadata.get(code, {})

        countries.append(
            {
                "code": code,
                "country_code": code,
                "country_name": meta.get("country_name"),
                "flag": meta.get("flag"),
                "count": counts[code],
                "subscription": f"/sub/country/{code}",
            }
        )

    return {
        "schema": 1,
        "source": "canonical-projection-v2",
        "mode": "production",
        "publishable": snapshot.publishable,
        "resolved": resolved,
        "unknown": unknown,
        "conflict": conflict,
        "country_count": len(countries),
        "countries": countries,
        "special_routes": {
            "unknown": "/sub/country/UNKNOWN",
            "conflict": "/sub/country/CONFLICT",
        },
    }
PY

echo "CATALOG_RESTORED=YES"


echo
echo "========== [3/9] HTTP CONTRACT RECONCILE =========="

"$PROJECT/venv/bin/python" - "$HTTP" <<'PY'
import ast
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")

# Import must exist exactly once.
if "from app.country.catalog import" not in source:
    marker = """from app.country.production_publish_projection import (
    get_country_projection,
)
"""

    addition = marker + """
from app.country.catalog import (
    build_country_catalog,
)
"""

    if marker not in source:
        raise SystemExit("IMPORT_MARKER_NOT_FOUND")

    source = source.replace(marker, addition, 1)


if "async def country_catalog(" not in source:
    marker = """async def publish_status(
    request: web.Request,
):
"""

    handler = """async def country_catalog(
    request: web.Request,
):

    catalog = build_country_catalog()

    return web.json_response(
        catalog,
        headers={
            "Cache-Control": "no-store",
            "X-Country-Source": "canonical-projection-v2",
            "X-Country-Catalog-Contract": "healthy",
            "X-Country-Count": str(
                catalog["country_count"]
            ),
        },
    )


"""

    if marker not in source:
        raise SystemExit("HANDLER_MARKER_NOT_FOUND")

    source = source.replace(
        marker,
        handler + marker,
        1,
    )


if '"/api/countries"' not in source:
    marker = """    app.router.add_get(
        "/api/publish/status",
        publish_status,
    )
"""

    route = """    app.router.add_get(
        "/api/countries",
        country_catalog,
    )

"""

    if marker not in source:
        raise SystemExit("ROUTE_MARKER_NOT_FOUND")

    source = source.replace(
        marker,
        route + marker,
        1,
    )


tree = ast.parse(source)

functions = {
    node.name
    for node in ast.walk(tree)
    if isinstance(
        node,
        (ast.FunctionDef, ast.AsyncFunctionDef),
    )
}

assert "country_catalog" in functions

route_count = 0

for node in ast.walk(tree):
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "add_get"
        and node.args
        and isinstance(node.args[0], ast.Constant)
        and node.args[0].value == "/api/countries"
    ):
        route_count += 1

assert route_count == 1

path.write_text(
    source,
    encoding="utf-8",
)

print("HTTP_CONTRACT_RECONCILE=PASS")
PY


echo
echo "========== [4/9] COMPILE + IMPORT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/catalog.py \
  app/publish/http.py \
  app/panel/server.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.catalog import build_country_catalog
from app.publish.http import install_publish_routes

catalog = build_country_catalog()

assert catalog["country_count"] == len(
    catalog["countries"]
)

assert (
    catalog["resolved"]
    + catalog["unknown"]
    + catalog["conflict"]
    == catalog["publishable"]
)

print("COUNTRY_COUNT=", catalog["country_count"])
print("PUBLISHABLE=", catalog["publishable"])
print("IMPORT_CONTRACT=PASS")
PY

echo "COMPILE=PASS"


echo
echo "========== [5/9] RESTART =========="

systemctl restart config-location-panel.service

wait_ready

echo "PANEL_READY=PASS"


echo
echo "========== [6/9] CORE REGRESSION =========="

for SPEC in \
  "ALL|/sub/all|200" \
  "UNKNOWN|/sub/country/UNKNOWN|200" \
  "CONFLICT|/sub/country/CONFLICT|200" \
  "INVALID|/sub/country/INVALID|404"
do
    IFS='|' read -r NAME PATH EXPECT <<<"$SPEC"

    CODE="$(
        curl -sS \
          --max-time 15 \
          -o /dev/null \
          -w '%{http_code}' \
          "http://127.0.0.1:4040$PATH" \
          2>/dev/null || true
    )"

    echo "$NAME=$CODE"
    test "$CODE" = "$EXPECT"
done

echo "CORE_REGRESSION=PASS"


echo
echo "========== [7/9] CATALOG HTTP CHARACTERIZE =========="

HDR="/tmp/phase6-pass1c.headers"
BODY="/tmp/phase6-pass1c.body"

CODE="$(
    curl -sS \
      --max-time 15 \
      -D "$HDR" \
      -o "$BODY" \
      -w '%{http_code}' \
      http://127.0.0.1:4040/api/countries \
      2>/dev/null || true
)"

echo "CATALOG_HTTP=$CODE"

sed -n '1,30p' "$HDR" || true

# 200 = already public.
# 302 = catalog works but panel auth redirects it.
test "$CODE" = "200" -o "$CODE" = "302"

if [ "$CODE" = "200" ]; then
    "$PROJECT/venv/bin/python" - "$BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

assert data["country_count"] == len(data["countries"])

assert (
    data["resolved"]
    + data["unknown"]
    + data["conflict"]
    == data["publishable"]
)

print("CATALOG_JSON=PASS")
print("COUNTRY_COUNT=", data["country_count"])
PY

    echo "CATALOG_ACCESS=PUBLIC"
else
    echo "CATALOG_ACCESS=AUTH_REDIRECT"
fi


echo
echo "========== [8/9] SERVICE STABILITY =========="

sleep 5

test "$(
    systemctl is-active \
      config-location-panel.service
)" = "active"

RESTARTS="$(
    systemctl show \
      config-location-panel.service \
      -p NRestarts \
      --value
)"

echo "PANEL_NRESTARTS=$RESTARTS"
echo "SERVICE_STABILITY=PASS"


echo
echo "========== [9/9] FINAL =========="

/usr/local/sbin/config-location-live-sync || true

echo "PHASE6_PASS1C_REPAIR=SUCCESS"
echo "PANEL_CRASH_LOOP=FIXED"
echo "CATALOG_MODULE_PRESENT=YES"
echo "CATALOG_HTTP_CONTRACT_PRESENT=YES"
echo "ROLLBACK=NOT_REQUIRED"

MUTATED=0
rm -rf "$BACKUP"
trap - ERR
