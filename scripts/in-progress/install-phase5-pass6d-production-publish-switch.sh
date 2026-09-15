#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass6d-controlled-production-publish-switch"

PROJECT="/opt/config-location"
REPO="/root/project-log"

PUBLISH_DIR="$PROJECT/app/publish"
ADAPTER="$PROJECT/app/country/production_publish_projection.py"

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

    if [ -d "$BACKUP_DIR/publish" ]; then
        rm -rf "$PUBLISH_DIR"
        cp -a "$BACKUP_DIR/publish" "$PUBLISH_DIR"
    fi

    if [ -f "$BACKUP_DIR/production_publish_projection.py.before" ]; then

        cp -a \
          "$BACKUP_DIR/production_publish_projection.py.before" \
          "$ADAPTER"

    else

        rm -f "$ADAPTER"

    fi

    systemctl restart config-location-panel.service 2>/dev/null || true

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
CONTROLLED PRODUCTION PUBLISH SWITCH

Rollback:
$ROLLED_BACK

Config mutation:
NONE

Country canonical-store mutation:
NONE

/sub/all preservation:
REQUIRED

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
echo " PHASE 5 PASS 6D"
echo " CONTROLLED PRODUCTION PUBLISH SWITCH"
echo " AUTOMATIC ROLLBACK"
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

test -d "$PUBLISH_DIR" || {
    fail "publish directory missing"
    exit 1
}

test -f "$PROJECT/app/country/projection.py" || {
    fail "projection missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/12] BACKUP =========="

cp -a "$PUBLISH_DIR" "$BACKUP_DIR/publish"

if [ -f "$ADAPTER" ]; then
    cp -a \
      "$ADAPTER" \
      "$BACKUP_DIR/production_publish_projection.py.before"
fi

echo "BACKUP_OK"


################################################
# 3 HASH BASELINE
################################################

echo
echo "========== [3/12] HASH BASELINE =========="

HASH_BEFORE="$(
find "$PUBLISH_DIR" \
  -type f \
  -name '*.py' \
  -print0 \
| sort -z \
| xargs -0 sha256sum \
| sha256sum \
| awk '{print $1}'
)"

echo "PUBLISH_HASH_BEFORE=$HASH_BEFORE"


################################################
# 4 /sub/all BASELINE
################################################

echo
echo "========== [4/12] SUB ALL BASELINE =========="

SUB_ALL_URL="http://127.0.0.1:4040/sub/all"

SUB_BEFORE="/tmp/phase5-pass6d-sub-before.txt"

HTTP_BEFORE="$(
curl \
  -sS \
  --max-time 15 \
  -o "$SUB_BEFORE" \
  -w '%{http_code}' \
  "$SUB_ALL_URL" \
  || true
)"

echo "HTTP_BEFORE=$HTTP_BEFORE"

[ "$HTTP_BEFORE" = "200" ] || {
    fail "/sub/all baseline not HTTP 200"
    exit 1
}

SIZE_BEFORE="$(stat -c '%s' "$SUB_BEFORE")"
SHA_BEFORE="$(sha256sum "$SUB_BEFORE" | awk '{print $1}')"

echo "SUB_SIZE_BEFORE=$SIZE_BEFORE"
echo "SUB_SHA_BEFORE=$SHA_BEFORE"


################################################
# 5 INSTALL PROJECTION ADAPTER
################################################

echo
echo "========== [5/12] INSTALL ADAPTER =========="

cat > "$ADAPTER" <<'PY'
from __future__ import annotations

from functools import lru_cache
from typing import Any

from app.country.projection import (
    build_projection,
)


@lru_cache(maxsize=1)
def projection() -> dict[str,Any]:
    return build_projection()


def refresh() -> None:
    projection.cache_clear()


def country_for_config(
    config_id: str,
) -> dict[str,Any]:

    row=(
        projection()
        .get("records",{})
        .get(str(config_id))
    )

    if not isinstance(row,dict):
        return {
            "state":"unknown",
            "country_code":None,
            "country_name":None,
            "flag":None,
        }

    return row


def country_code_for_config(
    config_id: str,
) -> str | None:

    row=country_for_config(
        config_id
    )

    if row.get("state")!="resolved":
        return None

    code=row.get(
        "country_code"
    )

    if (
        isinstance(code,str)
        and len(code.strip())==2
    ):
        return code.strip().upper()

    return None


def config_ids_for_country(
    country_code: str,
    config_ids,
) -> list[str]:

    wanted=str(
        country_code
    ).strip().upper()

    out=[]

    for cid in config_ids:

        if (
            country_code_for_config(
                str(cid)
            )
            == wanted
        ):
            out.append(
                str(cid)
            )

    return out
PY

echo "ADAPTER_INSTALLED"


################################################
# 6 DISCOVER EXACT PUBLISH HOOK
################################################

echo
echo "========== [6/12] DISCOVER PUBLISH HOOK =========="

HOOK_JSON="$DISCOVERY_DIR/${PHASE}-${TS}-hook.json"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$PUBLISH_DIR" "$HOOK_JSON" <<'PY'
import ast
import json
import sys
from pathlib import Path

root=Path(sys.argv[1])

rows=[]

for path in sorted(
    root.rglob("*.py")
):

    try:
        tree=ast.parse(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        continue

    for node in ast.walk(tree):

        if not isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
            ),
        ):
            continue

        low=node.name.lower()

        if (
            "country" in low
            and any(
                x in low
                for x in (
                    "sub",
                    "config",
                    "publish",
                    "list",
                    "get",
                )
            )
        ):

            rows.append(
                {
                    "file":
                        str(path),

                    "function":
                        node.name,

                    "line":
                        node.lineno,
                }
            )

Path(
    sys.argv[2]
).write_text(
    json.dumps(
        rows,
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)

print(
    json.dumps(
        rows,
        ensure_ascii=False,
        indent=2,
    )
)

if not rows:
    raise SystemExit(2)
PY

echo "HOOK_DISCOVERY_OK"


################################################
# 7 CONTROLLED PATCH
################################################

echo
echo "========== [7/12] CONTROLLED PATCH =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$HOOK_JSON" <<'PY'
import ast
import json
import sys
from pathlib import Path


hooks=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

if len(hooks) != 1:

    print(
        "FAIL_CLOSED_EXPECTED_ONE_HOOK",
        len(hooks),
    )

    raise SystemExit(3)


hook=hooks[0]

path=Path(
    hook["file"]
)

target=hook[
    "function"
]


source=path.read_text(
    encoding="utf-8"
)

tree=ast.parse(
    source
)


class Patch(ast.NodeTransformer):

    def __init__(self):
        self.changed=0

    def visit_FunctionDef(
        self,
        node,
    ):

        if node.name != target:
            return self.generic_visit(
                node
            )

        args=[
            arg.arg
            for arg in node.args.args
        ]

        country_arg=None

        for name in args:

            if "country" in name.lower():
                country_arg=name
                break

        if not country_arg:

            print(
                "NO_COUNTRY_ARGUMENT"
            )

            raise SystemExit(4)


        # We deliberately do not rewrite
        # /sub/all or generic publish paths.
        if "all" in node.name.lower():

            print(
                "REFUSE_GENERIC_ALL_ENDPOINT"
            )

            raise SystemExit(5)


        injected=ast.parse(
f'''
from app.country.production_publish_projection import config_ids_for_country
'''
        ).body[0]

        if not any(
            isinstance(x,ast.ImportFrom)
            and x.module
            ==
            "app.country.production_publish_projection"
            for x in tree.body
        ):

            tree.body.insert(
                0,
                injected
            )


        # Exact hook must already operate on
        # an iterable named config_ids or ids.
        local_names={
            n.id
            for n in ast.walk(node)
            if isinstance(
                n,
                ast.Name,
            )
        }

        source_name=None

        for candidate in (
            "config_ids",
            "ids",
            "publishable_ids",
        ):

            if candidate in local_names:
                source_name=candidate
                break


        if not source_name:

            print(
                "NO_SAFE_CONFIG_ID_COLLECTION"
            )

            raise SystemExit(6)


        assign=ast.parse(
f'''
{source_name} = config_ids_for_country(
    {country_arg},
    {source_name},
)
'''
        ).body[0]


        node.body.insert(
            0,
            assign
        )

        self.changed += 1

        return self.generic_visit(
            node
        )


patch=Patch()

tree=patch.visit(
    tree
)

ast.fix_missing_locations(
    tree
)


if patch.changed != 1:

    print(
        "PATCH_COUNT_INVALID",
        patch.changed,
    )

    raise SystemExit(7)


path.write_text(
    ast.unparse(
        tree
    )
    + "\n",
    encoding="utf-8",
)

print(
    "PATCHED_FILE=",
    path,
)

print(
    "PATCHED_FUNCTION=",
    target,
)

print(
    "PATCH_COUNT=",
    patch.changed,
)
PY

echo "CONTROLLED_PATCH_OK"


################################################
# 8 COMPILE / IMPORT
################################################

echo
echo "========== [8/12] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/production_publish_projection.py \
  app/country/projection.py \
  app/publish/*.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import app.country.production_publish_projection

print("IMPORT_OK")
PY


################################################
# 9 SERVICE RESTART
################################################

echo
echo "========== [9/12] SERVICE =========="

systemctl restart \
  config-location-panel.service

sleep 3

ACTIVE="$(
systemctl is-active \
config-location-panel.service \
|| true
)"

echo "PANEL_ACTIVE=$ACTIVE"

if [ "$ACTIVE" != "active" ]; then

    rollback

    fail "panel failed after switch"
    exit 1
fi


################################################
# 10 /sub/all PRESERVATION
################################################

echo
echo "========== [10/12] SUB ALL REGRESSION =========="

SUB_AFTER="/tmp/phase5-pass6d-sub-after.txt"

HTTP_AFTER="$(
curl \
  -sS \
  --max-time 15 \
  -o "$SUB_AFTER" \
  -w '%{http_code}' \
  "$SUB_ALL_URL" \
  || true
)"

echo "HTTP_AFTER=$HTTP_AFTER"

if [ "$HTTP_AFTER" != "200" ]; then

    rollback

    fail "/sub/all not HTTP 200 after switch"
    exit 1
fi


SIZE_AFTER="$(stat -c '%s' "$SUB_AFTER")"
SHA_AFTER="$(sha256sum "$SUB_AFTER" | awk '{print $1}')"

echo "SUB_SIZE_AFTER=$SIZE_AFTER"
echo "SUB_SHA_AFTER=$SHA_AFTER"


# Content may naturally rotate,
# but catastrophic shrink is forbidden.
MIN_SIZE="$(( SIZE_BEFORE * 70 / 100 ))"

if [ "$SIZE_AFTER" -lt "$MIN_SIZE" ]; then

    rollback

    fail "/sub/all shrank by more than 30%"
    exit 1
fi

echo "SUB_ALL_PRESERVATION_OK"


################################################
# 11 RUNTIME REGRESSION
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

    fail "runtime error after switch"
    exit 1
fi


echo "RUNTIME_REGRESSION_OK"


################################################
# 12 FINAL SUMMARY
################################################

echo
echo "========== [12/12] FINAL =========="

HASH_AFTER="$(
find "$PUBLISH_DIR" \
  -type f \
  -name '*.py' \
  -print0 \
| sort -z \
| xargs -0 sha256sum \
| sha256sum \
| awk '{print $1}'
)"


"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<PY
import json
import sys

out={
    "phase":
        "$PHASE",

    "result":
        "SUCCESS",

    "production_publish_wiring":
        True,

    "country_source":
        "CANONICAL_PROJECTION_V2",

    "sub_all_preserved":
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

    "publish_hash_before":
        "$HASH_BEFORE",

    "publish_hash_after":
        "$HASH_AFTER",

    "automatic_rollback":
        True,

    "rolled_back":
        False,

    "config_write":
        False,

    "country_store_write":
        False,
}

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        out,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")

print(
    json.dumps(
        out,
        ensure_ascii=False,
        indent=2,
    )
)
PY


echo "PRODUCTION_PUBLISH_WIRING=ENABLED"
echo "COUNTRY_SOURCE=CANONICAL_PROJECTION_V2"

echo "SUB_ALL_PRESERVATION=PASS"
echo "RUNTIME_REGRESSION=PASS"

echo "CONFIG_WRITE=NO"
echo "COUNTRY_STORE_WRITE=NO"

echo "AUTOMATIC_ROLLBACK=READY"
echo "ROLLED_BACK=NO"

echo
echo "PHASE5_PASS6D_SUCCESS"

RESULT="SUCCESS"
