#!/usr/bin/env bash
set -Eeu

PHASE="phase3-final-integration-regression"

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

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
RESULT_JSON="$DISCOVERY_DIR/${PHASE}-${TS}.json"

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

    echo
    echo "================================================"
    echo " FINAL RESULT"
    echo "================================================"
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

Service:
$SERVICE

Regression:
$RESULT_JSON

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
      "$RESULT_JSON" \
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
echo " PHASE 3 FINAL"
echo " INTEGRATION / REGRESSION TEST"
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

test -f "$STATUS" || {
    fail "retest status missing"
    exit 1
}

test -d "$LATEST" || {
    fail "health latest store missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 COMPILE REGRESSION
################################################

echo
echo "========== [2/12] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/retest/worker.py \
  app/health/retest/privileged_plan.py \
  app/health/core/engine.py \
  app/health/core/batch.py \
  app/health/storage/json_store.py \
  app/publish/filter.py \
  app/settings/engine.py

echo "COMPILE_OK"


################################################
# 3 SYSTEMD
################################################

echo
echo "========== [3/12] SERVICE =========="

ACTIVE="$(
    systemctl is-active "$SERVICE"
)"

ENABLED="$(
    systemctl is-enabled "$SERVICE"
)"

echo "ACTIVE=$ACTIVE"
echo "ENABLED=$ENABLED"

[ "$ACTIVE" = "active" ] || {
    fail "retest service not active"
    exit 1
}

[ "$ENABLED" = "enabled" ] || {
    fail "retest service not enabled"
    exit 1
}

echo "SYSTEMD_OK"


################################################
# 4 CENTRAL SETTINGS
################################################

echo
echo "========== [4/12] SETTINGS CONTRACT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import get_settings

s=get_settings()

retest=s.get(
    "health_retest",
    {}
)

resources=s.get(
    "resources",
    {}
)

minutes=int(
    retest.get(
        "retest_minutes",
        0,
    )
)

assert minutes >= 1

required=(
    "cpu_warning_percent",
    "cpu_critical_percent",
    "ram_warning_percent",
    "ram_critical_percent",
    "disk_warning_percent",
    "disk_critical_percent",
)

for key in required:
    assert key in resources, key

assert (
    float(resources["cpu_warning_percent"])
    <
    float(resources["cpu_critical_percent"])
)

assert (
    float(resources["ram_warning_percent"])
    <
    float(resources["ram_critical_percent"])
)

print("SETTINGS_CONTRACT_OK")
print("RETEST_MINUTES=",minutes)
print(
    "CPU=",
    resources["cpu_warning_percent"],
    resources["cpu_critical_percent"],
)
print(
    "RAM=",
    resources["ram_warning_percent"],
    resources["ram_critical_percent"],
)
print(
    "DISK=",
    resources["disk_warning_percent"],
    resources["disk_critical_percent"],
)
PY


################################################
# 5 RESOURCE GUARDIAN BINDING
################################################

echo
echo "========== [5/12] RESOURCE GUARDIAN =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.retest.worker import (
    resource_guardian_settings,
    resource_snapshot,
    adaptive_policy,
)

g=resource_guardian_settings()

expected={
    "cpu_warning_pct":
        "resources.cpu_warning_percent",

    "cpu_critical_pct":
        "resources.cpu_critical_percent",

    "ram_warning_pct":
        "resources.ram_warning_percent",

    "ram_critical_pct":
        "resources.ram_critical_percent",

    "disk_warning_pct":
        "resources.disk_warning_percent",

    "disk_critical_pct":
        "resources.disk_critical_percent",
}

for key,path in expected.items():
    assert g["sources"][key] == path
    assert g["sources"][key] != "fallback"

r=resource_snapshot()
p=adaptive_policy(r,1000)

assert 1 <= p["workers"] <= 3
assert 2 <= p["batch"] <= 9

print("RESOURCE_GUARDIAN_OK")
print("GUARDIAN=",g)
print("RESOURCE=",r)
print("POLICY=",p)
PY


################################################
# 6 ELIGIBILITY
################################################

echo
echo "========== [6/12] RETEST ELIGIBILITY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.retest import (
    build_privileged_retest_plan,
)

plan=build_privileged_retest_plan(
    limit=10
)

assert plan["scanned_records"] > 0
assert plan["parsed_records"] > 0
assert plan["real_healthy"] > 0

print("ELIGIBILITY_OK")
print(
    "SCANNED=",
    plan["scanned_records"],
)
print(
    "HEALTHY=",
    plan["real_healthy"],
)
print(
    "DUE=",
    plan["due_total"],
)
print(
    "CANDIDATES=",
    plan["candidate_count"],
)
PY


################################################
# 7 CAPTURE BEFORE
################################################

echo
echo "========== [7/12] CAPTURE BEFORE =========="

BEFORE_TESTS="$(
"$PROJECT/venv/bin/python" \
- "$STATUS" <<'PY'
import json,sys

d=json.load(open(sys.argv[1]))
print(int(d.get("total_tests",0)))
PY
)"

BEFORE_CYCLE="$(
"$PROJECT/venv/bin/python" \
- "$STATUS" <<'PY'
import json,sys

d=json.load(open(sys.argv[1]))
print(int(d.get("cycle",0)))
PY
)"

echo "BEFORE_TESTS=$BEFORE_TESTS"
echo "BEFORE_CYCLE=$BEFORE_CYCLE"


################################################
# 8 OBSERVE REAL PRODUCTION CYCLE
################################################

echo
echo "========== [8/12] REAL PRODUCTION OBSERVATION =========="

OBSERVED=0

for i in $(seq 1 180); do

    NOW_TESTS="$(
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

    NOW_CYCLE="$(
    "$PROJECT/venv/bin/python" \
    - "$STATUS" <<'PY'
import json,sys

try:
    d=json.load(open(sys.argv[1]))
    print(int(d.get("cycle",0)))
except Exception:
    print(0)
PY
    )"

    echo \
    "OBSERVE_$i TESTS=$NOW_TESTS CYCLE=$NOW_CYCLE"

    if [ "$NOW_TESTS" -gt "$BEFORE_TESTS" ]; then
        OBSERVED=1
        break
    fi

    sleep 1
done

[ "$OBSERVED" -eq 1 ] || {
    fail "no new production retest observed"
    exit 1
}

echo "REAL_RETEST_OBSERVED"


################################################
# 9 CANONICAL PERSISTENCE + PUBLISH
################################################

echo
echo "========== [9/12] RESULT / PUBLISH =========="

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

status=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

results=status.get(
    "cycle_results",
    []
)

assert results, "no cycle results"

publishable=set(
    publishable_config_ids()
)

latest_root=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

checked=0
unhealthy_checked=0

for result in results:

    cid=result["config_id"]

    path=(
        latest_root
        / f"{cid}.json"
    )

    assert path.exists(), (
        f"missing canonical result {cid}"
    )

    stored=json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    assert (
        stored.get("state")
        == result.get("state")
    ), cid

    checked += 1

    if (
        result.get("state")
        != "healthy"
    ):
        unhealthy_checked += 1

        assert (
            cid not in publishable
        ), (
            f"unhealthy config still publishable: {cid}"
        )

print("CANONICAL_PERSISTENCE_OK")
print("RESULTS_CHECKED=",checked)
print(
    "UNHEALTHY_PUBLISH_FILTER_CHECKED=",
    unhealthy_checked,
)
PY


################################################
# 10 PANEL / SETTINGS ENDPOINT
################################################

echo
echo "========== [10/12] PANEL =========="

HTTP_CODE="$(
curl \
  -sS \
  --connect-timeout 5 \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/settings \
  || true
)"

echo "SETTINGS_HTTP=$HTTP_CODE"

case "$HTTP_CODE" in
    200|301|302|303|307|308|401|403)
        echo "PANEL_SETTINGS_ENDPOINT_OK"
        ;;
    *)
        fail "settings endpoint unhealthy: $HTTP_CODE"
        exit 1
        ;;
esac


################################################
# 11 FINAL STATUS / JOURNAL
################################################

echo
echo "========== [11/12] RUNTIME HEALTH =========="

systemctl is-active "$SERVICE"
systemctl is-enabled "$SERVICE"

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
    fail "fatal runtime error detected"
    exit 1
fi

echo "NO_FATAL_ERRORS"


################################################
# 12 FINAL SNAPSHOT
################################################

echo
echo "========== [12/12] FINAL SNAPSHOT =========="

"$PROJECT/venv/bin/python" \
- "$STATUS" "$RESULT_JSON" "$HTTP_CODE" <<'PY'
import json
import sys
from datetime import datetime, timezone

src=sys.argv[1]
dst=sys.argv[2]
http_code=sys.argv[3]

d=json.load(
    open(
        src,
        encoding="utf-8",
    )
)

out={
    "phase":
        "phase3-final-integration-regression",

    "result":
        "SUCCESS",

    "generated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),

    "service": {
        "active": True,
        "enabled": True,
    },

    "settings_http":
        int(http_code),

    "retest": {
        "mode":
            d.get("mode"),

        "state":
            d.get("state"),

        "cycle":
            d.get("cycle"),

        "retest_minutes":
            d.get("retest_minutes"),

        "scanned_records":
            d.get("scanned_records"),

        "real_healthy":
            d.get("real_healthy"),

        "due_total":
            d.get("due_total"),

        "adaptive_workers":
            d.get("adaptive_workers"),

        "adaptive_batch":
            d.get("adaptive_batch"),

        "resource_level":
            d.get("resource_level"),

        "adaptive_reason":
            d.get("adaptive_reason"),

        "total_tests":
            d.get("total_tests"),

        "total_healthy":
            d.get("total_healthy"),

        "total_unhealthy":
            d.get("total_unhealthy"),

        "total_errors":
            d.get("total_errors"),

        "throughput_per_hour":
            d.get(
                "current_throughput_per_hour"
            ),
    },

    "resource_guardian":
        d.get("resource_guardian"),

    "checks": {
        "compile":
            True,

        "central_settings":
            True,

        "canonical_resource_binding":
            True,

        "fallback_sources_zero":
            True,

        "eligibility":
            True,

        "real_retest_execution":
            True,

        "canonical_persistence":
            True,

        "publish_filter_reaction":
            True,

        "settings_endpoint":
            True,

        "systemd_active":
            True,

        "boot_enabled":
            True,

        "fatal_runtime_errors":
            False,
    },

    "phase3_freeze_ready":
        True,
}

with open(
    dst,
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

echo "PHASE3_FREEZE_READY=YES"
echo "PHASE3_FINAL_SUCCESS"

RESULT="SUCCESS"
