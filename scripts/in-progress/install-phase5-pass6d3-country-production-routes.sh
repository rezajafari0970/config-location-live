#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass6d3-dedicated-production-country-subscription-routes"

PROJECT="/opt/config-location"
REPO="/root/project-log"

HTTP="$PROJECT/app/publish/http.py"
PROJECTION="$PROJECT/app/country/production_publish_projection.py"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR" \
  "$BACKUP_DIR"

RESULT="SUCCESS"
ERRORS=""
ROLLED_BACK="NO"

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

rollback() {

    echo
    echo "========== AUTOMATIC ROLLBACK =========="

    cp -a \
      "$BACKUP_DIR/http.py.before" \
      "$HTTP"

    systemctl restart \
      config-location-panel.service \
      2>/dev/null || true

    ROLLED_BACK="YES"

    echo "ROLLBACK_DONE"
}

finish() {

    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
    fi

    cat > "$REPORT" <<REPORT
CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Mode:
DEDICATED PRODUCTION COUNTRY SUBSCRIPTION ROUTES

Production Country endpoint:
/sub/country/{country_code}

Existing /sub/all mutation:
NO LOGICAL CHANGE REQUIRED

Existing /sub/{config_type} mutation:
NO LOGICAL CHANGE REQUIRED

Rollback:
$ROLLED_BACK

Config mutation:
NONE

Country canonical store mutation:
NONE

Summary:
$SUMMARY

Backup:
$BACKUP_DIR

Log:
$LOG

Errors:
$ERRORS
REPORT

    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$REPO" || exit 1

    git add \
      "$LOG" \
      "$REPORT" \
      "$SUMMARY" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase execution $PHASE $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT


echo "================================================"
echo " PHASE 5 PASS 6D.3"
echo " DEDICATED PRODUCTION COUNTRY ROUTES"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/12] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f "$HTTP" || {
    fail "publish http.py missing"
    exit 1
}

test -f "$PROJECTION" || {
    fail "production country projection adapter missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/12] BACKUP =========="

cp -a \
  "$HTTP" \
  "$BACKUP_DIR/http.py.before"

echo "BACKUP_OK"


################################################
# 3 BASELINE /sub/all
################################################

echo
echo "========== [3/12] SUB ALL BASELINE =========="

BEFORE="/tmp/pass6d3-sub-all-before.txt"

HTTP_BEFORE="$(
curl \
  -sS \
  --max-time 15 \
  -o "$BEFORE" \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  || true
)"

[ "$HTTP_BEFORE" = "200" ] || {
    fail "/sub/all baseline unhealthy"
    exit 1
}

SIZE_BEFORE="$(
stat -c '%s' "$BEFORE"
)"

SHA_BEFORE="$(
sha256sum "$BEFORE" \
| awk '{print $1}'
)"

echo "HTTP_BEFORE=$HTTP_BEFORE"
echo "SIZE_BEFORE=$SIZE_BEFORE"
echo "SHA_BEFORE=$SHA_BEFORE"


################################################
# 4 SNAPSHOT CONTRACT INSPECTION
################################################

echo
echo "========== [4/12] SNAPSHOT CONTRACT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.publish.filter import (
    build_publish_snapshot,
)

snap=build_publish_snapshot()

assert isinstance(snap,dict)

print(
    "SNAPSHOT_KEYS=",
    sorted(snap.keys()),
)

records=snap.get(
    "records"
)

if records is None:
    records=snap.get(
        "publishable_records"
    )

if records is None:
    records=snap.get(
        "configs"
    )

assert isinstance(
    records,
    list,
), (
    "No list-like canonical record collection "
    "found in publish snapshot"
)

print(
    "RECORD_COUNT=",
    len(records),
)

if records:
    first=records[0]

    assert isinstance(
        first,
        dict,
    )

    print(
        "FIRST_RECORD_KEYS=",
        sorted(first.keys()),
    )

    cid=(
        first.get("config_id")
        or first.get("id")
    )

    print(
        "FIRST_CONFIG_ID=",
        cid,
    )

    assert cid is not None

print("SNAPSHOT_CONTRACT_OK")
PY


################################################
# 5 PATCH HTTP MODULE
################################################

echo
echo "========== [5/12] PATCH HTTP =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$HTTP" <<'PY'
import ast
import sys
from pathlib import Path


path=Path(
    sys.argv[1]
)

source=path.read_text(
    encoding="utf-8",
)

tree=ast.parse(
    source
)


function_names={
    node.name
    for node in tree.body
    if isinstance(
        node,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    )
}


required={
    "_subscription_text",
    "subscription_all",
    "subscription_type",
    "install_publish_routes",
}

missing=required-function_names

if missing:
    raise SystemExit(
        "REQUIRED_FUNCTIONS_MISSING="
        + ",".join(
            sorted(missing)
        )
    )


if "subscription_country" in function_names:
    raise SystemExit(
        "COUNTRY_ROUTE_ALREADY_INSTALLED"
    )


import_node=ast.ImportFrom(
    module=(
        "app.country."
        "production_publish_projection"
    ),
    names=[
        ast.alias(
            name="country_code_for_config",
        )
    ],
    level=0,
)


already_imported=False

for node in tree.body:

    if (
        isinstance(
            node,
            ast.ImportFrom,
        )
        and node.module
        ==
        "app.country.production_publish_projection"
    ):
        already_imported=True


if not already_imported:

    insert_at=0

    if (
        tree.body
        and isinstance(
            tree.body[0],
            ast.Expr,
        )
        and isinstance(
            tree.body[0].value,
            ast.Constant,
        )
        and isinstance(
            tree.body[0].value.value,
            str,
        )
    ):
        insert_at=1

    while (
        insert_at < len(tree.body)
        and isinstance(
            tree.body[insert_at],
            (
                ast.Import,
                ast.ImportFrom,
            ),
        )
    ):
        insert_at += 1

    tree.body.insert(
        insert_at,
        import_node,
    )


country_source=r'''
def _country_subscription_text(country_code):
    snapshot = build_publish_snapshot()

    records = snapshot.get("records")

    if records is None:
        records = snapshot.get("publishable_records")

    if records is None:
        records = snapshot.get("configs")

    if not isinstance(records, list):
        raise RuntimeError(
            "canonical publish record collection unavailable"
        )

    wanted = str(
        country_code or ""
    ).strip().upper()

    if not wanted:
        return "", snapshot, 0

    if wanted != "UNKNOWN":
        if (
            len(wanted) != 2
            or not wanted.isalpha()
        ):
            return "", snapshot, 0

    lines = []

    for record in records:

        if not isinstance(record, dict):
            continue

        cid = (
            record.get("config_id")
            or record.get("id")
        )

        if cid is None:
            continue

        resolved = country_code_for_config(
            str(cid)
        )

        if wanted == "UNKNOWN":
            match = resolved is None
        else:
            match = resolved == wanted

        if not match:
            continue

        raw = record.get("raw")

        if isinstance(raw, str):
            raw = raw.strip()

            if raw:
                lines.append(raw)

    return "\n".join(lines), snapshot, len(lines)


async def subscription_country(request):

    country_code = str(
        request.match_info.get(
            "country_code",
            ""
        )
    ).strip().upper()

    text, snapshot, count = (
        _country_subscription_text(
            country_code
        )
    )

    if (
        country_code != "UNKNOWN"
        and (
            len(country_code) != 2
            or not country_code.isalpha()
        )
    ):
        raise web.HTTPNotFound()

    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Country":
                country_code,

            "X-Config-Publishable":
                str(
                    snapshot.get(
                        "publishable",
                        0,
                    )
                ),

            "X-Config-Country-Count":
                str(count),

            "X-Country-Source":
                "canonical-projection-v2",
        },
    )
'''

country_nodes=ast.parse(
    country_source
).body


install_index=None

for i,node in enumerate(
    tree.body
):

    if (
        isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
            ),
        )
        and node.name
        ==
        "install_publish_routes"
    ):
        install_index=i
        break


if install_index is None:
    raise SystemExit(
        "INSTALL_ROUTE_FUNCTION_NOT_FOUND"
    )


for offset,node in enumerate(
    country_nodes
):

    tree.body.insert(
        install_index + offset,
        node,
    )


install=None

for node in tree.body:

    if (
        isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
            ),
        )
        and node.name
        ==
        "install_publish_routes"
    ):
        install=node
        break


assert install is not None


route_exists=False

for node in ast.walk(
    install
):

    if not isinstance(
        node,
        ast.Call,
    ):
        continue

    for arg in node.args:

        if (
            isinstance(
                arg,
                ast.Constant,
            )
            and arg.value
            ==
            "/sub/country/{country_code}"
        ):
            route_exists=True


if route_exists:
    raise SystemExit(
        "COUNTRY_ROUTE_ALREADY_PRESENT"
    )


route_statement=ast.parse(
'''
app.router.add_get(
    "/sub/country/{country_code}",
    subscription_country,
)
'''
).body[0]


# Put the dedicated three-segment route
# before the generic /sub/{config_type}
# registration for maximum clarity.
insert_pos=None

for i,node in enumerate(
    install.body
):

    if not isinstance(
        node,
        ast.Expr,
    ):
        continue

    call=node.value

    if not isinstance(
        call,
        ast.Call,
    ):
        continue

    for arg in call.args:

        if (
            isinstance(
                arg,
                ast.Constant,
            )
            and arg.value
            ==
            "/sub/{config_type}"
        ):
            insert_pos=i
            break

    if insert_pos is not None:
        break


if insert_pos is None:

    raise SystemExit(
        "GENERIC_SUB_ROUTE_NOT_FOUND"
    )


install.body.insert(
    insert_pos,
    route_statement,
)


ast.fix_missing_locations(
    tree
)


new_source=ast.unparse(
    tree
) + "\n"


path.write_text(
    new_source,
    encoding="utf-8",
)


print(
    "PATCHED_FUNCTIONS="
    "_country_subscription_text,"
    "subscription_country"
)

print(
    "ROUTE_ADDED="
    "/sub/country/{country_code}"
)

print(
    "SUB_ALL_HANDLER_UNCHANGED=YES"
)

print(
    "SUB_TYPE_HANDLER_UNCHANGED=YES"
)
PY

echo "PATCH_OK"


################################################
# 6 COMPILE / IMPORT
################################################

echo
echo "========== [6/12] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/publish/http.py \
  app/publish/filter.py \
  app/country/production_publish_projection.py \
  app/country/projection.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import app.publish.http

assert hasattr(
    app.publish.http,
    "subscription_country",
)

assert hasattr(
    app.publish.http,
    "_country_subscription_text",
)

print("IMPORT_OK")
print("COUNTRY_HANDLER_PRESENT=YES")
PY


################################################
# 7 OFFLINE COUNTRY REGRESSION
################################################

echo
echo "========== [7/12] OFFLINE COUNTRY TEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.publish.http import (
    _country_subscription_text,
)

from app.country.projection import (
    build_projection,
)


projection=build_projection()

resolved_codes={}

for cid,row in projection[
    "records"
].items():

    if row.get(
        "state"
    ) != "resolved":
        continue

    code=row.get(
        "country_code"
    )

    if (
        isinstance(code,str)
        and len(code.strip())==2
    ):

        code=code.strip().upper()

        resolved_codes[
            code
        ]=(
            resolved_codes.get(
                code,
                0,
            )
            + 1
        )


assert resolved_codes

test_code=max(
    resolved_codes,
    key=resolved_codes.get,
)

text,snapshot,count=(
    _country_subscription_text(
        test_code
    )
)

assert isinstance(text,str)
assert count >= 0

print(
    "TEST_COUNTRY=",
    test_code,
)

print(
    "TEST_COUNTRY_COUNT=",
    count,
)

print(
    "SNAPSHOT_PUBLISHABLE=",
    snapshot.get(
        "publishable"
    ),
)

unknown_text,_,unknown_count=(
    _country_subscription_text(
        "UNKNOWN"
    )
)

assert isinstance(
    unknown_text,
    str,
)

print(
    "UNKNOWN_COUNT=",
    unknown_count,
)

print("OFFLINE_COUNTRY_TEST_OK")
PY


################################################
# 8 RESTART
################################################

echo
echo "========== [8/12] RESTART =========="

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

    fail "panel inactive after route install"
    exit 1
fi


################################################
# 9 /sub/all REGRESSION
################################################

echo
echo "========== [9/12] SUB ALL REGRESSION =========="

AFTER="/tmp/pass6d3-sub-all-after.txt"

HTTP_AFTER="$(
curl \
  -sS \
  --max-time 15 \
  -o "$AFTER" \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  || true
)"

if [ "$HTTP_AFTER" != "200" ]; then

    rollback

    fail "/sub/all failed after route install"
    exit 1
fi


SIZE_AFTER="$(
stat -c '%s' "$AFTER"
)"

SHA_AFTER="$(
sha256sum "$AFTER" \
| awk '{print $1}'
)"


echo "HTTP_AFTER=$HTTP_AFTER"
echo "SIZE_AFTER=$SIZE_AFTER"
echo "SHA_AFTER=$SHA_AFTER"


MIN="$(( SIZE_BEFORE * 70 / 100 ))"

if [ "$SIZE_AFTER" -lt "$MIN" ]; then

    rollback

    fail "/sub/all catastrophic shrink"
    exit 1
fi


echo "SUB_ALL_REGRESSION_OK"


################################################
# 10 LIVE COUNTRY CANARY
################################################

echo
echo "========== [10/12] COUNTRY ROUTE CANARY =========="

TEST_COUNTRY="$(
cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.projection import (
    build_projection,
)

counts={}

for row in build_projection()[
    "records"
].values():

    if row.get("state")!="resolved":
        continue

    code=row.get(
        "country_code"
    )

    if (
        isinstance(code,str)
        and len(code.strip())==2
    ):

        code=code.strip().upper()

        counts[code]=(
            counts.get(
                code,
                0,
            )
            + 1
        )

if not counts:
    raise SystemExit(1)

print(
    max(
        counts,
        key=counts.get,
    )
)
PY
)"


echo "TEST_COUNTRY=$TEST_COUNTRY"


COUNTRY_OUT="/tmp/pass6d3-country.txt"

COUNTRY_HTTP="$(
curl \
  -sS \
  --max-time 20 \
  -D /tmp/pass6d3-country.headers \
  -o "$COUNTRY_OUT" \
  -w '%{http_code}' \
  "http://127.0.0.1:4040/sub/country/$TEST_COUNTRY" \
  || true
)"


echo "COUNTRY_HTTP=$COUNTRY_HTTP"

if [ "$COUNTRY_HTTP" != "200" ]; then

    rollback

    fail "country endpoint not HTTP 200"
    exit 1
fi


grep -qi \
  '^X-Country-Source: canonical-projection-v2' \
  /tmp/pass6d3-country.headers \
  || {
      rollback
      fail "country projection response header missing"
      exit 1
  }


COUNTRY_SIZE="$(
stat -c '%s' "$COUNTRY_OUT"
)"


echo "COUNTRY_SIZE=$COUNTRY_SIZE"


UNKNOWN_HTTP="$(
curl \
  -sS \
  --max-time 20 \
  -o /tmp/pass6d3-unknown.txt \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/UNKNOWN \
  || true
)"


echo "UNKNOWN_HTTP=$UNKNOWN_HTTP"

if [ "$UNKNOWN_HTTP" != "200" ]; then

    rollback

    fail "UNKNOWN endpoint failed"
    exit 1
fi


INVALID_HTTP="$(
curl \
  -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/INVALID \
  || true
)"


echo "INVALID_HTTP=$INVALID_HTTP"

[ "$INVALID_HTTP" = "404" ] || {
    rollback
    fail "invalid country must return 404"
    exit 1
}


echo "COUNTRY_ROUTE_CANARY_OK"


################################################
# 11 RUNTIME ERRORS
################################################

echo
echo "========== [11/12] RUNTIME REGRESSION =========="

FATAL="$(
journalctl \
  -u config-location-panel.service \
  --since "$START" \
  --no-pager \
| grep -Ei \
  'Traceback|SyntaxError|ImportError|ModuleNotFoundError|fatal' \
|| true
)"


if [ -n "$FATAL" ]; then

    echo "$FATAL"

    rollback

    fail "runtime regression detected"
    exit 1
fi


echo "RUNTIME_REGRESSION_OK"


################################################
# 12 SUMMARY
################################################

echo
echo "========== [12/12] SUMMARY =========="

"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<PY
import json
import sys

data={
    "phase":
        "$PHASE",

    "result":
        "SUCCESS",

    "production_country_routes":
        True,

    "country_route":
        "/sub/country/{country_code}",

    "country_source":
        "CANONICAL_PROJECTION_V2",

    "sub_all_preserved":
        True,

    "sub_type_preserved":
        True,

    "sub_all_http_before":
        "$HTTP_BEFORE",

    "sub_all_http_after":
        "$HTTP_AFTER",

    "sub_all_size_before":
        $SIZE_BEFORE,

    "sub_all_size_after":
        $SIZE_AFTER,

    "sub_all_sha_before":
        "$SHA_BEFORE",

    "sub_all_sha_after":
        "$SHA_AFTER",

    "country_canary":
        "$TEST_COUNTRY",

    "country_canary_http":
        "$COUNTRY_HTTP",

    "country_canary_size":
        $COUNTRY_SIZE,

    "unknown_http":
        "$UNKNOWN_HTTP",

    "invalid_country_http":
        "$INVALID_HTTP",

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
echo "PRODUCTION_COUNTRY_ROUTES=ENABLED"
echo "COUNTRY_SOURCE=CANONICAL_PROJECTION_V2"

echo "SUB_ALL_PRESERVED=YES"
echo "SUB_TYPE_PRESERVED=YES"

echo "UNKNOWN_ROUTE=ENABLED"
echo "INVALID_COUNTRY_FAIL_CLOSED=YES"

echo "AUTOMATIC_ROLLBACK=READY"
echo "ROLLED_BACK=NO"

echo "CONFIG_WRITE=NO"
echo "CANONICAL_COUNTRY_STORE_WRITE=NO"

echo
echo "PHASE5_PASS6D3_SUCCESS"

RESULT="SUCCESS"
