#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"

HTTP="$PROJECT/app/publish/http.py"
SERVER="$PROJECT/app/panel/server.py"
CATALOG="$PROJECT/app/country/catalog.py"

BACKUP="$(mktemp -d)"
MUTATED=0

wait_panel() {

    for _ in $(seq 1 30); do

        if systemctl is-active \
            config-location-panel.service \
            >/dev/null 2>&1
        then

            CODE="$(
                curl -sS \
                  --max-time 3 \
                  -o /dev/null \
                  -w '%{http_code}' \
                  http://127.0.0.1:4040/sub/all \
                  2>/dev/null || true
            )"

            if [ "$CODE" = "200" ]; then
                return 0
            fi
        fi

        sleep 1
    done

    return 1
}


rollback() {
    RC=$?

    if [ "$MUTATED" -eq 1 ]; then

        echo
        echo "========== AUTOMATIC ROLLBACK =========="

        cp -a "$BACKUP/http.py" "$HTTP"
        cp -a "$BACKUP/server.py" "$SERVER"

        if [ -f "$BACKUP/catalog.py" ]; then
            cp -a "$BACKUP/catalog.py" "$CATALOG"
        else
            rm -f "$CATALOG"
        fi

        systemctl restart \
          config-location-panel.service \
          >/dev/null 2>&1 || true

        wait_panel || true

        echo "ROLLBACK=COMPLETE"
    fi

    rm -rf "$BACKUP"

    exit "$RC"
}

trap rollback ERR


echo "================================================"
echo " PHASE 6 PASS 1B"
echo " PUBLIC COUNTRY CATALOG FIX"
echo "================================================"


echo
echo "========== [1/11] PRECHECK =========="

test -f "$HTTP"
test -f "$SERVER"
test -x "$PROJECT/venv/bin/python"

wait_panel

echo "PRECHECK=PASS"


echo
echo "========== [2/11] BACKUP =========="

cp -a "$HTTP" "$BACKUP/http.py"
cp -a "$SERVER" "$BACKUP/server.py"

if [ -f "$CATALOG" ]; then
    cp -a "$CATALOG" "$BACKUP/catalog.py"
fi

MUTATED=1

echo "BACKUP=PASS"


echo
echo "========== [3/11] CREATE CATALOG MODULE =========="

cat > "$CATALOG" <<'PY'
from __future__ import annotations

from collections import defaultdict
from typing import Any

from app.publish.filter import (
    build_publish_snapshot,
)

from app.country.production_publish_projection import (
    get_country_projection,
)


def _code(
    value: Any,
) -> str | None:

    if not isinstance(
        value,
        str,
    ):
        return None

    value = value.strip().upper()

    if (
        len(value) != 2
        or not value.isalpha()
    ):
        return None

    return value


def build_country_catalog() -> dict[str, Any]:

    snapshot = (
        build_publish_snapshot()
    )

    projection = (
        get_country_projection()
    )

    records = projection.get(
        "records",
        {},
    )

    if not isinstance(
        records,
        dict,
    ):
        records = {}


    counts: dict[str, int] = defaultdict(int)

    meta: dict[
        str,
        dict[str, Any],
    ] = {}

    resolved = 0
    unknown = 0
    conflict = 0


    for config in snapshot.configs:

        if not isinstance(
            config,
            dict,
        ):
            continue

        cid = config.get("id")

        if not cid:
            unknown += 1
            continue

        row = records.get(
            str(cid)
        )

        if not isinstance(
            row,
            dict,
        ):
            unknown += 1
            continue

        state = str(
            row.get(
                "state",
                "unknown",
            )
        ).strip().lower()

        if state == "conflict":
            conflict += 1
            continue

        if state != "resolved":
            unknown += 1
            continue

        code = _code(
            row.get(
                "country_code"
            )
        )

        if code is None:
            unknown += 1
            continue

        resolved += 1
        counts[code] += 1

        item = meta.setdefault(
            code,
            {
                "country_name": None,
                "flag": None,
            },
        )

        name = row.get(
            "country_name"
        )

        if (
            item["country_name"] is None
            and isinstance(name, str)
            and name.strip()
        ):
            item["country_name"] = (
                name.strip()
            )

        flag = row.get("flag")

        if (
            item["flag"] is None
            and isinstance(flag, str)
            and flag.strip()
        ):
            item["flag"] = (
                flag.strip()
            )


    countries = []

    for code in sorted(counts):

        item = meta.get(
            code,
            {},
        )

        countries.append(
            {
                "code": code,

                "country_code": code,

                "country_name":
                    item.get(
                        "country_name"
                    ),

                "flag":
                    item.get(
                        "flag"
                    ),

                "count":
                    counts[code],

                "subscription":
                    "/sub/country/"
                    + code,
            }
        )


    return {
        "schema": 1,

        "source":
            "canonical-projection-v2",

        "mode":
            "production",

        "publishable":
            snapshot.publishable,

        "resolved":
            resolved,

        "unknown":
            unknown,

        "conflict":
            conflict,

        "country_count":
            len(countries),

        "countries":
            countries,

        "special_routes": {
            "unknown":
                "/sub/country/UNKNOWN",

            "conflict":
                "/sub/country/CONFLICT",
        },
    }
PY

echo "CATALOG_MODULE=PASS"


echo
echo "========== [4/11] PATCH PUBLISH HTTP =========="

"$PROJECT/venv/bin/python" \
- "$HTTP" <<'PY'
import ast
import sys
from pathlib import Path


path = Path(sys.argv[1])

s = path.read_text(
    encoding="utf-8",
)


import_marker = '''from app.country.production_publish_projection import (
    get_country_projection,
)
'''

import_block = '''from app.country.production_publish_projection import (
    get_country_projection,
)

from app.country.catalog import (
    build_country_catalog,
)
'''


if (
    "from app.country.catalog import"
    not in s
):

    if import_marker not in s:
        raise SystemExit(
            "CATALOG_IMPORT_MARKER_NOT_FOUND"
        )

    s = s.replace(
        import_marker,
        import_block,
        1,
    )


handler = '''async def country_catalog(
    request: web.Request,
):

    try:

        catalog = build_country_catalog()

    except Exception:

        raise web.HTTPServiceUnavailable(
            headers={
                "Cache-Control":
                    "no-store",

                "Retry-After":
                    "5",

                "X-Country-Source":
                    "canonical-projection-v2",

                "X-Country-Catalog-Contract":
                    "unavailable",
            }
        )

    return web.json_response(
        catalog,
        headers={
            "Cache-Control":
                "no-store",

            "X-Country-Source":
                "canonical-projection-v2",

            "X-Country-Catalog-Contract":
                "healthy",

            "X-Country-Count":
                str(
                    catalog[
                        "country_count"
                    ]
                ),
        },
    )


'''


if (
    "async def country_catalog("
    not in s
):

    marker = '''async def publish_status(
    request: web.Request,
):
'''

    if marker not in s:
        raise SystemExit(
            "CATALOG_HANDLER_MARKER_NOT_FOUND"
        )

    s = s.replace(
        marker,
        handler + marker,
        1,
    )


route = '''    app.router.add_get(
        "/api/countries",
        country_catalog,
    )

'''


if (
    '"/api/countries"'
    not in s
):

    marker = '''    app.router.add_get(
        "/api/publish/status",
        publish_status,
    )
'''

    if marker not in s:
        raise SystemExit(
            "CATALOG_ROUTE_MARKER_NOT_FOUND"
        )

    s = s.replace(
        marker,
        route + marker,
        1,
    )


tree = ast.parse(s)

routes = []

for node in ast.walk(tree):

    if not isinstance(
        node,
        ast.Call,
    ):
        continue

    if not isinstance(
        node.func,
        ast.Attribute,
    ):
        continue

    if node.func.attr != "add_get":
        continue

    if not node.args:
        continue

    first = node.args[0]

    if (
        isinstance(
            first,
            ast.Constant,
        )
        and first.value
        == "/api/countries"
    ):
        routes.append(
            first.value
        )


if len(routes) != 1:
    raise SystemExit(
        "CATALOG_ROUTE_INVALID"
    )


path.write_text(
    s,
    encoding="utf-8",
)

print(
    "HTTP_PATCH=PASS"
)
PY


echo
echo "========== [5/11] DISCOVER AUTH EXEMPTION CONTRACT =========="

"$PROJECT/venv/bin/python" \
- "$SERVER" <<'PY'
import re
import sys
from pathlib import Path


p = Path(sys.argv[1])

s = p.read_text(
    encoding="utf-8",
)


candidates = [
    "/sub/all",
    "/sub/country/",
    "/api/publish/status",
]


hits = []

for line_no, line in enumerate(
    s.splitlines(),
    start=1,
):

    low = line.lower()

    if any(
        token.lower() in low
        for token in candidates
    ):
        hits.append(
            (
                line_no,
                line,
            )
        )


print(
    "AUTH_RELATED_HITS="
)

for line_no, line in hits[:100]:
    print(
        f"{line_no}:{line}"
    )


patterns = [
    r'public',
    r'exempt',
    r'auth',
    r'login',
    r'/sub/',
    r'api/publish/status',
]


for pattern in patterns:

    count = len(
        re.findall(
            pattern,
            s,
            flags=re.I,
        )
    )

    print(
        f"PATTERN_{pattern}={count}"
    )
PY


echo
echo "========== [6/11] PATCH PUBLIC AUTH EXEMPTION =========="

"$PROJECT/venv/bin/python" \
- "$SERVER" <<'PY'
import ast
import sys
from pathlib import Path


path = Path(sys.argv[1])

s = path.read_text(
    encoding="utf-8",
)


# We need /api/countries to have the same public behavior
# as the existing public subscription/publish endpoints.
#
# Search likely literal collections that already contain
# /api/publish/status or /sub/all and add /api/countries.

tree = ast.parse(
    s
)

patched = 0


for node in ast.walk(tree):

    if not isinstance(
        node,
        (
            ast.List,
            ast.Tuple,
            ast.Set,
        ),
    ):
        continue


    values = []

    for elt in node.elts:

        if (
            isinstance(
                elt,
                ast.Constant,
            )
            and isinstance(
                elt.value,
                str,
            )
        ):
            values.append(
                elt.value
            )


    looks_public = (
        "/api/publish/status"
        in values
        or "/sub/all"
        in values
    )


    if not looks_public:
        continue


    if (
        "/api/countries"
        in values
    ):
        patched += 1
        continue


    node.elts.append(
        ast.Constant(
            value="/api/countries"
        )
    )

    patched += 1


if patched == 0:

    # Fallback: handle direct boolean public-path checks
    # such as path == "/api/publish/status".

    marker = '"/api/publish/status"'

    if marker in s:

        # Insert catalog beside known public status route
        # where a literal container was not discoverable.
        #
        # We do not globally replace the marker; only add
        # a small helper clause to expressions containing it.

        tree2 = ast.parse(s)

        changed = 0

        for node in ast.walk(tree2):

            if not isinstance(
                node,
                ast.Compare,
            ):
                continue

            text = ast.unparse(node)

            if (
                "/api/publish/status"
                not in text
            ):
                continue

            # Too risky to mutate arbitrary compare syntax.
            # Leave source unchanged and force discovery fail.
            changed += 1


        if changed:
            raise SystemExit(
                "AUTH_PUBLIC_CONTRACT_REQUIRES_EXACT_PATCH"
            )


    raise SystemExit(
        "PUBLIC_AUTH_COLLECTION_NOT_FOUND"
    )


ast.fix_missing_locations(
    tree
)

result = (
    ast.unparse(tree)
    + "\n"
)


# Must still compile.
ast.parse(result)


path.write_text(
    result,
    encoding="utf-8",
)

print(
    "PUBLIC_AUTH_PATCH=PASS"
)

print(
    "PATCHED_COLLECTIONS=",
    patched,
)
PY


echo
echo "========== [7/11] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/catalog.py \
  app/publish/http.py \
  app/panel/server.py

echo "COMPILE=PASS"


echo
echo "========== [8/11] UNIT CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.catalog import (
    build_country_catalog,
)

c = build_country_catalog()

assert (
    c["country_count"]
    == len(c["countries"])
)

assert (
    c["resolved"]
    + c["unknown"]
    + c["conflict"]
    == c["publishable"]
)

codes = [
    x["code"]
    for x in c["countries"]
]

assert (
    codes
    == sorted(
        set(codes)
    )
)

print(
    "COUNTRY_COUNT=",
    c[
        "country_count"
    ],
)

print(
    "PUBLISHABLE=",
    c[
        "publishable"
    ],
)

print(
    "UNIT_CONTRACT=PASS"
)
PY


echo
echo "========== [9/11] RESTART + READINESS =========="

systemctl restart \
  config-location-panel.service

wait_panel

echo "PANEL_READY=PASS"


echo
echo "========== [10/11] PUBLIC HTTP CONTRACT =========="

HDR="/tmp/p6p1b.headers"
BODY="/tmp/p6p1b.json"

HTTP="$(
    curl -sS \
      --max-time 20 \
      -D "$HDR" \
      -o "$BODY" \
      -w '%{http_code}' \
      http://127.0.0.1:4040/api/countries
)"

echo "CATALOG_HTTP=$HTTP"

test "$HTTP" = "200"


"$PROJECT/venv/bin/python" \
- "$HDR" "$BODY" <<'PY'
import json
import sys
from pathlib import Path


headers = Path(
    sys.argv[1]
).read_text(
    encoding="utf-8",
    errors="replace",
)

data = json.loads(
    Path(
        sys.argv[2]
    ).read_text(
        encoding="utf-8",
    )
)


assert (
    "X-Country-Catalog-Contract: healthy"
    in headers
)

assert (
    "X-Country-Source: canonical-projection-v2"
    in headers
)

assert (
    data[
        "country_count"
    ]
    == len(
        data[
            "countries"
        ]
    )
)

assert (
    data[
        "resolved"
    ]
    + data[
        "unknown"
    ]
    + data[
        "conflict"
    ]
    == data[
        "publishable"
    ]
)

print(
    "HTTP_CONTRACT=PASS"
)

print(
    "COUNTRY_COUNT=",
    data[
        "country_count"
    ],
)
PY


echo
echo "========== [11/11] REGRESSION =========="

for SPEC in \
  "ALL|http://127.0.0.1:4040/sub/all|200" \
  "UNKNOWN|http://127.0.0.1:4040/sub/country/UNKNOWN|200" \
  "CONFLICT|http://127.0.0.1:4040/sub/country/CONFLICT|200" \
  "INVALID|http://127.0.0.1:4040/sub/country/INVALID|404" \
  "CATALOG|http://127.0.0.1:4040/api/countries|200"
do

    IFS='|' read -r NAME URL EXPECT \
      <<<"$SPEC"

    CODE="$(
        curl -sS \
          --max-time 15 \
          -o /dev/null \
          -w '%{http_code}' \
          "$URL" \
          2>/dev/null || true
    )"

    echo "$NAME=$CODE"

    test "$CODE" = "$EXPECT"

done


echo
echo "PHASE6_PASS1B=SUCCESS"
echo "CATALOG_PUBLIC=YES"
echo "CATALOG_DYNAMIC=YES"
echo "AUTH_REDIRECT=NO"
echo "ROLLBACK=NOT_REQUIRED"

echo
echo "PHASE6_PASS1B_PUBLIC_COUNTRY_CATALOG_SUCCESS"

MUTATED=0

rm -rf "$BACKUP"

trap - ERR
