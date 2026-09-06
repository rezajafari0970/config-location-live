#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"

echo "================================================"
echo " PHASE 6 PASS 1D"
echo " FINAL COUNTRY CATALOG VALIDATION"
echo "================================================"

echo
echo "========== [1/7] SERVICE =========="

test "$(
    systemctl is-active \
      config-location-panel.service
)" = "active"

echo "PANEL=active"


echo
echo "========== [2/7] COMPILE =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  "$PROJECT/app/country/catalog.py" \
  "$PROJECT/app/publish/http.py" \
  "$PROJECT/app/panel/server.py"

echo "COMPILE=PASS"


echo
echo "========== [3/7] IMPORT / CATALOG =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.catalog import (
    build_country_catalog,
)

catalog = build_country_catalog()

assert (
    catalog["country_count"]
    == len(catalog["countries"])
)

assert (
    catalog["resolved"]
    + catalog["unknown"]
    + catalog["conflict"]
    == catalog["publishable"]
)

codes = [
    item["code"]
    for item in catalog["countries"]
]

assert codes == sorted(set(codes))

assert all(
    len(code) == 2
    and code.isalpha()
    and code.isupper()
    for code in codes
)

print(
    "PUBLISHABLE=",
    catalog["publishable"],
)

print(
    "RESOLVED=",
    catalog["resolved"],
)

print(
    "UNKNOWN=",
    catalog["unknown"],
)

print(
    "CONFLICT=",
    catalog["conflict"],
)

print(
    "COUNTRY_COUNT=",
    catalog["country_count"],
)

print("CATALOG_MODEL=PASS")
PY


echo
echo "========== [4/7] CORE HTTP =========="

for SPEC in \
  "ALL|/sub/all|200" \
  "UNKNOWN|/sub/country/UNKNOWN|200" \
  "CONFLICT|/sub/country/CONFLICT|200" \
  "INVALID|/sub/country/INVALID|404" \
  "STATUS|/api/publish/status|200"
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

echo "CORE_HTTP=PASS"


echo
echo "========== [5/7] COUNTRY CATALOG HTTP =========="

HDR="/tmp/phase6-pass1d.headers"
BODY="/tmp/phase6-pass1d.body"

CODE="$(
    curl -sS \
      --max-time 20 \
      -D "$HDR" \
      -o "$BODY" \
      -w '%{http_code}' \
      http://127.0.0.1:4040/api/countries \
      2>/dev/null || true
)"

echo "CATALOG_HTTP=$CODE"

sed -n '1,25p' "$HDR"

if [ "$CODE" = "200" ]; then

    "$PROJECT/venv/bin/python" \
    - "$BODY" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as f:
    data = json.load(f)

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

assert (
    data["source"]
    == "canonical-projection-v2"
)

print(
    "HTTP_COUNTRY_COUNT=",
    data["country_count"],
)

print("CATALOG_JSON=PASS")
PY

    echo "CATALOG_ACCESS=PUBLIC"

elif [ "$CODE" = "302" ]; then

    echo "CATALOG_ACCESS=AUTH_REDIRECT"

else

    echo "CATALOG_ACCESS=INVALID"
    exit 1
fi


echo
echo "========== [6/7] COUNTRY ROUTE SAMPLE =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY' \
> /tmp/phase6-pass1d-codes.txt
from app.country.catalog import (
    build_country_catalog,
)

catalog = build_country_catalog()

for item in catalog["countries"][:10]:
    print(item["code"])
PY

while IFS= read -r COUNTRY; do

    [ -n "$COUNTRY" ] || continue

    CODE="$(
        curl -sS \
          --max-time 15 \
          -o /dev/null \
          -w '%{http_code}' \
          "http://127.0.0.1:4040/sub/country/${COUNTRY}" \
          2>/dev/null || true
    )"

    echo "$COUNTRY=$CODE"

    test "$CODE" = "200"

done < /tmp/phase6-pass1d-codes.txt

echo "COUNTRY_SAMPLE=PASS"


echo
echo "========== [7/7] STABILITY =========="

sleep 5

STATE="$(
    systemctl is-active \
      config-location-panel.service \
      2>/dev/null || true
)"

echo "PANEL_STATE=$STATE"

test "$STATE" = "active"

CODE="$(
    curl -sS \
      --max-time 10 \
      -o /dev/null \
      -w '%{http_code}' \
      http://127.0.0.1:4040/sub/all \
      2>/dev/null || true
)"

echo "FINAL_SUB_ALL=$CODE"

test "$CODE" = "200"

echo
echo "PHASE6_PASS1D_FINAL_VALIDATION=PASS"
echo "PRODUCTION_HEALTHY=YES"
echo "COUNTRY_CATALOG_MODEL=READY"
echo "PHASE6_PASS1_COMPLETE=YES"
