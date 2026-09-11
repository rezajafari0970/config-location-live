#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"
SERVER="$PROJECT/app/panel/server.py"

BACKUP="$(mktemp)"
MUTATED=0

cp -a "$SERVER" "$BACKUP"

wait_ready() {
    for I in $(seq 1 45); do

        STATE="$(
            systemctl is-active \
              config-location-panel.service \
              2>/dev/null || true
        )"

        CODE="$(
            curl -sS \
              --max-time 3 \
              -o /dev/null \
              -w '%{http_code}' \
              http://127.0.0.1:4040/sub/all \
              2>/dev/null || true
        )"

        echo "READY[$I] service=$STATE http=$CODE"

        if [ "$STATE" = "active" ] && \
           [ "$CODE" = "200" ]; then
            return 0
        fi

        sleep 1
    done

    return 1
}

rollback() {
    RC=$?

    echo
    echo "========== AUTOMATIC ROLLBACK =========="

    if [ "$MUTATED" -eq 1 ]; then
        /bin/cp -a "$BACKUP" "$SERVER"

        systemctl restart \
          config-location-panel.service \
          >/dev/null 2>&1 || true

        wait_ready || true
    fi

    /bin/rm -f "$BACKUP"

    echo "ROLLBACK=COMPLETE"

    exit "$RC"
}

trap rollback ERR


echo "================================================"
echo " PHASE 6 PASS 2"
echo " PUBLIC COUNTRY CATALOG AUTH CONTRACT"
echo "================================================"


echo
echo "========== [1/8] PRECHECK =========="

test -f "$SERVER"

test "$(
    systemctl is-active \
      config-location-panel.service
)" = "active"

BEFORE="$(
    curl -sS \
      --max-time 10 \
      -o /dev/null \
      -w '%{http_code}' \
      http://127.0.0.1:4040/api/countries \
      2>/dev/null || true
)"

echo "CATALOG_BEFORE=$BEFORE"

test "$BEFORE" = "302"

echo "PRECHECK=PASS"


echo
echo "========== [2/8] EXACT AUTH PATCH =========="

"$PROJECT/venv/bin/python" \
- "$SERVER" <<'PY'
import ast
import sys
from pathlib import Path

path = Path(sys.argv[1])

source = path.read_text(
    encoding="utf-8",
)

old = '''        request.path in {
            "/login",
            "/health",
            "/api/publish/status",
        }
'''

new = '''        request.path in {
            "/login",
            "/health",
            "/api/publish/status",
            "/api/countries",
        }
'''

if old not in source:

    if (
        '"/api/countries",'
        in source
    ):
        print(
            "AUTH_PATCH=ALREADY_PRESENT"
        )

    else:
        raise SystemExit(
            "EXACT_AUTH_BLOCK_NOT_FOUND"
        )

else:

    source = source.replace(
        old,
        new,
        1,
    )

    path.write_text(
        source,
        encoding="utf-8",
    )

    print(
        "AUTH_PATCH=APPLIED"
    )


tree = ast.parse(
    path.read_text(
        encoding="utf-8",
    )
)

text = path.read_text(
    encoding="utf-8",
)

if text.count(
    '"/api/countries",'
) != 1:
    raise SystemExit(
        "AUTH_COUNTRIES_COUNT_INVALID"
    )

print(
    "AUTH_CONTRACT=PASS"
)
PY

MUTATED=1


echo
echo "========== [3/8] COMPILE =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  "$PROJECT/app/panel/server.py" \
  "$PROJECT/app/publish/http.py" \
  "$PROJECT/app/country/catalog.py"

echo "COMPILE=PASS"


echo
echo "========== [4/8] CONTROLLED RESTART =========="

systemctl restart \
  config-location-panel.service

wait_ready

echo "PANEL_READY=PASS"


echo
echo "========== [5/8] PUBLIC CATALOG CONTRACT =========="

HDR="/tmp/phase6-pass2.headers"
BODY="/tmp/phase6-pass2.json"

CODE="$(
    curl -sS \
      --max-time 20 \
      -D "$HDR" \
      -o "$BODY" \
      -w '%{http_code}' \
      http://127.0.0.1:4040/api/countries
)"

echo "CATALOG_AFTER=$CODE"

test "$CODE" = "200"

grep -qi \
  '^X-Country-Catalog-Contract: healthy' \
  "$HDR"

grep -qi \
  '^X-Country-Source: canonical-projection-v2' \
  "$HDR"

echo "PUBLIC_HTTP=PASS"


echo
echo "========== [6/8] JSON CONTRACT =========="

"$PROJECT/venv/bin/python" \
- "$BODY" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as f:
    data = json.load(f)

assert data["schema"] == 1

assert (
    data["source"]
    == "canonical-projection-v2"
)

assert (
    data["country_count"]
    == len(data["countries"])
)

assert (
    data["resolved"]
    + data["unknown"]
    + data["conflict"]
    == data["publishable"]
)

codes = [
    row["code"]
    for row in data["countries"]
]

assert codes == sorted(set(codes))

for row in data["countries"]:

    code = row["code"]

    assert (
        row["subscription"]
        == f"/sub/country/{code}"
    )

    assert row["count"] > 0


print(
    "PUBLISHABLE=",
    data["publishable"],
)

print(
    "RESOLVED=",
    data["resolved"],
)

print(
    "UNKNOWN=",
    data["unknown"],
)

print(
    "CONFLICT=",
    data["conflict"],
)

print(
    "COUNTRY_COUNT=",
    data["country_count"],
)

print("JSON_CONTRACT=PASS")
PY


echo
echo "========== [7/8] REGRESSION =========="

for SPEC in \
  "ALL|/sub/all|200" \
  "UNKNOWN|/sub/country/UNKNOWN|200" \
  "CONFLICT|/sub/country/CONFLICT|200" \
  "INVALID|/sub/country/INVALID|404" \
  "STATUS|/api/publish/status|200" \
  "CATALOG|/api/countries|200"
do

    IFS='|' read -r \
      NAME URL_PATH EXPECT \
      <<<"$SPEC"

    CODE="$(
        curl -sS \
          --max-time 15 \
          -o /dev/null \
          -w '%{http_code}' \
          "http://127.0.0.1:4040${URL_PATH}" \
          2>/dev/null || true
    )"

    echo "$NAME=$CODE"

    test "$CODE" = "$EXPECT"
done

echo "REGRESSION=PASS"


echo
echo "========== [8/8] STABILITY =========="

sleep 5

STATE="$(
    systemctl is-active \
      config-location-panel.service \
      2>/dev/null || true
)"

FINAL="$(
    curl -sS \
      --max-time 10 \
      -o /dev/null \
      -w '%{http_code}' \
      http://127.0.0.1:4040/api/countries \
      2>/dev/null || true
)"

echo "PANEL_STATE=$STATE"
echo "FINAL_CATALOG_HTTP=$FINAL"

test "$STATE" = "active"
test "$FINAL" = "200"

echo
echo "PHASE6_PASS2=PASS"
echo "CATALOG_PUBLIC=YES"
echo "AUTH_REDIRECT=REMOVED"
echo "PRODUCTION_HEALTHY=YES"

MUTATED=0

/bin/rm -f "$BACKUP"

trap - ERR
