#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"

echo "================================================"
echo " PHASE 6 PASS 0"
echo " COUNTRY CATALOG / PANEL / PUBLIC API DISCOVERY"
echo "================================================"

echo
echo "========== [1/9] CURRENT PROJECTION =========="

sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json

from collections import Counter

from app.country.production_publish_projection import (
    get_country_projection,
)

projection = get_country_projection()

records = projection.get(
    "records",
    {},
)

states = Counter()
countries = Counter()

for row in records.values():

    if not isinstance(row, dict):
        continue

    state = str(
        row.get(
            "state",
            "unknown",
        )
    )

    states[state] += 1

    if state == "resolved":

        code = row.get(
            "country_code"
        )

        if (
            isinstance(code, str)
            and len(code.strip()) == 2
            and code.strip().isalpha()
        ):

            countries[
                code.strip().upper()
            ] += 1


print(
    "PROJECTION_MODE=",
    projection.get("mode"),
)

print(
    "RECORDS=",
    len(records),
)

print(
    "STATES=",
    dict(states),
)

print(
    "COUNTRY_COUNT=",
    len(countries),
)

print(
    "COUNTRIES="
)

print(
    json.dumps(
        dict(
            sorted(
                countries.items()
            )
        ),
        ensure_ascii=False,
        indent=2,
    )
)
PY


echo
echo "========== [2/9] PUBLISHABLE COUNTRY VIEW =========="

sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json

from collections import Counter

from app.publish.filter import (
    build_publish_snapshot,
)

from app.country.production_publish_projection import (
    get_country_projection,
)

snapshot = build_publish_snapshot()
projection = get_country_projection()

records = projection.get(
    "records",
    {},
)

countries = Counter()

unknown = 0
conflict = 0

for config in snapshot.configs:

    if not isinstance(config, dict):
        continue

    cid = config.get("id")

    if not cid:
        continue

    row = records.get(
        str(cid)
    )

    if not isinstance(row, dict):

        unknown += 1
        continue

    state = row.get("state")

    if state == "conflict":

        conflict += 1
        continue

    if state != "resolved":

        unknown += 1
        continue

    code = row.get(
        "country_code"
    )

    if (
        isinstance(code, str)
        and len(code.strip()) == 2
        and code.strip().isalpha()
    ):

        countries[
            code.strip().upper()
        ] += 1

    else:

        unknown += 1


print(
    "PUBLISHABLE=",
    snapshot.publishable,
)

print(
    "RESOLVED=",
    sum(
        countries.values()
    ),
)

print(
    "UNKNOWN=",
    unknown,
)

print(
    "CONFLICT=",
    conflict,
)

print(
    "CATALOG_COUNTRY_COUNT=",
    len(countries),
)

print(
    json.dumps(
        dict(
            sorted(
                countries.items()
            )
        ),
        ensure_ascii=False,
        indent=2,
    )
)
PY


echo
echo "========== [3/9] PUBLISH HTTP ROUTES =========="

grep -nE \
'add_get|subscription_country|publish_status|sub/country|api/' \
"$PROJECT/app/publish/http.py" \
|| true


echo
echo "========== [4/9] PANEL COUNTRY MODULES =========="

for FILE in \
  "$PROJECT/app/panel/country_ui.py" \
  "$PROJECT/app/panel/read_model.py" \
  "$PROJECT/app/panel/publish_read_model.py" \
  "$PROJECT/app/panel/publish_ui.py"
do

    echo
    echo "----- $FILE -----"

    grep -nE \
    'country|countries|projection|publish|route|api|count|flag|UNKNOWN|CONFLICT' \
    "$FILE" \
    | head -n 200 \
    || true

done


echo
echo "========== [5/9] PANEL SERVER ROUTES =========="

grep -nE \
'router|add_get|add_post|country|countries|publish|api/' \
"$PROJECT/app/panel/server.py" \
| head -n 400 \
|| true


echo
echo "========== [6/9] COUNTRY API GAP =========="

python3 - "$PROJECT/app/publish/http.py" <<'PY'
import ast
import sys
from pathlib import Path

path = Path(sys.argv[1])

tree = ast.parse(
    path.read_text(
        encoding="utf-8",
    )
)

routes = []

for node in ast.walk(tree):

    if not isinstance(
        node,
        ast.Call,
    ):
        continue

    func = node.func

    if not isinstance(
        func,
        ast.Attribute,
    ):
        continue

    if func.attr != "add_get":
        continue

    if not node.args:
        continue

    first = node.args[0]

    if isinstance(
        first,
        ast.Constant,
    ) and isinstance(
        first.value,
        str,
    ):

        routes.append(
            first.value
        )


print(
    "GET_ROUTES="
)

for route in routes:
    print(route)


catalog_candidates = {
    "/api/countries",
    "/api/country/catalog",
    "/api/publish/countries",
}


found = sorted(
    catalog_candidates
    & set(routes)
)


print(
    "COUNTRY_CATALOG_API_PRESENT=",
    bool(found),
)

print(
    "MATCHED_CATALOG_ROUTES=",
    found,
)
PY


echo
echo "========== [7/9] CURRENT COUNTRY HTTP CONTRACT =========="

for CODE in \
  UNKNOWN \
  CONFLICT \
  DE \
  US
do

    echo
    echo "--- $CODE ---"

    curl -sS \
      --max-time 15 \
      -D - \
      -o /tmp/phase6-pass0-country.body \
      "http://127.0.0.1:4040/sub/country/$CODE" \
      | sed -n '1,30p' \
      || true

    echo -n "BODY_LINES="

    awk \
      'NF {count++} END {print count+0}' \
      /tmp/phase6-pass0-country.body

done


echo
echo "========== [8/9] SERVICE / PERFORMANCE BASELINE =========="

systemctl is-active \
  config-location-panel.service

systemctl is-active \
  config-location-country-worker.service

systemctl is-active \
  config-location-country-event-consumer.service


for URL in \
  /sub/all \
  /sub/country/UNKNOWN \
  /sub/country/DE
do

    printf '%s ' "$URL"

    curl -sS \
      --max-time 15 \
      -o /dev/null \
      -w 'http=%{http_code} time=%{time_total}\n' \
      "http://127.0.0.1:4040$URL" \
      || true

done


echo
echo "========== [9/9] DISCOVERY RESULT =========="

echo "PHASE6_PASS0_MODE=READ_ONLY"
echo "PRODUCTION_MUTATION=NO"
echo "SERVICE_RESTART=NO"

echo "DISCOVERY_COMPLETE=YES"

echo
echo "PHASE6_PASS0_COUNTRY_CATALOG_DISCOVERY_SUCCESS"
