#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass2-canonical-country-projection-orphan-reconciliation-design"

PROJECT="/opt/config-location"
REPO="/root/project-log"

MODULE="$PROJECT/app/country/projection.py"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
PROJECTION="$DISCOVERY_DIR/${PHASE}-${TS}.json"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}-summary.json"

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
SHADOW CANONICAL COUNTRY PROJECTION

Config mutation:
NONE

Country-store mutation:
NONE

Orphan deletion:
NONE

Panel mutation:
NONE

Publish mutation:
NONE

Service restart:
NONE

Projection:
$PROJECTION

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
      "$PROJECTION" \
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
echo " PHASE 5 PASS 2"
echo " CANONICAL COUNTRY PROJECTION"
echo " ORPHAN / RECONCILIATION DESIGN"
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

test -d /var/lib/config-location/configs || {
    fail "config store missing"
    exit 1
}

test -d /var/lib/config-location/country || {
    fail "country store missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/10] BACKUP =========="

if [ -f "$MODULE" ]; then
    cp -a \
      "$MODULE" \
      "$BACKUP_DIR/projection.py.before"
fi

echo "BACKUP_OK"


################################################
# 3 INSTALL SHADOW PROJECTION MODULE
################################################

echo
echo "========== [3/10] INSTALL PROJECTION MODULE =========="

cat > "$MODULE" <<'PY'
from __future__ import annotations

import json

from dataclasses import (
    asdict,
    dataclass,
)

from pathlib import Path
from typing import Any


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

COUNTRY_ROOT = Path(
    "/var/lib/config-location/country"
)

RESULT_ROOT = (
    COUNTRY_ROOT / "results"
)

IDENTITY_ROOT = (
    COUNTRY_ROOT / "country-identity"
)

PIPELINE_ROOT = (
    COUNTRY_ROOT / "pipeline" / "latest"
)


UNKNOWN_VALUES = {
    "",
    "unknown",
    "UNKNOWN",
    "Unknown",
    "ناشناس",
    "none",
    "None",
    "null",
    "--",
}


@dataclass
class CountryEvidence:
    source: str
    config_id: str
    country_code: str | None
    country_name: str | None
    flag: str | None
    confidence: float | None
    state: str | None
    locked: bool
    accepted: bool
    reason: str


@dataclass
class CountryProjection:
    config_id: str
    state: str
    country_code: str | None
    country_name: str | None
    flag: str | None
    confidence: float | None
    selected_source: str | None
    conflict: bool
    evidence_count: int
    evidence: list[dict[str, Any]]


def read_json(
    path: Path,
) -> Any:

    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return None


def clean(
    value: Any,
) -> str | None:

    if value is None:
        return None

    value=str(value).strip()

    if value in UNKNOWN_VALUES:
        return None

    return value or None


def code_of(
    obj: dict[str,Any],
) -> str | None:

    value=clean(
        obj.get(
            "country_code"
        )
    )

    if value:
        return value.upper()

    country=clean(
        obj.get("country")
    )

    if (
        country
        and len(country)==2
        and country.isalpha()
    ):
        return country.upper()

    return None


def name_of(
    obj: dict[str,Any],
) -> str | None:

    value=clean(
        obj.get(
            "country_name"
        )
    )

    if value:
        return value

    country=clean(
        obj.get("country")
    )

    if (
        country
        and not (
            len(country)==2
            and country.isalpha()
        )
    ):
        return country

    return None


def confidence_of(
    obj: dict[str,Any],
) -> float | None:

    for key in (
        "country_confidence",
        "confidence",
    ):

        if key not in obj:
            continue

        try:
            value=float(
                obj[key]
            )

            if value > 1:
                value=value / 100.0

            return max(
                0.0,
                min(
                    1.0,
                    value,
                ),
            )

        except Exception:
            continue

    return None


def state_of(
    obj: dict[str,Any],
) -> str | None:

    for key in (
        "state",
        "country_state",
        "status",
        "verdict",
    ):

        value=clean(
            obj.get(key)
        )

        if value:
            return value.lower()

    return None


def is_locked_identity(
    obj: dict[str,Any],
) -> bool:

    return bool(
        obj.get(
            "country_identity_locked",
            False,
        )
        or obj.get(
            "locked",
            False,
        )
        or obj.get(
            "country_detection_once",
            False,
        )
        or str(
            obj.get(
                "country_identity_guard",
                "",
            )
        ).lower()
        in {
            "locked",
            "true",
            "1",
        }
    )


def accepted_state(
    source: str,
    state: str | None,
    locked: bool,
) -> bool:

    if source=="identity":
        return locked

    if state is None:
        return True

    return state in {
        "confirmed",
        "resolved",
        "healthy",
        "success",
        "accepted",
        "final",
        "stable",
        "known",
    }


def make_evidence(
    source: str,
    config_id: str,
    obj: dict[str,Any],
) -> CountryEvidence:

    code=code_of(obj)
    name=name_of(obj)

    locked=(
        is_locked_identity(obj)
        if source=="identity"
        else False
    )

    state=state_of(obj)

    has_country=bool(
        code or name
    )

    accepted=(
        has_country
        and accepted_state(
            source,
            state,
            locked,
        )
    )

    if not has_country:
        reason="missing_country"

    elif source=="identity" and not locked:
        reason="identity_not_locked"

    elif not accepted:
        reason=(
            "state_not_accepted:"
            + str(state)
        )

    else:
        reason="accepted"


    return CountryEvidence(
        source=source,
        config_id=config_id,
        country_code=code,
        country_name=name,
        flag=clean(
            obj.get("flag")
        ),
        confidence=confidence_of(
            obj
        ),
        state=state,
        locked=locked,
        accepted=accepted,
        reason=reason,
    )


def candidate_paths(
    root: Path,
    config_id: str,
) -> list[Path]:

    direct=(
        root
        / f"{config_id}.json"
    )

    if direct.is_file():
        return [direct]

    return []


def load_evidence(
    config_id: str,
) -> list[CountryEvidence]:

    sources=[
        (
            "identity",
            IDENTITY_ROOT,
        ),
        (
            "results",
            RESULT_ROOT,
        ),
        (
            "pipeline_latest",
            PIPELINE_ROOT,
        ),
    ]

    out=[]

    for source,root in sources:

        for path in candidate_paths(
            root,
            config_id,
        ):

            obj=read_json(
                path
            )

            if not isinstance(
                obj,
                dict,
            ):
                continue

            out.append(
                make_evidence(
                    source,
                    config_id,
                    obj,
                )
            )

    return out


def evidence_key(
    row: CountryEvidence,
) -> str | None:

    if row.country_code:
        return (
            "code:"
            + row.country_code.upper()
        )

    if row.country_name:
        return (
            "name:"
            + row.country_name
            .strip()
            .casefold()
        )

    return None


def choose_projection(
    config_id: str,
    evidence: list[CountryEvidence],
) -> CountryProjection:

    accepted=[
        row
        for row in evidence
        if row.accepted
    ]

    keys={
        evidence_key(row)
        for row in accepted
        if evidence_key(row)
    }


    # Fail closed on conflicting accepted
    # evidence.
    if len(keys) > 1:

        return CountryProjection(
            config_id=config_id,
            state="conflict",
            country_code=None,
            country_name=None,
            flag=None,
            confidence=None,
            selected_source=None,
            conflict=True,
            evidence_count=len(evidence),
            evidence=[
                asdict(x)
                for x in evidence
            ],
        )


    priority={
        "identity":0,
        "results":1,
        "pipeline_latest":2,
    }


    accepted.sort(
        key=lambda row: (
            priority.get(
                row.source,
                99,
            ),
            -(
                row.confidence
                if row.confidence
                is not None
                else -1
            ),
        )
    )


    if not accepted:

        return CountryProjection(
            config_id=config_id,
            state="unknown",
            country_code=None,
            country_name=None,
            flag=None,
            confidence=None,
            selected_source=None,
            conflict=False,
            evidence_count=len(evidence),
            evidence=[
                asdict(x)
                for x in evidence
            ],
        )


    selected=accepted[0]


    return CountryProjection(
        config_id=config_id,
        state="resolved",
        country_code=selected.country_code,
        country_name=selected.country_name,
        flag=selected.flag,
        confidence=selected.confidence,
        selected_source=selected.source,
        conflict=False,
        evidence_count=len(evidence),
        evidence=[
            asdict(x)
            for x in evidence
        ],
    )


def current_config_ids() -> list[str]:

    ids=[]

    for path in CONFIG_ROOT.glob(
        "*.json"
    ):

        obj=read_json(
            path
        )

        if isinstance(
            obj,
            dict,
        ):

            cid=obj.get(
                "config_id",
                path.stem,
            )

        else:
            cid=path.stem

        ids.append(
            str(cid)
        )

    return sorted(
        set(ids)
    )


def build_projection() -> dict[str,Any]:

    records={}

    counts={
        "resolved":0,
        "unknown":0,
        "conflict":0,
    }

    source_counts={}

    for cid in current_config_ids():

        row=choose_projection(
            cid,
            load_evidence(cid),
        )

        records[cid]=asdict(
            row
        )

        counts[row.state]=(
            counts.get(
                row.state,
                0,
            )
            + 1
        )

        if row.selected_source:

            source_counts[
                row.selected_source
            ]=(
                source_counts.get(
                    row.selected_source,
                    0,
                )
                + 1
            )


    return {
        "schema":
            1,

        "mode":
            "shadow",

        "current_config_count":
            len(records),

        "counts":
            counts,

        "selected_source_counts":
            source_counts,

        "records":
            records,
    }


def store_ids(
    root: Path,
) -> set[str]:

    ids=set()

    if not root.exists():
        return ids

    for path in root.rglob(
        "*.json"
    ):

        obj=read_json(
            path
        )

        if isinstance(
            obj,
            dict,
        ):

            cid=(
                obj.get("config_id")
                or obj.get("id")
                or path.stem
            )

        else:
            cid=path.stem

        if cid:
            ids.add(
                str(cid)
            )

    return ids


def orphan_inventory() -> dict[str,Any]:

    current=set(
        current_config_ids()
    )

    result={}

    for name,root in (
        ("results",RESULT_ROOT),
        ("identity",IDENTITY_ROOT),
        (
            "pipeline_latest",
            PIPELINE_ROOT,
        ),
    ):

        ids=store_ids(root)

        orphan=(
            ids - current
        )

        result[name]={
            "record_count":
                len(ids),

            "current_overlap":
                len(
                    ids & current
                ),

            "orphan_count":
                len(orphan),

            "orphan_sample":
                sorted(orphan)[:100],

            "delete_allowed":
                False,
        }

    return result
PY

echo "MODULE_INSTALLED"


################################################
# 4 COMPILE
################################################

echo
echo "========== [4/10] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/projection.py

echo "COMPILE_OK"


################################################
# 5 SYNTHETIC SELFTEST
################################################

echo
echo "========== [5/10] SELFTEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.projection import (
    CountryEvidence,
    choose_projection,
)

identity=CountryEvidence(
    source="identity",
    config_id="x",
    country_code="DE",
    country_name="Germany",
    flag="🇩🇪",
    confidence=1.0,
    state="confirmed",
    locked=True,
    accepted=True,
    reason="accepted",
)

pipeline=CountryEvidence(
    source="pipeline_latest",
    config_id="x",
    country_code="DE",
    country_name="Germany",
    flag="🇩🇪",
    confidence=.8,
    state="resolved",
    locked=False,
    accepted=True,
    reason="accepted",
)

r=choose_projection(
    "x",
    [
        pipeline,
        identity,
    ],
)

assert r.state=="resolved"
assert r.selected_source=="identity"
assert r.country_code=="DE"


conflict=CountryEvidence(
    source="results",
    config_id="x",
    country_code="US",
    country_name="United States",
    flag="🇺🇸",
    confidence=.9,
    state="confirmed",
    locked=False,
    accepted=True,
    reason="accepted",
)

r=choose_projection(
    "x",
    [
        identity,
        conflict,
    ],
)

assert r.state=="conflict"
assert r.country_code is None

r=choose_projection(
    "x",
    [],
)

assert r.state=="unknown"

print("SELFTEST_OK")
print("IDENTITY_PRIORITY_OK")
print("CONFLICT_FAIL_CLOSED_OK")
print("UNKNOWN_FAIL_CLOSED_OK")
PY


################################################
# 6 BUILD LIVE SHADOW PROJECTION
################################################

echo
echo "========== [6/10] BUILD SHADOW PROJECTION =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$PROJECTION" <<'PY'
import json
import sys

from app.country.projection import (
    build_projection,
)

p=build_projection()

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        p,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")

print(
    "CURRENT_CONFIGS=",
    p["current_config_count"],
)

print(
    "RESOLVED=",
    p["counts"].get(
        "resolved",
        0,
    ),
)

print(
    "UNKNOWN=",
    p["counts"].get(
        "unknown",
        0,
    ),
)

print(
    "CONFLICT=",
    p["counts"].get(
        "conflict",
        0,
    ),
)

print(
    "SOURCE_COUNTS=",
    p["selected_source_counts"],
)
PY


################################################
# 7 ORPHAN INVENTORY
################################################

echo
echo "========== [7/10] ORPHAN INVENTORY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SUMMARY" "$PROJECTION" <<'PY'
import json
import sys

from app.country.projection import (
    orphan_inventory,
)

projection=json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)

orphans=orphan_inventory()

summary={
    "phase":
        "phase5-pass2-canonical-country-projection-orphan-reconciliation-design",

    "mode":
        "shadow",

    "current_config_count":
        projection[
            "current_config_count"
        ],

    "projection_counts":
        projection[
            "counts"
        ],

    "selected_source_counts":
        projection[
            "selected_source_counts"
        ],

    "orphan_inventory":
        orphans,

    "orphan_deletion":
        False,

    "config_mutation":
        False,

    "country_store_mutation":
        False,

    "panel_integration":
        False,

    "publish_integration":
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
    json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 8 VALIDATE CURRENT-ONLY
################################################

echo
echo "========== [8/10] VALIDATE CURRENT ONLY =========="

"$PROJECT/venv/bin/python" \
- "$PROJECTION" <<'PY'
import json
import sys
from pathlib import Path

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

config_root=Path(
    "/var/lib/config-location/configs"
)

disk_ids=set()

for path in config_root.glob(
    "*.json"
):

    try:
        obj=json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )

        cid=str(
            obj.get(
                "config_id",
                path.stem,
            )
        )

    except Exception:
        cid=path.stem

    disk_ids.add(cid)


projection_ids=set(
    d["records"]
)

assert (
    projection_ids
    == disk_ids
)

assert (
    d["current_config_count"]
    == len(disk_ids)
)

for cid,row in d[
    "records"
].items():

    assert row["state"] in {
        "resolved",
        "unknown",
        "conflict",
    }

    if row["state"]=="conflict":
        assert row["country_code"] is None
        assert row["selected_source"] is None


print("CURRENT_ONLY_OK")
print(
    "NO_ORPHAN_IN_PROJECTION=YES"
)
print(
    "CONFLICT_FAIL_CLOSED=YES"
)
PY


################################################
# 9 SERVICES / NO MUTATION
################################################

echo
echo "========== [9/10] SERVICES =========="

for UNIT in \
  config-location-country-worker.service \
  config-location-country-event-consumer.service
do

    echo "$UNIT"

    systemctl is-active \
      "$UNIT" \
      2>/dev/null || true

    systemctl is-enabled \
      "$UNIT" \
      2>/dev/null || true
done

echo "SERVICE_RESTART=NONE"
echo "CONFIG_MUTATION=NONE"
echo "COUNTRY_STORE_MUTATION=NONE"
echo "ORPHAN_DELETE=NONE"
echo "PANEL_MUTATION=NONE"
echo "PUBLISH_MUTATION=NONE"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

test -s "$PROJECTION" || {
    fail "projection missing"
    exit 1
}

test -s "$SUMMARY" || {
    fail "summary missing"
    exit 1
}

echo "CANONICAL_PROJECTION_DESIGN=READY"
echo "CURRENT_CONFIG_FILTER=READY"
echo "IDENTITY_PRIORITY=READY"
echo "RESULT_FALLBACK=READY"
echo "PIPELINE_FALLBACK=READY"
echo "CONFLICT_FAIL_CLOSED=READY"
echo "ORPHAN_INVENTORY=READY"

echo "ORPHAN_DELETE=NO"
echo "CONFIG_WRITE=NO"
echo "COUNTRY_STORE_WRITE=NO"
echo "PANEL_WIRING=NO"
echo "PUBLISH_WIRING=NO"

echo
echo "PHASE5_PASS2_SUCCESS"

RESULT="SUCCESS"
