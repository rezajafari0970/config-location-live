#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"

echo "================================================"
echo " PHASE 6 PASS 2 — FINAL VALIDATION"
echo "================================================"

echo
echo "========== [1/7] SERVICE =========="

STATE="$(
    systemctl is-active \
      config-location-panel.service \
      2>/dev/null || true
)"

echo "PANEL=$STATE"
test "$STATE" = "active"


echo
echo "========== [2/7] SOURCE AUTH CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path
import ast

path = Path(
    "/opt/config-location/app/panel/server.py"
)

source = path.read_text(
    encoding="utf-8",
)

ast.parse(source)

assert '"/api/countries"' in source
assert '"/api/publish/status"' in source

print("SOURCE_AUTH_CONTRACT=PASS")
PY


echo
echo "========== [3/7] COMPILE =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  "$PROJECT/app/panel/server.py" \
  "$PROJECT/app/publish/http.py" \
  "$PROJECT/app/country/catalog.py"

echo "COMPILE=PASS"


echo
echo "========== [4/7] PUBLIC HTTP =========="

HDR="/tmp/phase6-pass2-final.headers"
BODY="/tmp/phase6-pass2-final.json"

CODE="$(
    curl -sS \
      --max-time 20 \
      -D "$HDR" \
      -o "$BODY" \
      -w '%{http_code}' \
      http://127.0.0.1:4040/api/countries
)"

echo "CATALOG_HTTP=$CODE"

test "$CODE" = "200"

if grep -qi '^Location: /login' "$HDR"; then
    echo "AUTH_REDIRECT=YES"
    exit 1
fi

echo "AUTH_REDIRECT=NO"

grep -qi \
  '^X-Country-Catalog-Contract: healthy' \
  "$HDR"

grep -qi \
  '^X-Country-Source: canonical-projection-v2' \
  "$HDR"

echo "PUBLIC_HTTP=PASS"


echo
echo "========== [5/7] JSON CONTRACT =========="

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

assert all(
    row["count"] > 0
    for row in data["countries"]
)

print("PUBLISHABLE=", data["publishable"])
print("RESOLVED=", data["resolved"])
print("UNKNOWN=", data["unknown"])
print("CONFLICT=", data["conflict"])
print("COUNTRY_COUNT=", data["country_count"])

print("JSON_CONTRACT=PASS")
PY


echo
echo "========== [6/7] COMPLETE HTTP REGRESSION =========="

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

echo "HTTP_REGRESSION=PASS"


echo
echo "========== [7/7] STABILITY =========="

sleep 5

STATE="$(
    systemctl is-active \
      config-location-panel.service \
      2>/dev/null || true
)"

CATALOG="$(
    curl -sS \
      --max-time 10 \
      -o /dev/null \
      -w '%{http_code}' \
      http://127.0.0.1:4040/api/countries \
      2>/dev/null || true
)"

ALL="$(
    curl -sS \
      --max-time 10 \
      -o /dev/null \
      -w '%{http_code}' \
      http://127.0.0.1:4040/sub/all \
      2>/dev/null || true
)"

echo "PANEL_STATE=$STATE"
echo "FINAL_CATALOG=$CATALOG"
echo "FINAL_SUB_ALL=$ALL"

test "$STATE" = "active"
test "$CATALOG" = "200"
test "$ALL" = "200"

echo
echo "========================================"
echo " PHASE 6 PASS 2 COMPLETE"
echo "========================================"

echo "PUBLIC_COUNTRY_CATALOG=PASS"
echo "AUTH_REDIRECT=REMOVED"
echo "PRODUCTION_HEALTHY=YES"
echo "PHASE6_PASS2_COMPLETE=YES"
