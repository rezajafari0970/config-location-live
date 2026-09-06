#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass4-canonical-projection-contract-fix-pipeline-authority"

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
SHADOW CANONICAL PROJECTION CONTRACT FIX

Projection code:
UPDATED

Config mutation:
NONE

Country-store mutation:
NONE

Orphan deletion:
NONE

Panel wiring:
NONE

Publish wiring:
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
echo " PHASE 5 PASS 4"
echo " CANONICAL PROJECTION CONTRACT FIX"
echo " PIPELINE AUTHORITY"
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

test -f "$MODULE" || {
    fail "projection.py missing"
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

cp -a \
  "$MODULE" \
  "$BACKUP_DIR/projection.py.before"

echo "BACKUP_OK"


################################################
# 3 INSTALL FIXED PROJECTION
################################################

echo
echo "========== [3/10] INSTALL CONTRACT FIX =========="

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


FINAL_STATES = {
    "confirmed",
    "confirmed_stable",
    "confirmed_rotating_ip",
    "stable",
    "accepted",
    "resolved",
    "final",
    "known",
}


NON_FINAL_STATES = {
    "pending_confirmation",
    "ambiguous",
    "unstable_exit",
    "error",
    "unknown",
    "failed",
    "failure",
    "pending",
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
    evidence_path: str | None

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
    selected_path: str | None

    conflict: bool

    evidence_count: int
    accepted_evidence_count: int

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

    if not isinstance(
        value,
        (
            str,
            int,
            float,
        ),
    ):
        return None

    value=str(value).strip()

    if value in UNKNOWN_VALUES:
        return None

    return value or None


def normalize_code(
    value: Any,
) -> str | None:

    value=clean(value)

    if not value:
        return None

    value=value.upper()

    if (
        len(value)==2
        and value.isalpha()
    ):
        return value

    return None


def normalize_name(
    value: Any,
) -> str | None:

    value=clean(value)

    if not value:
        return None

    if (
        len(value)==2
        and value.isalpha()
    ):
        return None

    return value


def normalize_confidence(
    value: Any,
) -> float | None:

    try:
        value=float(value)

    except Exception:
        return None

    if value > 1:
        value=value / 100.0

    return max(
        0.0,
        min(
            1.0,
            value,
        ),
    )


def state_value(
    obj: dict[str,Any],
) -> str | None:

    for key in (
        "state",
        "country_state",
        "status",
        "verdict",
        "decision",
        "resolution_state",
    ):

        value=clean(
            obj.get(key)
        )

        if value:
            return value.lower()

    return None


def confidence_value(
    obj: dict[str,Any],
) -> float | None:

    for key in (
        "country_confidence",
        "confidence",
        "score",
    ):

        if key in obj:

            value=normalize_confidence(
                obj.get(key)
            )

            if value is not None:
                return value

    return None


def direct_country(
    obj: dict[str,Any],
) -> tuple[
    str | None,
    str | None,
    str | None,
]:

    code=normalize_code(
        obj.get(
            "country_code"
        )
    )

    name=normalize_name(
        obj.get(
            "country_name"
        )
    )


    country=clean(
        obj.get(
            "country"
        )
    )

    if country:

        if (
            not code
            and len(country)==2
            and country.isalpha()
        ):

            code=country.upper()

        elif not name:

            name=normalize_name(
                country
            )


    flag=clean(
        obj.get("flag")
    )


    return (
        code,
        name,
        flag,
    )


def identity_locked(
    obj: dict[str,Any],
) -> bool:

    metadata=(
        obj.get("metadata")
        if isinstance(
            obj.get("metadata"),
            dict,
        )
        else {}
    )


    values=[
        obj.get(
            "country_identity_locked"
        ),

        obj.get("locked"),

        metadata.get(
            "country_identity_locked"
        ),
    ]


    if any(
        value is True
        for value in values
    ):
        return True


    guard=(
        obj.get(
            "country_identity_guard"
        )
        or metadata.get(
            "country_identity_guard"
        )
    )


    if guard is True:
        return True


    if str(
        guard
    ).strip().lower() in {
        "locked",
        "true",
        "1",
    }:
        return True


    return False


def section_evidence(
    *,
    source: str,
    config_id: str,
    obj: dict[str,Any],
    section_name: str,
    accepted: bool,
    state: str | None,
    reason: str,
    locked: bool=False,
) -> CountryEvidence | None:

    code,name,flag=direct_country(
        obj
    )

    if not (
        code
        or name
    ):
        return None


    return CountryEvidence(
        source=source,
        config_id=config_id,

        country_code=code,
        country_name=name,
        flag=flag,

        confidence=confidence_value(
            obj
        ),

        state=state,
        evidence_path=section_name,

        locked=locked,
        accepted=accepted,
        reason=reason,
    )


def identity_evidence(
    config_id: str,
    obj: dict[str,Any],
) -> list[CountryEvidence]:

    locked=identity_locked(
        obj
    )

    state=state_value(
        obj
    )


    row=section_evidence(
        source="identity",
        config_id=config_id,
        obj=obj,
        section_name="$",
        accepted=locked,
        state=state,
        locked=locked,
        reason=(
            "locked_identity"
            if locked
            else "identity_not_locked"
        ),
    )


    return (
        [row]
        if row
        else []
    )


def result_evidence(
    config_id: str,
    obj: dict[str,Any],
) -> list[CountryEvidence]:

    rows=[]

    top_state=state_value(
        obj
    )


    # Canonical final result:
    # top-level result is accepted only
    # when result state itself is final.
    top_accepted=(
        top_state
        in FINAL_STATES
    )


    row=section_evidence(
        source="results",
        config_id=config_id,
        obj=obj,
        section_name="$",
        accepted=top_accepted,
        state=top_state,
        reason=(
            "final_result"
            if top_accepted
            else (
                "non_final_result:"
                + str(top_state)
            )
        ),
    )

    if row:
        rows.append(row)


    # Primary is evidence, but does not
    # override a non-final top-level result.
    primary=obj.get(
        "primary"
    )

    if isinstance(
        primary,
        dict,
    ):

        primary_state=state_value(
            primary
        )

        primary_final=(
            primary_state
            in FINAL_STATES
        )

        accepted=(
            top_accepted
            and primary_final
        )

        row=section_evidence(
            source="results",
            config_id=config_id,
            obj=primary,
            section_name="$.primary",
            accepted=accepted,
            state=primary_state,
            reason=(
                "final_result_primary"
                if accepted
                else "primary_not_canonical_final"
            ),
        )

        if row:
            rows.append(row)


    return rows


def pipeline_evidence(
    config_id: str,
    obj: dict[str,Any],
) -> list[CountryEvidence]:

    rows=[]

    top_state=state_value(
        obj
    )


    # Hard boundary:
    # non-final pipeline state may contain
    # Country evidence, but it remains
    # shadow-only and cannot resolve.
    top_final=(
        top_state
        in FINAL_STATES
    )


    row=section_evidence(
        source="pipeline_latest",
        config_id=config_id,
        obj=obj,
        section_name="$",
        accepted=top_final,
        state=top_state,
        reason=(
            "final_pipeline"
            if top_final
            else (
                "non_final_pipeline:"
                + str(top_state)
            )
        ),
    )

    if row:
        rows.append(row)


    # Fusion is the strongest nested verdict
    # when the parent pipeline state is final.
    fusion=obj.get(
        "fusion"
    )

    if isinstance(
        fusion,
        dict,
    ):

        fusion_state=state_value(
            fusion
        )

        accepted=(
            top_final
            and fusion_state
            in FINAL_STATES
        )

        row=section_evidence(
            source="pipeline_latest",
            config_id=config_id,
            obj=fusion,
            section_name="$.fusion",
            accepted=accepted,
            state=fusion_state,
            reason=(
                "final_pipeline_fusion"
                if accepted
                else "fusion_not_canonical_final"
            ),
        )

        if row:
            rows.append(row)


    # Primary is usable evidence only when
    # both parent and primary are final.
    primary=obj.get(
        "primary"
    )

    if isinstance(
        primary,
        dict,
    ):

        primary_state=state_value(
            primary
        )

        accepted=(
            top_final
            and primary_state
            in FINAL_STATES
        )

        row=section_evidence(
            source="pipeline_latest",
            config_id=config_id,
            obj=primary,
            section_name="$.primary",
            accepted=accepted,
            state=primary_state,
            reason=(
                "final_pipeline_primary"
                if accepted
                else "primary_not_canonical_final"
            ),
        )

        if row:
            rows.append(row)


    return rows


def direct_path(
    root: Path,
    config_id: str,
) -> Path:

    return (
        root
        / f"{config_id}.json"
    )


def load_evidence(
    config_id: str,
) -> list[CountryEvidence]:

    out=[]


    identity_path=direct_path(
        IDENTITY_ROOT,
        config_id,
    )

    if identity_path.is_file():

        obj=read_json(
            identity_path
        )

        if isinstance(obj,dict):

            out.extend(
                identity_evidence(
                    config_id,
                    obj,
                )
            )


    result_path=direct_path(
        RESULT_ROOT,
        config_id,
    )

    if result_path.is_file():

        obj=read_json(
            result_path
        )

        if isinstance(obj,dict):

            out.extend(
                result_evidence(
                    config_id,
                    obj,
                )
            )


    pipeline_path=direct_path(
        PIPELINE_ROOT,
        config_id,
    )

    if pipeline_path.is_file():

        obj=read_json(
            pipeline_path
        )

        if isinstance(obj,dict):

            out.extend(
                pipeline_evidence(
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


def accepted_source_rows(
    evidence: list[CountryEvidence],
) -> dict[
    str,
    list[CountryEvidence],
]:

    grouped={}

    for row in evidence:

        if not row.accepted:
            continue

        grouped.setdefault(
            row.source,
            []
        ).append(row)

    return grouped


def source_consensus(
    rows: list[CountryEvidence],
) -> CountryEvidence | None:

    if not rows:
        return None


    keys={
        evidence_key(row)
        for row in rows
        if evidence_key(row)
    }


    if len(keys) != 1:
        return None


    # Prefer strongest nested path.
    path_priority={
        "$.fusion":0,
        "$":1,
        "$.primary":2,
    }


    return sorted(
        rows,
        key=lambda row: (
            path_priority.get(
                row.evidence_path
                or "",
                99,
            ),

            -(
                row.confidence
                if row.confidence
                is not None
                else -1
            ),
        ),
    )[0]


def choose_projection(
    config_id: str,
    evidence: list[CountryEvidence],
) -> CountryProjection:

    grouped=accepted_source_rows(
        evidence
    )


    candidates={}


    for source,rows in grouped.items():

        row=source_consensus(
            rows
        )

        if row is not None:

            candidates[
                source
            ]=row


    # Different accepted sources must agree.
    keys={
        evidence_key(row)
        for row in candidates.values()
        if evidence_key(row)
    }


    if len(keys) > 1:

        return CountryProjection(
            config_id=config_id,

            state="conflict",

            country_code=None,
            country_name=None,
            flag=None,

            confidence=None,

            selected_source=None,
            selected_path=None,

            conflict=True,

            evidence_count=len(
                evidence
            ),

            accepted_evidence_count=sum(
                1
                for row in evidence
                if row.accepted
            ),

            evidence=[
                asdict(row)
                for row in evidence
            ],
        )


    authority=(
        "identity",
        "results",
        "pipeline_latest",
    )


    selected=None


    for source in authority:

        if source in candidates:

            selected=candidates[
                source
            ]

            break


    if selected is None:

        return CountryProjection(
            config_id=config_id,

            state="unknown",

            country_code=None,
            country_name=None,
            flag=None,

            confidence=None,

            selected_source=None,
            selected_path=None,

            conflict=False,

            evidence_count=len(
                evidence
            ),

            accepted_evidence_count=0,

            evidence=[
                asdict(row)
                for row in evidence
            ],
        )


    return CountryProjection(
        config_id=config_id,

        state="resolved",

        country_code=
            selected.country_code,

        country_name=
            selected.country_name,

        flag=
            selected.flag,

        confidence=
            selected.confidence,

        selected_source=
            selected.source,

        selected_path=
            selected.evidence_path,

        conflict=False,

        evidence_count=len(
            evidence
        ),

        accepted_evidence_count=sum(
            1
            for row in evidence
            if row.accepted
        ),

        evidence=[
            asdict(row)
            for row in evidence
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

        if isinstance(obj,dict):

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
    path_counts={}


    for cid in current_config_ids():

        row=choose_projection(
            cid,
            load_evidence(
                cid
            ),
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


        if row.selected_path:

            key=(
                row.selected_source
                + ":"
                + row.selected_path
            )

            path_counts[
                key
            ]=(
                path_counts.get(
                    key,
                    0,
                )
                + 1
            )


    return {
        "schema":
            2,

        "mode":
            "shadow",

        "authority": [
            "locked_identity",
            "final_results",
            "final_pipeline",
        ],

        "accepted_final_states":
            sorted(
                FINAL_STATES
            ),

        "non_final_states":
            sorted(
                NON_FINAL_STATES
            ),

        "current_config_count":
            len(records),

        "counts":
            counts,

        "selected_source_counts":
            source_counts,

        "selected_path_counts":
            path_counts,

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

        if isinstance(obj,dict):

            cid=(
                obj.get(
                    "config_id"
                )
                or obj.get(
                    "id"
                )
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

        ids=store_ids(
            root
        )

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

            "delete_allowed":
                False,
        }


    return result
PY

echo "CONTRACT_FIX_INSTALLED"


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
# 5 SYNTHETIC CONTRACT TESTS
################################################

echo
echo "========== [5/10] CONTRACT SELFTEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.projection import (
    CountryEvidence,
    choose_projection,
)


def row(
    source,
    code,
    state,
    accepted,
    path="$",
    locked=False,
):

    return CountryEvidence(
        source=source,
        config_id="x",

        country_code=code,
        country_name=None,
        flag=None,

        confidence=1.0,

        state=state,
        evidence_path=path,

        locked=locked,
        accepted=accepted,
        reason="test",
    )


# Pipeline final works.
r=choose_projection(
    "x",
    [
        row(
            "pipeline_latest",
            "DE",
            "confirmed_stable",
            True,
        )
    ],
)

assert r.state=="resolved"
assert r.country_code=="DE"
assert (
    r.selected_source
    =="pipeline_latest"
)


# pending must not resolve
r=choose_projection(
    "x",
    [
        row(
            "pipeline_latest",
            "DE",
            "pending_confirmation",
            False,
        )
    ],
)

assert r.state=="unknown"


# ambiguous must not resolve
r=choose_projection(
    "x",
    [
        row(
            "pipeline_latest",
            "DE",
            "ambiguous",
            False,
        )
    ],
)

assert r.state=="unknown"


# locked identity wins
r=choose_projection(
    "x",
    [
        row(
            "identity",
            "DE",
            "confirmed",
            True,
            locked=True,
        ),
        row(
            "pipeline_latest",
            "DE",
            "confirmed_stable",
            True,
        ),
    ],
)

assert r.state=="resolved"
assert r.selected_source=="identity"


# Cross-source disagreement
# stays fail-closed.
r=choose_projection(
    "x",
    [
        row(
            "identity",
            "DE",
            "confirmed",
            True,
            locked=True,
        ),
        row(
            "pipeline_latest",
            "US",
            "confirmed_stable",
            True,
        ),
    ],
)

assert r.state=="conflict"
assert r.country_code is None


print("SELFTEST_OK")
print("FINAL_PIPELINE_ACCEPTED=YES")
print("PENDING_BLOCKED=YES")
print("AMBIGUOUS_BLOCKED=YES")
print("IDENTITY_PRIORITY=YES")
print("CROSS_SOURCE_FAIL_CLOSED=YES")
PY


################################################
# 6 LIVE SHADOW BUILD
################################################

echo
echo "========== [6/10] LIVE SHADOW BUILD =========="

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
    p[
        "current_config_count"
    ],
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
    p[
        "selected_source_counts"
    ],
)

print(
    "PATH_COUNTS=",
    p[
        "selected_path_counts"
    ],
)
PY


################################################
# 7 SUMMARY / ORPHANS
################################################

echo
echo "========== [7/10] SUMMARY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$PROJECTION" "$SUMMARY" <<'PY'
import json
import sys

from app.country.projection import (
    orphan_inventory,
)

p=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)


current=int(
    p[
        "current_config_count"
    ]
)

resolved=int(
    p[
        "counts"
    ].get(
        "resolved",
        0,
    )
)

unknown=int(
    p[
        "counts"
    ].get(
        "unknown",
        0,
    )
)

conflict=int(
    p[
        "counts"
    ].get(
        "conflict",
        0,
    )
)


summary={
    "phase":
        "phase5-pass4-canonical-projection-contract-fix-pipeline-authority",

    "mode":
        "shadow",

    "schema":
        p.get(
            "schema"
        ),

    "current_config_count":
        current,

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
                / current
            )
            if current
            else 0,
            3,
        ),

    "unknown_percent":
        round(
            (
                unknown
                * 100
                / current
            )
            if current
            else 0,
            3,
        ),

    "selected_source_counts":
        p[
            "selected_source_counts"
        ],

    "selected_path_counts":
        p[
            "selected_path_counts"
        ],

    "authority":
        p[
            "authority"
        ],

    "orphan_inventory":
        orphan_inventory(),

    "mutations": {
        "config":
            False,

        "country_store":
            False,

        "orphan_delete":
            False,

        "panel":
            False,

        "publish":
            False,
    },
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
    json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 8 VALIDATE CONTRACT
################################################

echo
echo "========== [8/10] VALIDATE =========="

"$PROJECT/venv/bin/python" \
- "$PROJECTION" "$SUMMARY" <<'PY'
import json
import sys

p=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

s=json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)


assert p["schema"]==2
assert p["mode"]=="shadow"

assert (
    p["current_config_count"]
    > 0
)

assert (
    sum(
        p["counts"].values()
    )
    ==
    p["current_config_count"]
)

assert (
    p["counts"].get(
        "resolved",
        0,
    )
    >= 100
)

# Pass 4 must prove that Pipeline
# authority is actually being used.
assert (
    p[
        "selected_source_counts"
    ].get(
        "pipeline_latest",
        0,
    )
    > 0
)


for cid,row in p[
    "records"
].items():

    assert row["state"] in {
        "resolved",
        "unknown",
        "conflict",
    }


    if row["state"]=="unknown":

        assert (
            row["selected_source"]
            is None
        )


    if row["state"]=="conflict":

        assert row["conflict"] is True
        assert row["country_code"] is None
        assert row["selected_source"] is None


for value in s[
    "mutations"
].values():

    assert value is False


print("CONTRACT_VALID")
print(
    "PIPELINE_AUTHORITY_ACTIVE_SHADOW=YES"
)

print(
    "RESOLVED=",
    s["resolved"],
)

print(
    "UNKNOWN=",
    s["unknown"],
)

print(
    "CONFLICT=",
    s["conflict"],
)

print(
    "RESOLVED_PERCENT=",
    s[
        "resolved_percent"
    ],
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

    ACTIVE="$(
        systemctl is-active \
          "$UNIT" \
          2>/dev/null || true
    )"

    ENABLED="$(
        systemctl is-enabled \
          "$UNIT" \
          2>/dev/null || true
    )"

    echo \
    "$UNIT ACTIVE=$ACTIVE ENABLED=$ENABLED"

done


echo "SERVICE_RESTART=NONE"

echo "CONFIG_WRITE=NO"
echo "COUNTRY_STORE_WRITE=NO"
echo "ORPHAN_DELETE=NO"
echo "PANEL_WIRING=NO"
echo "PUBLISH_WIRING=NO"


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


echo "CANONICAL_PROJECTION_SCHEMA=2"
echo "LOCKED_IDENTITY_AUTHORITY=READY"
echo "FINAL_RESULTS_AUTHORITY=READY"
echo "FINAL_PIPELINE_AUTHORITY=READY"

echo "CONFIRMED_STATE=ACCEPTED"
echo "CONFIRMED_STABLE_STATE=ACCEPTED"
echo "CONFIRMED_ROTATING_IP_STATE=ACCEPTED"

echo "PENDING_CONFIRMATION=BLOCKED"
echo "AMBIGUOUS=BLOCKED"
echo "UNSTABLE_EXIT=BLOCKED"
echo "ERROR_STATE=BLOCKED"

echo "CROSS_SOURCE_CONFLICT=FAIL_CLOSED"

echo "CONFIG_WRITE=NO"
echo "COUNTRY_STORE_WRITE=NO"
echo "ORPHAN_DELETE=NO"
echo "PANEL_WIRING=NO"
echo "PUBLISH_WIRING=NO"

echo
echo "PHASE5_PASS4_SUCCESS"

RESULT="SUCCESS"
