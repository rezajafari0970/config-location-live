#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass5-removal-execution-architecture-rollback-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"

WAIT_STATUS="/var/lib/config-location/removal-wait/status.json"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_ROOT="/root/3245"

BACKUP_DIR="$BACKUP_ROOT/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
CONTRACT="$DISCOVERY_DIR/${PHASE}-${TS}.json"

EXECUTOR="$PROJECT/app/health/lifecycle/removal_executor.py"

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
DRY-RUN EXECUTION ARCHITECTURE

Production delete:
DISABLED

Delete performed:
NO

Rollback contract:
ENABLED

Contract:
$CONTRACT

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
      "$CONTRACT" \
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
echo " PHASE 4 PASS 5"
echo " REMOVAL EXECUTION + ROLLBACK CONTRACT"
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

test -f "$WAIT_STATUS" || {
    fail "removal wait status missing"
    exit 1
}

test -f "$PROJECT/app/publish/filter.py" || {
    fail "publish filter missing"
    exit 1
}

test -f "$PROJECT/app/integrity/referential_guard.py" || {
    fail "referential guard missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP OLD EXECUTOR
################################################

echo
echo "========== [2/10] BACKUP =========="

if [ -f "$EXECUTOR" ]; then
    cp -a \
      "$EXECUTOR" \
      "$BACKUP_DIR/removal_executor.py.before"
fi

cp -a \
  "$WAIT_STATUS" \
  "$BACKUP_DIR/removal-wait-status.reference.json"

echo "BACKUP_OK"


################################################
# 3 INSTALL EXECUTOR CONTRACT
################################################

echo
echo "========== [3/10] INSTALL EXECUTOR CONTRACT =========="

cat > "$EXECUTOR" <<'PY'
from __future__ import annotations

import hashlib
import inspect
import json
import os
import shutil
import tempfile

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT = Path(
    "/var/lib/config-location/health-results/latest"
)

LIFECYCLE_ROOT = Path(
    "/var/lib/config-location/health-lifecycle"
)

COUNTRY_ROOT = Path(
    "/var/lib/config-location/country"
)

WAIT_STATUS = Path(
    "/var/lib/config-location/removal-wait/status.json"
)

ROLLBACK_ROOT = Path(
    "/var/lib/config-location/removal-rollback"
)


PRODUCTION_DELETE = False


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


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
        return {}


def sha256_file(
    path: Path,
) -> str | None:

    if not path.is_file():
        return None

    h=hashlib.sha256()

    with path.open("rb") as fh:

        while True:

            chunk=fh.read(
                1024 * 1024
            )

            if not chunk:
                break

            h.update(chunk)

    return h.hexdigest()


def first_live_candidate() -> dict[str,Any] | None:

    status=read_json(
        WAIT_STATUS
    )

    sample=status.get(
        "live_candidate_sample",
        [],
    )

    if not isinstance(
        sample,
        list,
    ):
        return None

    for row in sample:

        if not isinstance(
            row,
            dict,
        ):
            continue

        if row.get(
            "live_safe_candidate"
        ) is True:

            return row

    return None


def locate_candidate_files(
    config_id: str,
) -> dict[str,Any]:

    direct={
        "config":
            CONFIG_ROOT
            / f"{config_id}.json",

        "health":
            HEALTH_ROOT
            / f"{config_id}.json",
    }


    country_matches=[]

    if COUNTRY_ROOT.exists():

        for path in COUNTRY_ROOT.rglob("*"):

            if not path.is_file():
                continue

            try:
                if (
                    config_id
                    in path.name
                ):
                    country_matches.append(
                        str(path)
                    )
                    continue

                if (
                    path.stat().st_size
                    <= 2_000_000
                ):

                    text=path.read_text(
                        encoding="utf-8",
                        errors="ignore",
                    )

                    if config_id in text:
                        country_matches.append(
                            str(path)
                        )

            except Exception:
                continue


    lifecycle_matches=[]

    if LIFECYCLE_ROOT.exists():

        for path in LIFECYCLE_ROOT.glob(
            "*.json"
        ):

            try:
                if (
                    path.stat().st_size
                    <= 50_000_000
                ):

                    text=path.read_text(
                        encoding="utf-8",
                        errors="ignore",
                    )

                    if config_id in text:
                        lifecycle_matches.append(
                            str(path)
                        )

            except Exception:
                continue


    return {
        "config":
            str(
                direct["config"]
            ),

        "config_exists":
            direct["config"].exists(),

        "health":
            str(
                direct["health"]
            ),

        "health_exists":
            direct["health"].exists(),

        "country_matches":
            sorted(
                set(
                    country_matches
                )
            ),

        "lifecycle_matches":
            sorted(
                set(
                    lifecycle_matches
                )
            ),
    }


def build_final_revalidation(
    candidate: dict[str,Any],
) -> dict[str,Any]:

    cid=str(
        candidate.get(
            "config_id",
            "",
        )
    ).strip()

    if not cid:
        return {
            "valid":
                False,

            "reason":
                "missing_config_id",
        }


    config_path=(
        CONFIG_ROOT
        / f"{cid}.json"
    )

    health_path=(
        HEALTH_ROOT
        / f"{cid}.json"
    )


    health=read_json(
        health_path
    )


    health_state=str(
        health.get(
            "state",
            "unknown",
        )
    ).lower()


    unhealthy_streak=int(
        candidate.get(
            "current_unhealthy_streak",
            0,
        )
        or 0
    )


    healthy_streak=int(
        candidate.get(
            "current_healthy_streak",
            0,
        )
        or 0
    )


    min_streak=int(
        candidate.get(
            "min_streak",
            8,
        )
        or 8
    )


    checks={
        "config_exists":
            config_path.exists(),

        "health_exists":
            health_path.exists(),

        "latest_health_unhealthy":
            health_state
            == "unhealthy",

        "policy_delete_shadow":
            bool(
                candidate.get(
                    "delete_candidate_shadow",
                    False,
                )
            ),

        "minimum_streak_met":
            unhealthy_streak
            >= min_streak,

        "healthy_streak_zero":
            healthy_streak
            == 0,

        "worker_marked_live_safe":
            candidate.get(
                "live_safe_candidate"
            )
            is True,
    }


    return {
        "valid":
            all(
                checks.values()
            ),

        "config_id":
            cid,

        "checks":
            checks,

        "latest_health_state":
            health_state,

        "unhealthy_streak":
            unhealthy_streak,

        "healthy_streak":
            healthy_streak,

        "minimum_streak":
            min_streak,
    }


def inspect_publish_state(
    config_id: str,
) -> dict[str,Any]:

    from app.publish.filter import (
        publishable_config_ids,
    )

    try:

        publishable=set(
            publishable_config_ids()
        )

    except Exception as exc:

        return {
            "check_ok":
                False,

            "error":
                repr(exc),

            "publishable":
                None,
        }


    return {
        "check_ok":
            True,

        "publishable":
            config_id in publishable,

        "expected_for_removal_candidate":
            False,
    }


def inspect_referential_guard() -> dict[str,Any]:

    import app.integrity.referential_guard as rg


    wanted=(
        "reconcile_one_orphan",
        "sweep_orphans",
    )

    result={}


    for name in wanted:

        fn=getattr(
            rg,
            name,
            None,
        )

        if fn is None:

            result[name]={
                "exists":
                    False,
            }

            continue


        try:

            sig=str(
                inspect.signature(
                    fn
                )
            )

        except Exception:

            sig="unknown"


        result[name]={
            "exists":
                True,

            "callable":
                callable(fn),

            "signature":
                sig,
        }


    return result


def build_backup_manifest(
    config_id: str,
    files: dict[str,Any],
) -> dict[str,Any]:

    paths=[]


    for key in (
        "config",
        "health",
    ):

        value=files.get(
            key
        )

        if value:

            p=Path(value)

            if p.is_file():
                paths.append(p)


    for key in (
        "country_matches",
        "lifecycle_matches",
    ):

        for value in files.get(
            key,
            [],
        ):

            p=Path(value)

            if p.is_file():
                paths.append(p)


    unique=[]

    seen=set()

    for path in paths:

        resolved=str(
            path.resolve()
        )

        if resolved in seen:
            continue

        seen.add(
            resolved
        )

        unique.append(
            path
        )


    return {
        "config_id":
            config_id,

        "generated_at":
            now_iso(),

        "files": [
            {
                "path":
                    str(path),

                "size":
                    path.stat().st_size,

                "mode":
                    oct(
                        path.stat().st_mode
                        & 0o777
                    ),

                "uid":
                    path.stat().st_uid,

                "gid":
                    path.stat().st_gid,

                "sha256":
                    sha256_file(
                        path
                    ),
            }
            for path in unique
        ],
    }


def build_rollback_contract(
    config_id: str,
    backup_manifest: dict[str,Any],
) -> dict[str,Any]:

    return {
        "version":
            1,

        "config_id":
            config_id,

        "rollback_order": [
            "restore config store record",
            "restore canonical health record",
            "restore lifecycle references if independently stored",
            "restore country references if independently stored",
            "regenerate lifecycle snapshots",
            "regenerate safety snapshot",
            "verify publish state",
            "run referential guard",
        ],

        "backup_manifest":
            backup_manifest,

        "preconditions": {
            "production_delete":
                False,

            "backup_complete_before_delete":
                True,

            "all_backup_hashes_verified":
                True,

            "exclusive_destructive_lock_required":
                True,
        },
    }


def build_removal_plan() -> dict[str,Any]:

    candidate=first_live_candidate()


    if candidate is None:

        return {
            "mode":
                "dry_run",

            "state":
                "WAITING_NO_CANDIDATE",

            "production_delete":
                False,

            "delete_performed":
                False,

            "candidate":
                None,

            "generated_at":
                now_iso(),
        }


    cid=str(
        candidate["config_id"]
    )


    revalidation=build_final_revalidation(
        candidate
    )


    files=locate_candidate_files(
        cid
    )


    publish=inspect_publish_state(
        cid
    )


    guard=inspect_referential_guard()


    backup_manifest=build_backup_manifest(
        cid,
        files,
    )


    rollback=build_rollback_contract(
        cid,
        backup_manifest,
    )


    gates={
        "final_revalidation":
            revalidation.get(
                "valid"
            )
            is True,

        "publish_already_excluded":
            (
                publish.get(
                    "check_ok"
                )
                is True
                and publish.get(
                    "publishable"
                )
                is False
            ),

        "config_file_exists":
            files[
                "config_exists"
            ],

        "health_file_exists":
            files[
                "health_exists"
            ],

        "backup_manifest_nonempty":
            len(
                backup_manifest[
                    "files"
                ]
            )
            >= 2,

        "referential_guard_available":
            (
                guard.get(
                    "reconcile_one_orphan",
                    {}
                ).get(
                    "exists"
                )
                is True
            ),
    }


    would_be_removal_ready=(
        all(
            gates.values()
        )
    )


    return {
        "mode":
            "dry_run",

        "state":
            (
                "REMOVAL_READY_SHADOW"
                if would_be_removal_ready
                else "REMOVAL_BLOCKED"
            ),

        "generated_at":
            now_iso(),

        "production_delete":
            False,

        "delete_performed":
            False,

        "delete_api_called":
            False,

        "config_id":
            cid,

        "candidate":
            candidate,

        "final_revalidation":
            revalidation,

        "publish":
            publish,

        "referential_guard":
            guard,

        "files":
            files,

        "backup_manifest":
            backup_manifest,

        "rollback_contract":
            rollback,

        "safety_gates":
            gates,

        "would_be_removal_ready":
            would_be_removal_ready,

        "execution_contract": {
            "step_1":
                "final live revalidation",

            "step_2":
                "acquire exclusive destructive lock",

            "step_3":
                "create immutable backup bundle",

            "step_4":
                "verify backup hashes",

            "step_5":
                "remove canonical config record",

            "step_6":
                "remove canonical health record",

            "step_7":
                "reconcile lifecycle state",

            "step_8":
                "reconcile country references",

            "step_9":
                "run referential guard",

            "step_10":
                "regenerate lifecycle/policy/safety",

            "step_11":
                "verify config absent from publish",

            "step_12":
                "commit removal journal",

            "rollback":
                "restore backup bundle in reverse dependency order",
        },
    }


# IMPORTANT:
#
# This module intentionally contains no destructive
# execution implementation.
#
# There is no:
#   unlink()
#   os.remove()
#   shutil.rmtree()
#   delete config API invocation
#
# Pass 5 defines the architecture only.
PY

echo "EXECUTOR_CONTRACT_INSTALLED"


################################################
# 4 STATIC DESTRUCTIVE GUARD
################################################

echo
echo "========== [4/10] STATIC DESTRUCTIVE GUARD =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - "$EXECUTOR" <<'PYGUARD'
import ast
import sys

path = sys.argv[1]

tree = ast.parse(
    open(
        path,
        encoding="utf-8",
    ).read(),
    filename=path,
)

dangerous = {
    "os.remove",
    "os.unlink",
    "shutil.rmtree",
}

found = []

for node in ast.walk(tree):

    if not isinstance(node, ast.Call):
        continue

    fn = node.func
    name = None

    if isinstance(fn, ast.Attribute):

        if isinstance(fn.value, ast.Name):
            name = f"{fn.value.id}.{fn.attr}"

        elif fn.attr == "unlink":
            name = "Path.unlink"

    if name in dangerous or name == "Path.unlink":
        found.append(
            {
                "line": node.lineno,
                "call": name,
            }
        )

if found:
    for item in found:
        print(
            f"DANGEROUS_CALL line={item['line']} call={item['call']}"
        )

    raise SystemExit(1)

print("AST_DESTRUCTIVE_GUARD_OK")
PYGUARD

echo "NO_DESTRUCTIVE_PRIMITIVES=YES"


################################################
# 5 COMPILE / IMPORT
################################################

echo
echo "========== [5/10] COMPILE + IMPORT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/lifecycle/removal_executor.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.removal_executor import (
    build_removal_plan,
    PRODUCTION_DELETE,
)

assert PRODUCTION_DELETE is False

plan=build_removal_plan()

assert (
    plan["production_delete"]
    is False
)

assert (
    plan["delete_performed"]
    is False
)

print("IMPORT_PLAN_OK")
print("STATE=",plan["state"])
PY


################################################
# 6 BUILD CURRENT PLAN
################################################

echo
echo "========== [6/10] BUILD CURRENT PLAN =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$CONTRACT" <<'PY'
import json
import sys

from app.health.lifecycle.removal_executor import (
    build_removal_plan,
)

plan=build_removal_plan()

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        plan,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    json.dumps(
        plan,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 7 VALIDATE CONTRACT
################################################

echo
echo "========== [7/10] VALIDATE CONTRACT =========="

"$PROJECT/venv/bin/python" \
- "$CONTRACT" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert (
    d["mode"]
    == "dry_run"
)

assert (
    d["production_delete"]
    is False
)

assert (
    d["delete_performed"]
    is False
)


state=d["state"]

assert state in {
    "WAITING_NO_CANDIDATE",
    "REMOVAL_READY_SHADOW",
    "REMOVAL_BLOCKED",
}


print("ROLLBACK_CONTRACT_VALID")
print("STATE=",state)


if state=="WAITING_NO_CANDIDATE":

    print(
        "LIVE_CANDIDATE=NONE"
    )

    print(
        "EXPECTED_WAITING_STATE=YES"
    )


else:

    print(
        "CONFIG_ID=",
        d["config_id"],
    )

    print(
        "FINAL_REVALIDATION=",
        d[
            "final_revalidation"
        ][
            "valid"
        ],
    )

    print(
        "PUBLISHABLE=",
        d[
            "publish"
        ].get(
            "publishable"
        ),
    )

    print(
        "BACKUP_FILES=",
        len(
            d[
                "backup_manifest"
            ][
                "files"
            ]
        ),
    )

    print(
        "WOULD_BE_REMOVAL_READY=",
        d[
            "would_be_removal_ready"
        ],
    )
PY


################################################
# 8 REFERENTIAL GUARD CONTRACT
################################################

echo
echo "========== [8/10] REFERENTIAL GUARD =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import inspect

import app.integrity.referential_guard as rg

for name in (
    "reconcile_one_orphan",
    "sweep_orphans",
):

    fn=getattr(
        rg,
        name,
        None,
    )

    print(
        name,
        "exists=",
        fn is not None,
        "signature=",
        (
            inspect.signature(fn)
            if fn
            else None
        ),
    )

print(
    "REFERENTIAL_GUARD_INSPECTED"
)
PY


################################################
# 9 SERVICES
################################################

echo
echo "========== [9/10] SERVICES =========="

systemctl is-active \
  config-location-retest.service \
  2>/dev/null || true

systemctl is-active \
  config-location-removal-wait.service \
  2>/dev/null || true

echo "SERVICE_RESTART=NONE"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "REMOVAL_EXECUTION_ARCHITECTURE=READY"
echo "ROLLBACK_CONTRACT=READY"

echo "FINAL_REVALIDATION=REQUIRED"
echo "EXCLUSIVE_LOCK=REQUIRED"
echo "BACKUP_BEFORE_DELETE=REQUIRED"
echo "HASH_VERIFICATION=REQUIRED"
echo "REFERENTIAL_GUARD=REQUIRED"

echo "PRODUCTION_DELETE=DISABLED"
echo "DELETE_PERFORMED=NO"
echo "DESTRUCTIVE_PRIMITIVES=NONE"

echo
echo "PHASE4_PASS5_SUCCESS"

RESULT="SUCCESS"
