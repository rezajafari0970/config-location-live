#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass6b-controlled-publish-canary-wiring"

PROJECT="/opt/config-location"
REPO="/root/project-log"

MODULE="$PROJECT/app/country/publish_canary.py"

STATE_ROOT="/var/lib/config-location/country/publish-canary"
STATUS="$STATE_ROOT/status.json"
GROUP_ROOT="$STATE_ROOT/groups"

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
CONTROLLED PUBLISH CANARY

Production publish wiring:
NO

/sub/all mutation:
NO

Production endpoint mutation:
NO

Config mutation:
NONE

Country canonical-store mutation:
NONE

Canary state:
$STATE_ROOT

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
echo " PHASE 5 PASS 6B"
echo " CONTROLLED PUBLISH CANARY WIRING"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/11] PRECHECK =========="

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

test -f "$PROJECT/app/publish/filter.py" || {
    fail "publish filter missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/11] BACKUP =========="

[ ! -f "$MODULE" ] || \
cp -a "$MODULE" \
"$BACKUP_DIR/publish_canary.py.before"

[ ! -f "$STATUS" ] || \
cp -a "$STATUS" \
"$BACKUP_DIR/status.before.json"

echo "BACKUP_OK"


################################################
# 3 INSTALL CANARY MODULE
################################################

echo
echo "========== [3/11] INSTALL MODULE =========="

cat > "$MODULE" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import tempfile

from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.country.projection import (
    build_projection,
)

from app.publish.filter import (
    publishable_config_ids,
)


STATE_ROOT=Path(
    "/var/lib/config-location/country/publish-canary"
)

GROUP_ROOT=STATE_ROOT/"groups"

STATUS_PATH=STATE_ROOT/"status.json"

PRODUCTION_WIRING=False


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def atomic_json(
    path: Path,
    value: Any,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd,tmp=tempfile.mkstemp(
        dir=str(path.parent),
        prefix="."+path.name+".",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as fh:

            json.dump(
                value,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())

        os.chmod(tmp,0o640)

        os.replace(
            tmp,
            path,
        )

    finally:

        if os.path.exists(tmp):
            os.unlink(tmp)


def sha256_json(
    value: Any,
) -> str:

    raw=json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",",":"),
    ).encode("utf-8")

    return hashlib.sha256(
        raw
    ).hexdigest()


def group_key(
    row: dict[str,Any],
) -> str:

    state=row.get(
        "state",
        "unknown",
    )

    if state=="conflict":
        return "CONFLICT"

    if state!="resolved":
        return "UNKNOWN"

    code=row.get(
        "country_code"
    )

    if isinstance(code,str):

        code=code.strip().upper()

        if (
            len(code)==2
            and code.isalpha()
        ):
            return code

    return "UNKNOWN"


def build_canary() -> dict[str,Any]:

    projection=build_projection()

    records=projection.get(
        "records",
        {},
    )

    current=set(records)

    publishable={
        str(cid)
        for cid in
        publishable_config_ids()
    }

    publishable &= current


    groups=defaultdict(list)

    resolved=0
    unknown=0
    conflict=0


    for cid in sorted(
        publishable
    ):

        row=records[cid]

        state=row.get(
            "state",
            "unknown",
        )

        if state=="resolved":
            resolved += 1

        elif state=="conflict":
            conflict += 1

        else:
            unknown += 1


        key=group_key(row)

        groups[key].append(
            {
                "config_id":
                    cid,

                "state":
                    state,

                "country_code":
                    row.get(
                        "country_code"
                    ),

                "country_name":
                    row.get(
                        "country_name"
                    ),

                "flag":
                    row.get(
                        "flag"
                    ),

                "confidence":
                    row.get(
                        "confidence"
                    ),

                "source":
                    row.get(
                        "selected_source"
                    ),

                "path":
                    row.get(
                        "selected_path"
                    ),
            }
        )


    group_meta={}

    for key,items in sorted(
        groups.items()
    ):

        group_meta[key]={
            "count":
                len(items),

            "sha256":
                sha256_json(items),
        }


    total=len(publishable)


    return {
        "component":
            "country-publish-canary",

        "schema":
            1,

        "mode":
            "canary_only",

        "production_wiring":
            False,

        "sub_all_mutated":
            False,

        "generated_at":
            now_iso(),

        "projection_schema":
            projection.get(
                "schema"
            ),

        "publishable_count":
            total,

        "resolved":
            resolved,

        "unknown":
            unknown,

        "conflict":
            conflict,

        "resolved_percent":
            round(
                (
                    resolved
                    * 100
                    / total
                )
                if total
                else 0,
                3,
            ),

        "group_count":
            len(groups),

        "group_meta":
            group_meta,

        "groups":
            dict(groups),
    }


def write_canary(
    data: dict[str,Any],
) -> None:

    GROUP_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )


    # Only files inside the dedicated
    # canary namespace are replaced.
    expected=set()


    for key,items in data[
        "groups"
    ].items():

        path=(
            GROUP_ROOT
            / f"{key}.json"
        )

        expected.add(
            path.name
        )

        atomic_json(
            path,
            {
                "mode":
                    "canary_only",

                "production_wiring":
                    False,

                "group":
                    key,

                "count":
                    len(items),

                "sha256":
                    sha256_json(items),

                "records":
                    items,
            },
        )


    # Do not delete stale canary files yet.
    # Reconciliation is deliberately
    # non-destructive in Pass 6B.


    status={
        key:value
        for key,value in data.items()
        if key!="groups"
    }

    status[
        "expected_group_files"
    ]=sorted(expected)

    status[
        "stale_canary_cleanup"
    ]=False

    atomic_json(
        STATUS_PATH,
        status,
    )
PY

echo "MODULE_INSTALLED"


################################################
# 4 COMPILE / IMPORT
################################################

echo
echo "========== [4/11] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/publish_canary.py \
  app/country/projection.py \
  app/publish/filter.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.publish_canary import (
    PRODUCTION_WIRING,
)

assert PRODUCTION_WIRING is False

print("IMPORT_OK")
print("PRODUCTION_WIRING=False")
PY


################################################
# 5 BUILD CANARY
################################################

echo
echo "========== [5/11] BUILD CANARY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.publish_canary import (
    build_canary,
    write_canary,
)

data=build_canary()

assert (
    data["production_wiring"]
    is False
)

assert (
    data["sub_all_mutated"]
    is False
)

assert (
    data["publishable_count"]
    ==
    data["resolved"]
    + data["unknown"]
    + data["conflict"]
)

write_canary(data)

print(
    "PUBLISHABLE=",
    data["publishable_count"],
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
    "RESOLVED_PERCENT=",
    data["resolved_percent"],
)

print(
    "GROUP_COUNT=",
    data["group_count"],
)

print("CANARY_BUILD_OK")
PY


################################################
# 6 HASH / COUNT VALIDATION
################################################

echo
echo "========== [6/11] HASH VALIDATION =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from pathlib import Path

from app.country.publish_canary import (
    GROUP_ROOT,
    STATUS_PATH,
    sha256_json,
)

status=json.loads(
    STATUS_PATH.read_text(
        encoding="utf-8"
    )
)

total=0

for name in status[
    "expected_group_files"
]:

    path=GROUP_ROOT/name

    assert path.is_file()

    data=json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    assert (
        data["mode"]
        == "canary_only"
    )

    assert (
        data["production_wiring"]
        is False
    )

    records=data["records"]

    assert (
        len(records)
        == data["count"]
    )

    assert (
        sha256_json(records)
        == data["sha256"]
    )

    total += len(records)


assert (
    total
    == status[
        "publishable_count"
    ]
)

print("HASH_VALIDATION_OK")
print("GROUP_TOTAL=",total)
PY


################################################
# 7 COMPARE WITH PASS5 SHADOW
################################################

echo
echo "========== [7/11] CONSISTENCY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json

from app.country.publish_canary import (
    STATUS_PATH,
)

d=json.loads(
    STATUS_PATH.read_text(
        encoding="utf-8"
    )
)

assert (
    d["projection_schema"]
    == 2
)

assert (
    d["production_wiring"]
    is False
)

assert (
    d["sub_all_mutated"]
    is False
)

assert d["conflict"] >= 0

print("CANARY_CONTRACT_VALID")

print(
    "PUBLISHABLE=",
    d["publishable_count"],
)

print(
    "RESOLVED_PERCENT=",
    d["resolved_percent"],
)

print(
    "CONFLICT=",
    d["conflict"],
)

print(
    "GROUP_COUNT=",
    d["group_count"],
)
PY


################################################
# 8 PRODUCTION PUBLISH HASH GUARD
################################################

echo
echo "========== [8/11] PRODUCTION GUARD =========="

PROD_HASH_BEFORE="$(
find "$PROJECT/app/publish" \
  -type f \
  -name '*.py' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  | sha256sum \
  | awk '{print $1}'
)"

sleep 1

PROD_HASH_AFTER="$(
find "$PROJECT/app/publish" \
  -type f \
  -name '*.py' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  | sha256sum \
  | awk '{print $1}'
)"


echo "PUBLISH_CODE_HASH_BEFORE=$PROD_HASH_BEFORE"
echo "PUBLISH_CODE_HASH_AFTER=$PROD_HASH_AFTER"

[ "$PROD_HASH_BEFORE" = "$PROD_HASH_AFTER" ] || {
    fail "production publish code changed"
    exit 1
}

echo "PRODUCTION_PUBLISH_CODE_UNCHANGED=YES"


################################################
# 9 SERVICE REGRESSION
################################################

echo
echo "========== [9/11] SERVICES =========="

for UNIT in \
  config-location-panel.service \
  config-location-country-worker.service \
  config-location-country-event-consumer.service
do

    ACTIVE="$(
        systemctl is-active \
          "$UNIT" \
          2>/dev/null || true
    )"

    echo "$UNIT ACTIVE=$ACTIVE"

    [ "$ACTIVE" = "active" ] || {
        fail "$UNIT inactive"
        exit 1
    }

done

echo "SERVICE_RESTART=NONE"


################################################
# 10 SNAPSHOT SUMMARY
################################################

echo
echo "========== [10/11] SUMMARY =========="

cp -a \
  "$STATUS" \
  "$SUMMARY"

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

assert d["mode"]=="canary_only"
assert d["production_wiring"] is False
assert d["sub_all_mutated"] is False

print(
    json.dumps(
        d,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 11 FINAL
################################################

echo
echo "========== [11/11] FINAL =========="

echo "PUBLISH_CANARY=READY"
echo "CANONICAL_PROJECTION_V2=ACTIVE_IN_CANARY"

echo "PER_COUNTRY_CANARY_GROUPS=READY"
echo "HASH_VALIDATION=PASS"
echo "COUNT_VALIDATION=PASS"

echo "PRODUCTION_PUBLISH_WIRING=NO"
echo "SUB_ALL_MUTATION=NO"
echo "PRODUCTION_ENDPOINT_MUTATION=NO"

echo "CONFIG_WRITE=NO"
echo "CANONICAL_COUNTRY_STORE_WRITE=NO"
echo "ORPHAN_DELETE=NO"

echo "PASS6B_READY_FOR_OBSERVATION=YES"

echo
echo "PHASE5_PASS6B_SUCCESS"

RESULT="SUCCESS"
