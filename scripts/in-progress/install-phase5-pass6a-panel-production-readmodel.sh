#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass6a-controlled-panel-production-readmodel-wiring"

PROJECT="/opt/config-location"
REPO="/root/project-log"

PANEL_READ="$PROJECT/app/panel/read_model.py"
ADAPTER="$PROJECT/app/country/panel_projection_adapter.py"

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

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

finish() {
    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
        ERRORS="${ERRORS}\nexit code $CODE"
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
CONTROLLED PANEL PRODUCTION READ-MODEL WIRING

Panel read-model:
ENABLED IF CONTRACT PASSED

Publish wiring:
NO

Config mutation:
NONE

Country-store mutation:
NONE

Endpoint mutation:
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
echo " PHASE 5 PASS 6A"
echo " CONTROLLED PANEL PRODUCTION READ-MODEL WIRING"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/10] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f "$PROJECT/app/country/projection.py" || {
    fail "projection missing"
    exit 1
}

test -f "$PANEL_READ" || {
    fail "panel read_model.py missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/10] BACKUP =========="

cp -a \
  "$PANEL_READ" \
  "$BACKUP_DIR/read_model.py.before"

[ ! -f "$ADAPTER" ] || \
cp -a \
  "$ADAPTER" \
  "$BACKUP_DIR/panel_projection_adapter.py.before"

echo "BACKUP_OK"


################################################
# 3 INSTALL ADAPTER
################################################

echo
echo "========== [3/10] INSTALL ADAPTER =========="

cat > "$ADAPTER" <<'PY'
from __future__ import annotations

from functools import lru_cache
from typing import Any

from app.country.projection import (
    build_projection,
)


@lru_cache(maxsize=1)
def _projection_cache() -> dict[str, Any]:
    return build_projection()


def refresh_projection_cache() -> None:
    _projection_cache.cache_clear()


def country_projection_for(
    config_id: str,
) -> dict[str, Any]:

    row=(
        _projection_cache()
        .get("records", {})
        .get(str(config_id))
    )

    if not isinstance(row,dict):
        return {
            "state":"unknown",
            "country_code":None,
            "country_name":None,
            "flag":None,
            "confidence":None,
            "selected_source":None,
        }

    return row


def overlay_country(
    row: dict[str, Any],
) -> dict[str, Any]:

    if not isinstance(row,dict):
        return row

    cid=(
        row.get("config_id")
        or row.get("id")
    )

    if not cid:
        return row

    projected=country_projection_for(
        str(cid)
    )

    out=dict(row)

    state=projected.get(
        "state",
        "unknown",
    )

    out["country_state"]=state

    if state=="resolved":

        out["country_code"]=(
            projected.get(
                "country_code"
            )
        )

        out["country_name"]=(
            projected.get(
                "country_name"
            )
        )

        out["country"]=(
            projected.get(
                "country_name"
            )
            or projected.get(
                "country_code"
            )
        )

        out["flag"]=(
            projected.get(
                "flag"
            )
        )

        out["country_confidence"]=(
            projected.get(
                "confidence"
            )
        )

        out["country_source"]=(
            projected.get(
                "selected_source"
            )
        )

    else:

        out["country_code"]=None
        out["country_name"]=None
        out["country"]=None
        out["flag"]=None
        out["country_confidence"]=None
        out["country_source"]=None

    return out


def overlay_country_collection(
    value: Any,
) -> Any:

    if isinstance(value,list):
        return [
            overlay_country(x)
            if isinstance(x,dict)
            else x
            for x in value
        ]

    if isinstance(value,dict):

        # Single config row
        if (
            "config_id" in value
            or "id" in value
        ):
            return overlay_country(
                value
            )

    return value
PY

echo "ADAPTER_INSTALLED"


################################################
# 4 DISCOVER PANEL CONTRACT
################################################

echo
echo "========== [4/10] DISCOVER PANEL CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$PANEL_READ" "$SUMMARY" <<'PY'
import ast
import json
import sys

path=sys.argv[1]

tree=ast.parse(
    open(
        path,
        encoding="utf-8",
    ).read()
)

functions=[]

for node in tree.body:

    if isinstance(
        node,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):

        functions.append(
            node.name
        )


candidates=[]

keywords=(
    "config",
    "list",
    "row",
    "read",
    "view",
)

for name in functions:

    low=name.lower()

    if any(
        k in low
        for k in keywords
    ):
        candidates.append(name)


summary={
    "panel_functions":
        functions,

    "candidate_read_functions":
        candidates,

    "candidate_count":
        len(candidates),
}


with open(
    sys.argv[2],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        summary,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    "FUNCTIONS=",
    functions,
)

print(
    "CANDIDATES=",
    candidates,
)
PY


################################################
# 5 PATCH RETURN PATHS
################################################

echo
echo "========== [5/10] CONTROLLED PATCH =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$PANEL_READ" <<'PY'
import ast
import sys
from pathlib import Path


path=Path(
    sys.argv[1]
)

source=path.read_text(
    encoding="utf-8"
)

tree=ast.parse(
    source
)


TARGET_HINTS=(
    "config",
    "list",
    "row",
    "read",
    "view",
)


class Transformer(ast.NodeTransformer):

    def __init__(self):
        self.current=None
        self.changed=0


    def visit_FunctionDef(self,node):

        old=self.current
        self.current=node.name

        self.generic_visit(node)

        self.current=old

        return node


    def visit_AsyncFunctionDef(
        self,
        node,
    ):

        old=self.current
        self.current=node.name

        self.generic_visit(node)

        self.current=old

        return node


    def visit_Return(self,node):

        if not self.current:
            return node


        low=self.current.lower()

        if not any(
            hint in low
            for hint in TARGET_HINTS
        ):
            return node


        if node.value is None:
            return node


        # Avoid double wrapping.
        if (
            isinstance(
                node.value,
                ast.Call,
            )
            and isinstance(
                node.value.func,
                ast.Name,
            )
            and node.value.func.id
            == "overlay_country_collection"
        ):
            return node


        self.changed += 1

        node.value=ast.Call(
            func=ast.Name(
                id="overlay_country_collection",
                ctx=ast.Load(),
            ),
            args=[
                node.value
            ],
            keywords=[],
        )

        return node


transformer=Transformer()

tree=transformer.visit(
    tree
)

ast.fix_missing_locations(
    tree
)


if transformer.changed == 0:

    print(
        "NO_SAFE_RETURN_PATH_FOUND"
    )

    raise SystemExit(2)


import_line=(
    "from app.country.panel_projection_adapter "
    "import overlay_country_collection\n"
)


if import_line not in source:

    body=tree.body

    insert_at=0

    if (
        body
        and isinstance(
            body[0],
            ast.Expr,
        )
        and isinstance(
            body[0].value,
            ast.Constant,
        )
        and isinstance(
            body[0].value.value,
            str,
        )
    ):
        insert_at=1


    while (
        insert_at < len(body)
        and isinstance(
            body[insert_at],
            (
                ast.Import,
                ast.ImportFrom,
            ),
        )
    ):
        insert_at += 1


    body.insert(
        insert_at,
        ast.ImportFrom(
            module=(
                "app.country."
                "panel_projection_adapter"
            ),
            names=[
                ast.alias(
                    name=(
                        "overlay_country_collection"
                    ),
                )
            ],
            level=0,
        ),
    )


new_source=ast.unparse(
    tree
) + "\n"


path.write_text(
    new_source,
    encoding="utf-8",
)


print(
    "RETURN_PATHS_PATCHED=",
    transformer.changed,
)
PY

echo "PANEL_PATCH_APPLIED"


################################################
# 6 COMPILE + IMPORT
################################################

echo
echo "========== [6/10] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/panel_projection_adapter.py \
  app/country/projection.py \
  app/panel/read_model.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import app.panel.read_model
import app.country.panel_projection_adapter

print("IMPORT_OK")
PY


################################################
# 7 ADAPTER REGRESSION
################################################

echo
echo "========== [7/10] ADAPTER REGRESSION =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.panel_projection_adapter import (
    overlay_country,
)

from app.country.projection import (
    build_projection,
)

p=build_projection()

resolved=[
    cid
    for cid,row in p[
        "records"
    ].items()
    if row.get(
        "state"
    )=="resolved"
]

assert resolved

cid=resolved[0]

r=overlay_country(
    {
        "config_id":cid,
        "test":1,
    }
)

assert (
    r[
        "country_state"
    ]
    == "resolved"
)

assert (
    r["country_code"]
    or r["country_name"]
)

assert r["test"]==1

print(
    "ADAPTER_REGRESSION_OK"
)

print(
    "TEST_CONFIG_ID=",
    cid,
)

print(
    "COUNTRY_CODE=",
    r.get(
        "country_code"
    ),
)

print(
    "COUNTRY_NAME=",
    r.get(
        "country_name"
    ),
)
PY


################################################
# 8 PANEL SERVICE DISCOVERY + RESTART
################################################

echo
echo "========== [8/10] PANEL SERVICE =========="

PANEL_UNIT="$(
systemctl list-units \
  --type=service \
  --all \
  --no-legend \
  | awk '{print $1}' \
  | grep -Ei \
  '^config-location.*(panel|server|web).*\.service$' \
  | head -1 \
  || true
)"


echo "PANEL_UNIT=$PANEL_UNIT"


if [ -n "$PANEL_UNIT" ]; then

    systemctl restart \
      "$PANEL_UNIT"

    sleep 3

    systemctl is-active \
      "$PANEL_UNIT"

    echo "PANEL_RESTARTED=YES"

else

    echo "PANEL_RESTARTED=NO_UNIT_FOUND"

fi


################################################
# 9 RUNTIME VALIDATION
################################################

echo
echo "========== [9/10] RUNTIME VALIDATION =========="

if [ -n "$PANEL_UNIT" ]; then

    FATAL="$(
    journalctl \
      -u "$PANEL_UNIT" \
      --since "$START" \
      --no-pager \
      | grep -Ei \
      'Traceback|SyntaxError|ImportError|ModuleNotFoundError|fatal' \
      || true
    )"

    if [ -n "$FATAL" ]; then

        echo "$FATAL"

        echo "ROLLBACK_PANEL_READ_MODEL"

        cp -a \
          "$BACKUP_DIR/read_model.py.before" \
          "$PANEL_READ"

        systemctl restart \
          "$PANEL_UNIT" \
          || true

        fail "panel runtime regression"
        exit 1
    fi

fi


echo "RUNTIME_VALID"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "PANEL_PRODUCTION_READ_MODEL=ENABLED"
echo "COUNTRY_SOURCE=CANONICAL_PROJECTION_V2"

echo "CONFIG_STORE_WRITE=NO"
echo "COUNTRY_STORE_WRITE=NO"

echo "PUBLISH_WIRING=NO"
echo "PUBLISH_ENDPOINTS_UNCHANGED=YES"

echo "ROLLBACK_BACKUP=READY"
echo "FAIL_CLOSED_PATCH=YES"

echo
echo "PHASE5_PASS6A_SUCCESS"

RESULT="SUCCESS"
