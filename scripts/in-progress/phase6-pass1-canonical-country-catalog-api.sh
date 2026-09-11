#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"

HTTP="$PROJECT/app/publish/http.py"
CATALOG="$PROJECT/app/country/catalog.py"

BACKUP="$(mktemp -d)"
MUTATED=0

rollback() {
    RC=$?

    if [ "$MUTATED" -eq 1 ]; then

        echo
        echo "========== AUTOMATIC ROLLBACK =========="

        if [ -f "$BACKUP/http.py" ]; then
            cp -a "$BACKUP/http.py" "$HTTP"
        fi

        if [ -f "$BACKUP/catalog.py" ]; then
            cp -a "$BACKUP/catalog.py" "$CATALOG"
        else
            rm -f "$CATALOG"
        fi

        systemctl restart \
          config-location-panel.service \
          >/dev/null 2>&1 || true

        echo "ROLLBACK=COMPLETE"
    fi

    rm -rf "$BACKUP"

    exit "$RC"
}

trap rollback ERR

echo "================================================"
echo " PHASE 6 PASS 1"
echo " CANONICAL DYNAMIC COUNTRY CATALOG API"
echo "================================================"

echo
echo "========== [1/10] PRECHECK =========="

test -f "$HTTP"
test -x "$PROJECT/venv/bin/python"

systemctl is-active \
  config-location-panel.service \
  >/dev/null

curl -fsS \
  --max-time 10 \
  http://127.0.0.1:4040/api/publish/status \
  >/dev/null

echo "PRECHECK=PASS"


echo
echo "========== [2/10] BACKUP =========="

cp -a "$HTTP" "$BACKUP/http.py"

if [ -f "$CATALOG" ]; then
    cp -a "$CATALOG" "$BACKUP/catalog.py"
fi

MUTATED=1

echo "BACKUP=PASS"


echo
echo "========== [3/10] CREATE CATALOG READ MODEL =========="

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


def _normalise_country_code(
    value: Any,
) -> str | None:

    if not isinstance(
        value,
        str,
    ):
        return None

    value = (
        value
        .strip()
        .upper()
    )

    if (
        len(value) != 2
        or not value.isalpha()
    ):
        return None

    return value


def build_country_catalog() -> dict[str, Any]:
    """
    Canonical public catalog derived only from:

      1. current publishable snapshot
      2. canonical country production projection

    No static country allow-list is used.
    """

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


    country_counts: dict[
        str,
        int,
    ] = defaultdict(int)

    country_meta: dict[
        str,
        dict[str, Any],
    ] = {}


    unknown = 0
    conflict = 0
    resolved = 0


    for config in snapshot.configs:

        if not isinstance(
            config,
            dict,
        ):
            continue


        config_id = config.get(
            "id"
        )

        if not config_id:
            unknown += 1
            continue


        row = records.get(
            str(config_id)
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


        code = (
            _normalise_country_code(
                row.get(
                    "country_code"
                )
            )
        )


        if code is None:

            unknown += 1
            continue


        resolved += 1

        country_counts[
            code
        ] += 1


        meta = country_meta.setdefault(
            code,
            {
                "country_name":
                    None,

                "flag":
                    None,
            },
        )


        name = row.get(
            "country_name"
        )

        if (
            not meta[
                "country_name"
            ]
            and isinstance(
                name,
                str,
            )
            and name.strip()
        ):

            meta[
                "country_name"
            ] = name.strip()


        flag = row.get(
            "flag"
        )

        if (
            not meta[
                "flag"
            ]
            and isinstance(
                flag,
                str,
            )
            and flag.strip()
        ):

            meta[
                "flag"
            ] = flag.strip()


    countries = []


    for code in sorted(
        country_counts
    ):

        meta = country_meta.get(
            code,
            {},
        )


        countries.append(
            {
                "code":
                    code,

                "country_code":
                    code,

                "country_name":
                    meta.get(
                        "country_name"
                    ),

                "flag":
                    meta.get(
                        "flag"
                    ),

                "count":
                    country_counts[
                        code
                    ],

                "subscription":
                    (
                        "/sub/country/"
                        + code
                    ),
            }
        )


    return {
        "schema":
            1,

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

echo "CATALOG_MODULE=CREATED"


echo
echo "========== [4/10] PATCH HTTP API =========="

"$PROJECT/venv/bin/python" \
- "$HTTP" <<'PY'
import ast
import sys
from pathlib import Path


path = Path(sys.argv[1])

source = path.read_text(
    encoding="utf-8",
)


if (
    "build_country_catalog"
    not in source
):

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

    if import_marker not in source:
        raise SystemExit(
            "CATALOG_IMPORT_MARKER_NOT_FOUND"
        )

    source = source.replace(
        import_marker,
        import_block,
        1,
    )


if (
    "async def country_catalog("
    not in source
):

    marker = '''async def publish_status(
    request: web.Request,
):
'''

    handler = '''async def country_catalog(
    request: web.Request,
):

    try:

        catalog = (
            build_country_catalog()
        )

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

    if marker not in source:
        raise SystemExit(
            "CATALOG_HANDLER_MARKER_NOT_FOUND"
        )

    source = source.replace(
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
    not in source
):

    marker = '''    app.router.add_get(
        "/api/publish/status",
        publish_status,
    )
'''

    if marker not in source:
        raise SystemExit(
            "CATALOG_ROUTE_MARKER_NOT_FOUND"
        )

    source = source.replace(
        marker,
        route + marker,
        1,
    )


# Semantic validation before writing.

tree = ast.parse(
    source
)

functions = {
    node.name
    for node in ast.walk(tree)
    if isinstance(
        node,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    )
}

if "country_catalog" not in functions:
    raise SystemExit(
        "COUNTRY_CATALOG_HANDLER_MISSING"
    )


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
        and isinstance(
            first.value,
            str,
        )
    ):
        routes.append(
            first.value
        )


if routes.count(
    "/api/countries"
) != 1:

    raise SystemExit(
        "COUNTRY_CATALOG_ROUTE_COUNT_INVALID"
    )


path.write_text(
    source,
    encoding="utf-8",
)

print(
    "HTTP_CATALOG_PATCH=PASS"
)
PY


echo
echo "========== [5/10] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/catalog.py \
  app/publish/http.py

echo "COMPILE=PASS"


echo
echo "========== [6/10] UNIT CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.catalog import (
    build_country_catalog,
)

catalog = (
    build_country_catalog()
)

assert (
    catalog[
        "schema"
    ]
    == 1
)

assert (
    catalog[
        "source"
    ]
    == "canonical-projection-v2"
)

assert isinstance(
    catalog[
        "countries"
    ],
    list,
)

assert (
    catalog[
        "country_count"
    ]
    == len(
        catalog[
            "countries"
        ]
    )
)

codes = [
    row[
        "code"
    ]
    for row in catalog[
        "countries"
    ]
]

assert codes == sorted(
    set(codes)
)

assert all(
    len(code) == 2
    and code.isalpha()
    and code.isupper()
    for code in codes
)

assert (
    catalog[
        "resolved"
    ]
    + catalog[
        "unknown"
    ]
    + catalog[
        "conflict"
    ]
    == catalog[
        "publishable"
    ]
)

print(
    "COUNTRY_COUNT=",
    catalog[
        "country_count"
    ],
)

print(
    "RESOLVED=",
    catalog[
        "resolved"
    ],
)

print(
    "UNKNOWN=",
    catalog[
        "unknown"
    ],
)

print(
    "CONFLICT=",
    catalog[
        "conflict"
    ],
)

print(
    "UNIT_CONTRACT=PASS"
)
PY


echo
echo "========== [7/10] CONTROLLED RESTART =========="

systemctl restart \
  config-location-panel.service

sleep 4

test "$(
    systemctl is-active \
      config-location-panel.service
)" = "active"

echo "PANEL_RESTART=PASS"


echo
echo "========== [8/10] HTTP CATALOG REGRESSION =========="

HDR="/tmp/phase6-pass1-catalog.headers"
BODY="/tmp/phase6-pass1-catalog.json"

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
    "HTTP_COUNTRY_COUNT=",
    data[
        "country_count"
    ]
)

print(
    "HTTP_PUBLISHABLE=",
    data[
        "publishable"
    ]
)

print(
    "HTTP_CONTRACT=PASS"
)
PY


echo
echo "========== [9/10] EVERY COUNTRY ROUTE =========="

"$PROJECT/venv/bin/python" \
- "$BODY" <<'PY'
import json
import urllib.error
import urllib.request
import sys


catalog = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)


failed = []


for item in catalog[
    "countries"
]:

    code = item[
        "code"
    ]

    expected = int(
        item[
            "count"
        ]
    )


    request = urllib.request.Request(
        "http://127.0.0.1:4040"
        + item[
            "subscription"
        ],
        headers={
            "User-Agent":
                "phase6-pass1-regression",
        },
    )


    try:

        with urllib.request.urlopen(
            request,
            timeout=15,
        ) as response:

            status = int(
                response.status
            )

            header_count = int(
                response.headers.get(
                    "X-Config-Country-Count",
                    "-1",
                )
            )


    except Exception as exc:

        print(
            code,
            "ERROR",
            repr(exc),
        )

        failed.append(
            code
        )

        continue


    # Allow normal live churn between catalog build
    # and request, but contract/header must remain valid.

    ok = (
        status == 200
        and header_count >= 0
    )


    print(
        f"{code}: "
        f"catalog={expected} "
        f"http={header_count} "
        f"status={status} "
        f"ok={ok}"
    )


    if not ok:

        failed.append(
            code
        )


print(
    "COUNTRIES_TESTED=",
    len(
        catalog[
            "countries"
        ]
    ),
)

print(
    "COUNTRIES_FAILED=",
    len(failed),
)


if failed:

    print(
        "FAILED=",
        failed,
    )

    raise SystemExit(2)


print(
    "ALL_COUNTRY_ROUTES=PASS"
)
PY


echo
echo "========== [10/10] FINAL REGRESSION =========="

for SPEC in \
  "ALL|http://127.0.0.1:4040/sub/all|200" \
  "UNKNOWN|http://127.0.0.1:4040/sub/country/UNKNOWN|200" \
  "CONFLICT|http://127.0.0.1:4040/sub/country/CONFLICT|200" \
  "INVALID|http://127.0.0.1:4040/sub/country/INVALID|404" \
  "CATALOG|http://127.0.0.1:4040/api/countries|200"
do

    IFS='|' read -r \
      NAME URL EXPECT \
      <<<"$SPEC"

    CODE="$(
        curl -sS \
          --max-time 15 \
          -o /dev/null \
          -w '%{http_code}' \
          "$URL" \
          || true
    )"

    echo "$NAME=$CODE"

    test "$CODE" = "$EXPECT"

done


echo
echo "PHASE6_PASS1_MUTATION=SUCCESS"
echo "COUNTRY_CATALOG_DYNAMIC=YES"
echo "STATIC_COUNTRY_ALLOWLIST=NO"
echo "API_COUNTRIES=/api/countries"
echo "ROLLBACK=NOT_REQUIRED"

echo
echo "PHASE6_PASS1_CANONICAL_COUNTRY_CATALOG_SUCCESS"

MUTATED=0

rm -rf "$BACKUP"

trap - ERR
