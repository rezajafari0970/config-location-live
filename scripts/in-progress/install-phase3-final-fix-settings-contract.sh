#!/usr/bin/env bash
set -Eeu

PHASE="phase3-final-fix-settings-contract-alignment"

PROJECT="/opt/config-location"
REPO="/root/project-log"

SERVICE="config-location-retest.service"
STATUS="/var/lib/config-location/retest/status.json"
LATEST="/var/lib/config-location/health-results/latest"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
CONTRACT="$DISCOVERY_DIR/${PHASE}-${TS}-contract.json"
FINAL="$DISCOVERY_DIR/${PHASE}-${TS}-final.json"

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

 echo
 echo "========== FINAL =========="
 echo "RESULT=$RESULT"
 echo "END=$(date -Is)"

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

Contract:
$CONTRACT

Final:
$FINAL

Service:
$SERVICE

Production worker modified:
NO

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
   "$FINAL" \
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
echo " PHASE 3 FINAL FIX"
echo " SETTINGS CONTRACT ALIGNMENT"
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

test -f "$PROJECT/app/settings/engine.py" || {
 fail "settings engine missing"
 exit 1
}

test -f "$PROJECT/app/health/retest/worker.py" || {
 fail "retest worker missing"
 exit 1
}

test -f "$STATUS" || {
 fail "status missing"
 exit 1
}

test -d "$LATEST" || {
 fail "health latest missing"
 exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP REFERENCES
################################################

echo
echo "========== [2/12] BACKUP =========="

cp -a \
 "$PROJECT/app/settings/engine.py" \
 "$BACKUP_DIR/engine.py.reference"

cp -a \
 "$PROJECT/app/health/retest/worker.py" \
 "$BACKUP_DIR/worker.py.reference"

cp -a \
 "$STATUS" \
 "$BACKUP_DIR/status.before.json"

echo "BACKUP_OK"


################################################
# 3 COMPILE
################################################

echo
echo "========== [3/12] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
 app/settings/engine.py \
 app/health/retest/worker.py \
 app/health/retest/privileged_plan.py \
 app/health/core/engine.py \
 app/health/core/batch.py \
 app/health/storage/json_store.py \
 app/publish/filter.py

echo "COMPILE_OK"


################################################
# 4 DISCOVER REAL SETTINGS CONTRACT
################################################

echo
echo "========== [4/12] DISCOVER SETTINGS CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$CONTRACT" <<'PY'
import json
import sys

from app.settings.engine import get_settings

s=get_settings()


def walk(value,path=""):
    rows=[]

    if isinstance(value,dict):
        for k,v in value.items():
            p=f"{path}.{k}" if path else k

            if isinstance(v,(dict,list)):
                rows.extend(
                    walk(v,p)
                )
            else:
                rows.append(
                    (p,v)
                )

    elif isinstance(value,list):
        for i,v in enumerate(value):
            rows.extend(
                walk(
                    v,
                    f"{path}[{i}]",
                )
            )

    return rows


rows=walk(s)


retest_matches=[]

for path,value in rows:
    low=path.lower()

    if (
        "retest" in low
        or (
            "health" in low
            and "minute" in low
        )
    ):
        retest_matches.append(
            {
                "path":path,
                "value":value,
            }
        )


resources=s.get(
    "resources",
    {}
)


required_resources=(
    "cpu_warning_percent",
    "cpu_critical_percent",
    "ram_warning_percent",
    "ram_critical_percent",
    "disk_warning_percent",
    "disk_critical_percent",
)


missing=[
    key
    for key in required_resources
    if key not in resources
]

if missing:
    raise RuntimeError(
        "missing resources keys: "
        + ",".join(missing)
    )


out={
    "top_level_keys":
        sorted(s.keys()),

    "retest_matches":
        retest_matches,

    "resources":
        {
            key:resources[key]
            for key
            in required_resources
        },
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

echo "SETTINGS_DISCOVERY_OK"


################################################
# 5 RESOLVE RETEST CONTRACT FROM SAME API
################################################

echo
echo "========== [5/12] RETEST CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.retest import (
    build_privileged_retest_plan,
)

from app.settings.engine import (
    get_settings,
)

s=get_settings()

plan=build_privileged_retest_plan(
    limit=1
)

minutes=int(
    plan["retest_minutes"]
)

assert minutes >= 1

print(
    "CANONICAL_RETEST_MINUTES=",
    minutes,
)

print(
    "PLAN_INTERVAL_SECONDS=",
    plan["interval_seconds"],
)

assert (
    int(plan["interval_seconds"])
    == minutes * 60
)

print(
    "RETEST_CONTRACT_OK"
)
PY


################################################
# 6 RESOURCE CONTRACT
################################################

echo
echo "========== [6/12] RESOURCE CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import get_settings

from app.health.retest.worker import (
    resource_guardian_settings,
    resource_snapshot,
    adaptive_policy,
)

s=get_settings()

resources=s["resources"]

g=resource_guardian_settings()


mapping={
    "cpu_warning_pct":
        "cpu_warning_percent",

    "cpu_critical_pct":
        "cpu_critical_percent",

    "ram_warning_pct":
        "ram_warning_percent",

    "ram_critical_pct":
        "ram_critical_percent",

    "disk_warning_pct":
        "disk_warning_percent",

    "disk_critical_pct":
        "disk_critical_percent",
}


for worker_key,settings_key in mapping.items():

    expected=float(
        resources[
            settings_key
        ]
    )

    actual=float(
        g[
            worker_key
        ]
    )

    assert actual == expected, (
        worker_key,
        actual,
        expected,
    )

    assert (
        g["sources"][worker_key]
        ==
        f"resources.{settings_key}"
    )


assert (
    g["cpu_warning_pct"]
    <
    g["cpu_critical_pct"]
)

assert (
    g["ram_warning_pct"]
    <
    g["ram_critical_pct"]
)

assert (
    g["disk_warning_pct"]
    <
    g["disk_critical_pct"]
)


r=resource_snapshot()

p=adaptive_policy(
    r,
    1000,
)

assert 1 <= p["workers"] <= 3
assert 2 <= p["batch"] <= 9


print("RESOURCE_CONTRACT_OK")
print("GUARDIAN=",g)
print("POLICY=",p)
PY


################################################
# 7 SYSTEMD
################################################

echo
echo "========== [7/12] SYSTEMD =========="

ACTIVE="$(
 systemctl is-active "$SERVICE"
)"

ENABLED="$(
 systemctl is-enabled "$SERVICE"
)"

echo "ACTIVE=$ACTIVE"
echo "ENABLED=$ENABLED"

[ "$ACTIVE" = "active" ] || {
 fail "service inactive"
 exit 1
}

[ "$ENABLED" = "enabled" ] || {
 fail "service disabled"
 exit 1
}

echo "SYSTEMD_OK"


################################################
# 8 ELIGIBILITY
################################################

echo
echo "========== [8/12] ELIGIBILITY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.retest import (
    build_privileged_retest_plan,
)

p=build_privileged_retest_plan(
    limit=10
)

assert p["scanned_records"] > 0
assert p["parsed_records"] > 0
assert p["real_healthy"] > 0

print("ELIGIBILITY_OK")
print("SCANNED=",p["scanned_records"])
print("HEALTHY=",p["real_healthy"])
print("DUE=",p["due_total"])
print("CANDIDATES=",p["candidate_count"])
PY


################################################
# 9 OBSERVE REAL RETEST
################################################

echo
echo "========== [9/12] REAL RETEST =========="

BEFORE="$(
"$PROJECT/venv/bin/python" \
- "$STATUS" <<'PY'
import json,sys

d=json.load(open(sys.argv[1]))
print(int(d.get("total_tests",0)))
PY
)"

echo "BEFORE_TESTS=$BEFORE"

OBSERVED=0

for i in $(seq 1 180); do

 NOW="$(
 "$PROJECT/venv/bin/python" \
 - "$STATUS" <<'PY'
import json,sys

try:
 d=json.load(open(sys.argv[1]))
 print(int(d.get("total_tests",0)))
except Exception:
 print(0)
PY
 )"

 echo "OBSERVE_$i TESTS=$NOW"

 if [ "$NOW" -gt "$BEFORE" ]; then
   OBSERVED=1
   break
 fi

 sleep 1
done

[ "$OBSERVED" -eq 1 ] || {
 fail "no new retest observed"
 exit 1
}

echo "REAL_RETEST_OK"


################################################
# 10 PERSISTENCE + PUBLISH
################################################

echo
echo "========== [10/12] PERSISTENCE / PUBLISH =========="

sleep 7

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$STATUS" <<'PY'
import json
import sys
from pathlib import Path

from app.publish.filter import (
    publishable_config_ids,
)

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

rows=d.get(
    "cycle_results",
    []
)

assert rows

latest=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

publishable=set(
    publishable_config_ids()
)

checked=0
unhealthy=0

for row in rows:

    cid=row["config_id"]

    path=latest/f"{cid}.json"

    assert path.exists()

    stored=json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    assert (
        stored.get("state")
        ==
        row.get("state")
    )

    checked += 1

    if row.get("state") != "healthy":

        unhealthy += 1

        assert cid not in publishable


print(
    "CANONICAL_PERSISTENCE_OK"
)

print(
    "RESULTS_CHECKED=",
    checked,
)

print(
    "UNHEALTHY_FILTERED=",
    unhealthy,
)
PY


################################################
# 11 PANEL + JOURNAL
################################################

echo
echo "========== [11/12] PANEL / RUNTIME =========="

HTTP="$(
curl \
 -sS \
 --connect-timeout 5 \
 --max-time 10 \
 -o /dev/null \
 -w '%{http_code}' \
 http://127.0.0.1:4040/settings \
 || true
)"

echo "SETTINGS_HTTP=$HTTP"

case "$HTTP" in
 200|301|302|303|307|308|401|403)
   ;;
 *)
   fail "settings endpoint failed: $HTTP"
   exit 1
   ;;
esac


FATAL="$(
journalctl \
 -u "$SERVICE" \
 --since "$START" \
 --no-pager \
 | grep -Ei \
 'Traceback|SyntaxError|ModuleNotFoundError|PermissionError|segmentation fault|fatal' \
 || true
)"

if [ -n "$FATAL" ]; then
 echo "$FATAL"
 fail "fatal runtime error"
 exit 1
fi

echo "PANEL_RUNTIME_OK"


################################################
# 12 FINAL SNAPSHOT
################################################

echo
echo "========== [12/12] FINAL =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$STATUS" "$FINAL" "$CONTRACT" "$HTTP" <<'PY'
import json
import sys
from datetime import datetime, timezone

status=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

contract=json.load(
    open(
        sys.argv[3],
        encoding="utf-8",
    )
)

out={
    "phase":
        "phase3-final-fix-settings-contract-alignment",

    "result":
        "SUCCESS",

    "generated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),

    "production_worker_modified":
        False,

    "settings_contract":
        contract,

    "runtime": {
        "service_active":
            True,

        "service_enabled":
            True,

        "settings_http":
            int(sys.argv[4]),

        "mode":
            status.get("mode"),

        "cycle":
            status.get("cycle"),

        "retest_minutes":
            status.get(
                "retest_minutes"
            ),

        "due_total":
            status.get(
                "due_total"
            ),

        "adaptive_workers":
            status.get(
                "adaptive_workers"
            ),

        "adaptive_batch":
            status.get(
                "adaptive_batch"
            ),

        "resource_level":
            status.get(
                "resource_level"
            ),

        "total_tests":
            status.get(
                "total_tests"
            ),

        "total_healthy":
            status.get(
                "total_healthy"
            ),

        "total_unhealthy":
            status.get(
                "total_unhealthy"
            ),

        "total_errors":
            status.get(
                "total_errors"
            ),
    },

    "checks": {
        "precheck": True,
        "compile": True,
        "settings_discovery": True,
        "retest_contract": True,
        "resource_contract": True,
        "systemd": True,
        "eligibility": True,
        "real_retest": True,
        "canonical_persistence": True,
        "publish_filter": True,
        "panel": True,
        "fatal_errors": False,
    },

    "phase3_freeze_ready":
        True,
}


with open(
    sys.argv[2],
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


echo
echo "================================================"
echo " PHASE 3 FINAL REGRESSION: PASS"
echo "================================================"

echo "SETTINGS_CONTRACT_ALIGNED=YES"
echo "PRODUCTION_WORKER_MODIFIED=NO"
echo "PHASE3_FREEZE_READY=YES"
echo "PHASE3_FINAL_SUCCESS"

RESULT="SUCCESS"
