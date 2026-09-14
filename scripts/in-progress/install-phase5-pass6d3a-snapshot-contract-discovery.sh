#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass6d3a-exact-build-publish-snapshot-runtime-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
DISCOVERY="$DISCOVERY_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR"

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
READ ONLY RUNTIME CONTRACT DISCOVERY

Production mutation:
NONE

Publish mutation:
NONE

Endpoint mutation:
NONE

Service restart:
NONE

Discovery:
$DISCOVERY

Summary:
$SUMMARY

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
      "$DISCOVERY" \
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
echo " PHASE 5 PASS 6D.3A"
echo " EXACT build_publish_snapshot() CONTRACT"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/8] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f "$PROJECT/app/publish/filter.py" || {
    fail "publish filter missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 COMPILE
################################################

echo
echo "========== [2/8] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/publish/filter.py

echo "COMPILE_OK"


################################################
# 3 SOURCE CAPTURE
################################################

echo
echo "========== [3/8] SOURCE CAPTURE =========="

{
echo "================================================"
echo " PHASE 5 PASS 6D.3A"
echo " build_publish_snapshot() SOURCE"
echo "================================================"

echo "TIME=$(date -Is)"

echo
echo "========== filter.py =========="

nl -ba \
  "$PROJECT/app/publish/filter.py" \
  | sed -n '1,1400p'

echo
echo "========== REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'build_publish_snapshot\(|publish_snapshot|publishable_ids|publishable_records|snapshot\[' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 2400 || true

echo
echo "READ_ONLY=true"
echo "PRODUCTION_MUTATION=false"
echo "PUBLISH_MUTATION=false"
echo "ENDPOINT_MUTATION=false"
echo "SERVICE_RESTART=false"

echo "PHASE5_PASS6D3A_DISCOVERY_COMPLETE"

} > "$DISCOVERY"


################################################
# 4 RUNTIME TYPE INTROSPECTION
################################################

echo
echo "========== [4/8] RUNTIME INTROSPECTION =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import dataclasses
import inspect
import json
import sys
from collections.abc import Mapping, Sequence

from app.publish.filter import (
    build_publish_snapshot,
)


def safe_type_name(value):
    t=type(value)
    return f"{t.__module__}.{t.__qualname__}"


def preview_scalar(value):
    if isinstance(
        value,
        (str,int,float,bool,type(None)),
    ):
        s=repr(value)
        return s[:300]

    return None


def describe(value, depth=0):

    out={
        "type": safe_type_name(value),
    }

    if depth > 3:
        return out

    scalar=preview_scalar(value)

    if scalar is not None:
        out["value"]=scalar
        return out


    if dataclasses.is_dataclass(value):

        out["dataclass"]=True

        fields={}

        for field in dataclasses.fields(value):

            try:
                item=getattr(
                    value,
                    field.name,
                )
            except Exception as exc:
                fields[field.name]={
                    "error":repr(exc),
                }
                continue

            fields[field.name]=describe(
                item,
                depth+1,
            )

        out["fields"]=fields
        return out


    if isinstance(value,Mapping):

        out["mapping"]=True

        keys=[
            str(k)
            for k in list(
                value.keys()
            )[:200]
        ]

        out["keys"]=keys

        items={}

        for k in list(value.keys())[:80]:

            try:
                items[str(k)]=describe(
                    value[k],
                    depth+1,
                )
            except Exception as exc:
                items[str(k)]={
                    "error":repr(exc),
                }

        out["items"]=items

        try:
            out["length"]=len(value)
        except Exception:
            pass

        return out


    if (
        isinstance(value,Sequence)
        and not isinstance(
            value,
            (str,bytes,bytearray),
        )
    ):

        out["sequence"]=True

        try:
            out["length"]=len(value)
        except Exception:
            pass

        samples=[]

        for item in list(value)[:10]:
            samples.append(
                describe(
                    item,
                    depth+1,
                )
            )

        out["samples"]=samples
        return out


    attrs={}

    for name in dir(value):

        if name.startswith("_"):
            continue

        try:
            attr=getattr(
                value,
                name,
            )
        except Exception:
            continue

        if callable(attr):
            continue

        attrs[name]=describe(
            attr,
            depth+1,
        )

        if len(attrs) >= 80:
            break

    if attrs:
        out["attributes"]=attrs

    return out


snapshot=build_publish_snapshot()

summary={
    "phase":
        "phase5-pass6d3a-exact-build-publish-snapshot-runtime-contract",

    "read_only":
        True,

    "snapshot_type":
        safe_type_name(snapshot),

    "snapshot_is_dict":
        isinstance(snapshot,dict),

    "snapshot_is_mapping":
        isinstance(snapshot,Mapping),

    "snapshot_is_sequence":
        (
            isinstance(snapshot,Sequence)
            and not isinstance(
                snapshot,
                (str,bytes,bytearray),
            )
        ),

    "snapshot_is_dataclass":
        dataclasses.is_dataclass(
            snapshot
        ),

    "description":
        describe(snapshot),

    "production_mutation":
        False,

    "service_restart":
        False,
}


with open(
    sys.argv[1],
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
    "SNAPSHOT_TYPE=",
    summary[
        "snapshot_type"
    ],
)

print(
    "SNAPSHOT_IS_DICT=",
    summary[
        "snapshot_is_dict"
    ],
)

print(
    "SNAPSHOT_IS_MAPPING=",
    summary[
        "snapshot_is_mapping"
    ],
)

print(
    "SNAPSHOT_IS_SEQUENCE=",
    summary[
        "snapshot_is_sequence"
    ],
)

print(
    "SNAPSHOT_IS_DATACLASS=",
    summary[
        "snapshot_is_dataclass"
    ],
)

print("RUNTIME_INTROSPECTION_OK")
PY


################################################
# 5 SEMANTIC FIELD DISCOVERY
################################################

echo
echo "========== [5/8] SEMANTIC FIELD DISCOVERY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import dataclasses
from collections.abc import Mapping, Sequence

from app.publish.filter import (
    build_publish_snapshot,
)


snapshot=build_publish_snapshot()


def walk(
    value,
    path="$",
    depth=0,
):

    if depth > 6:
        return

    if dataclasses.is_dataclass(value):

        for field in dataclasses.fields(value):

            try:
                item=getattr(
                    value,
                    field.name,
                )
            except Exception:
                continue

            p=(
                path
                + "."
                + field.name
            )

            yield p,item

            yield from walk(
                item,
                p,
                depth+1,
            )

        return


    if isinstance(value,Mapping):

        for key,item in value.items():

            p=(
                path
                + "."
                + str(key)
            )

            yield p,item

            yield from walk(
                item,
                p,
                depth+1,
            )

        return


    if (
        isinstance(value,Sequence)
        and not isinstance(
            value,
            (str,bytes,bytearray),
        )
    ):

        for i,item in enumerate(
            list(value)[:50]
        ):

            p=(
                path
                + f"[{i}]"
            )

            yield p,item

            yield from walk(
                item,
                p,
                depth+1,
            )


interesting=[]

for path,value in walk(snapshot):

    low=path.lower()

    if any(
        term in low
        for term in (
            "publish",
            "record",
            "config",
            "raw",
            "id",
            "eligible",
            "suppressed",
            "healthy",
            "recovered",
        )
    ):

        kind=type(value).__name__

        length=None

        try:
            length=len(value)
        except Exception:
            pass

        interesting.append(
            (
                path,
                kind,
                length,
            )
        )


for row in interesting[:500]:

    print(
        "PATH=",
        row[0],
        "TYPE=",
        row[1],
        "LEN=",
        row[2],
    )

print(
    "SEMANTIC_PATH_COUNT=",
    len(interesting),
)

print("SEMANTIC_DISCOVERY_OK")
PY


################################################
# 6 EXACT SERIALIZATION COMPATIBILITY
################################################

echo
echo "========== [6/8] SERIALIZATION CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import inspect

from app.publish import http


print(
    "_subscription_text_signature=",
    inspect.signature(
        http._subscription_text
    ),
)

source=inspect.getsource(
    http._subscription_text
)

print(
    "========== _subscription_text SOURCE =========="
)

print(source)

print(
    "SERIALIZER_SOURCE_CAPTURED=YES"
)
PY


################################################
# 7 VALIDATION
################################################

echo
echo "========== [7/8] VALIDATE =========="

test -s "$SUMMARY" || {
    fail "summary missing"
    exit 1
}

test -s "$DISCOVERY" || {
    fail "discovery missing"
    exit 1
}

grep -q \
  'PHASE5_PASS6D3A_DISCOVERY_COMPLETE' \
  "$DISCOVERY" || {
    fail "discovery incomplete"
    exit 1
}

"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert d["read_only"] is True
assert d["production_mutation"] is False
assert d["service_restart"] is False

assert isinstance(
    d["snapshot_type"],
    str,
)

assert d["snapshot_type"]

print("SUMMARY_CONTRACT_VALID")
PY

echo "DISCOVERY_VALID"


################################################
# 8 FINAL
################################################

echo
echo "========== [8/8] FINAL =========="

echo "SNAPSHOT_RUNTIME_TYPE_DISCOVERED=YES"
echo "SNAPSHOT_STRUCTURE_DISCOVERED=YES"
echo "SEMANTIC_FIELDS_DISCOVERED=YES"
echo "SERIALIZER_CONTRACT_CAPTURED=YES"

echo "PRODUCTION_MUTATION=NO"
echo "PUBLISH_MUTATION=NO"
echo "ENDPOINT_MUTATION=NO"
echo "SERVICE_RESTART=NO"

echo
echo "PHASE5_PASS6D3A_SUCCESS"

RESULT="SUCCESS"
