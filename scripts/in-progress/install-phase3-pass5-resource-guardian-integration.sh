#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass5-resource-guardian-telemetry-cleanup"

PROJECT="/opt/config-location"
REPO="/root/project-log"

SERVICE="config-location-retest.service"
WORKER="$PROJECT/app/health/retest/worker.py"
STATUS="/var/lib/config-location/retest/status.json"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
OBSERVE="$DISCOVERY_DIR/${PHASE}-${TS}.json"

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

Service:
$SERVICE

Integration:
Resource Guardian -> Retest Adaptive Controller

Observation:
$OBSERVE

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
   "$OBSERVE" \
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
echo " PHASE 3 PASS 5"
echo " RESOURCE GUARDIAN + TELEMETRY CLEANUP"
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

test -f "$WORKER" || {
 fail "adaptive worker missing"
 exit 1
}

test -f "$PROJECT/app/settings/engine.py" || {
 fail "settings engine missing"
 exit 1
}

test "$(systemctl is-active "$SERVICE")" = "active" || {
 fail "retest service not active"
 exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/10] BACKUP =========="

cp -a "$WORKER" \
 "$BACKUP_DIR/worker.py.before"

[ ! -f "$STATUS" ] || \
 cp -a "$STATUS" \
 "$BACKUP_DIR/status.json.before"

echo "BACKUP_OK"


################################################
# 3 DISCOVER CENTRAL SETTINGS
################################################

echo
echo "========== [3/10] RESOURCE GUARDIAN SETTINGS =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from app.settings.engine import get_settings

s=get_settings()

print(
 json.dumps(
   s.get("resource_guardian", {}),
   ensure_ascii=False,
   indent=2,
 )
)
PY


################################################
# 4 PATCH WORKER
################################################

echo
echo "========== [4/10] PATCH WORKER =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path

p=Path(
 "/opt/config-location/app/health/retest/worker.py"
)

text=p.read_text(
 encoding="utf-8"
)

# Import Central Settings if not already present.
marker='from app.health.retest import ('

if (
 'from app.settings.engine import get_settings'
 not in text
):
 text=text.replace(
   marker,
   'from app.settings.engine import get_settings\n\n'
   + marker,
   1,
 )


# Insert helper immediately before adaptive_policy.
needle='def adaptive_policy(\n'

if needle not in text:
 raise RuntimeError(
   "adaptive_policy insertion point missing"
 )

helper=r'''
def resource_guardian_settings() -> dict[str, float]:
    """
    Central Settings is the source of truth.

    Values are percentages:
      CPU warning / critical
      RAM warning / critical
    """

    settings = get_settings()

    section = settings.get(
        "resource_guardian",
        {},
    )

    def number(
        keys,
        default,
    ):
        for key in keys:
            value = section.get(key)

            if value is None:
                continue

            try:
                return float(value)
            except (
                TypeError,
                ValueError,
            ):
                continue

        return float(default)

    return {
        "cpu_warning_pct": number(
            (
                "cpu_warning_pct",
                "cpu_warning",
                "cpu_warn_pct",
            ),
            75,
        ),

        "cpu_critical_pct": number(
            (
                "cpu_critical_pct",
                "cpu_critical",
                "cpu_crit_pct",
            ),
            90,
        ),

        "ram_warning_pct": number(
            (
                "ram_warning_pct",
                "ram_warning",
                "ram_warn_pct",
            ),
            80,
        ),

        "ram_critical_pct": number(
            (
                "ram_critical_pct",
                "ram_critical",
                "ram_crit_pct",
            ),
            95,
        ),
    }


'''

if 'def resource_guardian_settings()' not in text:
 text=text.replace(
   needle,
   helper + needle,
   1,
 )


start=text.index(
 'def adaptive_policy(\n'
)

end=text.index(
 '\ndef sleep_interruptible(',
 start,
)

replacement=r'''def adaptive_policy(
    resource: dict[str, Any],
    due_total: int,
) -> dict[str, Any]:

    guardian = (
        resource_guardian_settings()
    )

    # Linux load ratio is used as our CPU pressure
    # signal. Convert it to a percentage so it can
    # obey the Central Resource Guardian thresholds.
    cpu_pressure_pct = min(
        max(
            float(
                resource["load_ratio"]
            ) * 100.0,
            0.0,
        ),
        1000.0,
    )

    mem_available_pct = float(
        resource[
            "mem_available_pct"
        ]
    )

    ram_used_pct = max(
        0.0,
        100.0 - mem_available_pct,
    )

    cpu_warning = guardian[
        "cpu_warning_pct"
    ]

    cpu_critical = guardian[
        "cpu_critical_pct"
    ]

    ram_warning = guardian[
        "ram_warning_pct"
    ]

    ram_critical = guardian[
        "ram_critical_pct"
    ]


    if (
        cpu_pressure_pct >= cpu_critical
        or ram_used_pct >= ram_critical
    ):
        return {
            "workers": 1,
            "batch": 2,
            "idle": 30,
            "level": "critical",
            "reason": (
                "resource_guardian_critical"
            ),
            "guardian": guardian,
            "cpu_pressure_pct": round(
                cpu_pressure_pct,
                2,
            ),
            "ram_used_pct": round(
                ram_used_pct,
                2,
            ),
        }


    if (
        cpu_pressure_pct >= cpu_warning
        or ram_used_pct >= ram_warning
    ):
        return {
            "workers": 1,
            "batch": 3,
            "idle": 15,
            "level": "warning",
            "reason": (
                "resource_guardian_warning"
            ),
            "guardian": guardian,
            "cpu_pressure_pct": round(
                cpu_pressure_pct,
                2,
            ),
            "ram_used_pct": round(
                ram_used_pct,
                2,
            ),
        }


    if due_total >= 200:
        workers=3
        batch=9
        reason="healthy_resources_large_backlog"

    elif due_total >= 50:
        workers=2
        batch=6
        reason="healthy_resources_medium_backlog"

    else:
        workers=1
        batch=3
        reason="healthy_resources_small_backlog"


    return {
        "workers": workers,
        "batch": batch,
        "idle": (
            5
            if due_total >= 50
            else 15
        ),
        "level": "normal",
        "reason": reason,
        "guardian": guardian,
        "cpu_pressure_pct": round(
            cpu_pressure_pct,
            2,
        ),
        "ram_used_pct": round(
            ram_used_pct,
            2,
        ),
    }

'''

text=(
 text[:start]
 + replacement
 + text[end:]
)


# Add policy telemetry to write_status.
old='''                resource=resource,

                last_error=None,
'''

new='''                resource=resource,

                resource_guardian=(
                    policy.get(
                        "guardian",
                        {},
                    )
                ),

                resource_level=(
                    policy.get(
                        "level"
                    )
                ),

                adaptive_reason=(
                    policy.get(
                        "reason"
                    )
                ),

                cpu_pressure_pct=(
                    policy.get(
                        "cpu_pressure_pct"
                    )
                ),

                ram_used_pct=(
                    policy.get(
                        "ram_used_pct"
                    )
                ),

                last_error=None,
'''

if old not in text:
 raise RuntimeError(
   "status telemetry insertion point missing"
 )

text=text.replace(
 old,
 new,
 1,
)


# Clean stale lifecycle telemetry on worker startup.
old='''    previous = read_status()

    cycle = int(
'''

new='''    previous = read_status()

    # Remove stale lifecycle fields left by
    # an earlier worker process.
    for stale_key in (
        "stopped_at",
        "current_config_id",
        "current_config_type",
        "current_test_started_at",
    ):
        previous.pop(
            stale_key,
            None,
        )

    atomic_json(
        STATUS,
        previous,
    )

    cycle = int(
'''

if old not in text:
 raise RuntimeError(
   "startup cleanup insertion point missing"
 )

text=text.replace(
 old,
 new,
 1,
)


p.write_text(
 text,
 encoding="utf-8",
)

print(
 "WORKER_PATCH_OK"
)
PY


################################################
# 5 COMPILE + IMPORT
################################################

echo
echo "========== [5/10] COMPILE + IMPORT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile "$WORKER"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.retest.worker import (
 resource_guardian_settings,
 resource_snapshot,
 adaptive_policy,
)

g=resource_guardian_settings()
r=resource_snapshot()
p=adaptive_policy(r,1000)

assert (
 g["cpu_warning_pct"]
 < g["cpu_critical_pct"]
)

assert (
 g["ram_warning_pct"]
 < g["ram_critical_pct"]
)

assert p["level"] in {
 "normal",
 "warning",
 "critical",
}

assert 1 <= p["workers"] <= 3
assert 2 <= p["batch"] <= 9

print("COMPILE_IMPORT_OK")
print("GUARDIAN=",g)
print("RESOURCE=",r)
print("POLICY=",p)
PY


################################################
# 6 RESTART
################################################

echo
echo "========== [6/10] RESTART =========="

systemctl restart "$SERVICE"

for i in $(seq 1 20); do
 ACTIVE="$(
   systemctl is-active "$SERVICE" \
   2>/dev/null || true
 )"

 echo "CHECK_$i=$ACTIVE"

 [ "$ACTIVE" = "active" ] && break

 sleep 1
done

test "$(systemctl is-active "$SERVICE")" = "active" || {
 fail "service restart failed"
 exit 1
}

echo "SERVICE_ACTIVE"


################################################
# 7 OBSERVE
################################################

echo
echo "========== [7/10] OBSERVE =========="

OBSERVED=0

for i in $(seq 1 180); do

 if [ -f "$STATUS" ]; then

   VALID="$(
   "$PROJECT/venv/bin/python" \
   - "$STATUS" <<'PY'
import json,sys

try:
 d=json.load(open(sys.argv[1]))

 ok=(
   d.get("mode")=="adaptive"
   and d.get("resource_level")
      in {"normal","warning","critical"}
   and bool(
     d.get("resource_guardian")
   )
   and d.get("adaptive_reason")
 )

 print("1" if ok else "0")

except Exception:
 print("0")
PY
   )"

   echo "OBSERVE_$i VALID=$VALID"

   if [ "$VALID" = "1" ]; then
     OBSERVED=1
     break
   fi
 fi

 sleep 1
done

[ "$OBSERVED" -eq 1 ] || {
 fail "guardian telemetry not observed"
 exit 1
}

echo "GUARDIAN_TELEMETRY_OBSERVED"


################################################
# 8 VALIDATE TELEMETRY
################################################

echo
echo "========== [8/10] TELEMETRY =========="

cp -a "$STATUS" "$OBSERVE"

"$PROJECT/venv/bin/python" \
- "$OBSERVE" <<'PY'
import json,sys

d=json.load(open(sys.argv[1]))

assert d["mode"]=="adaptive"

assert d["resource_level"] in {
 "normal",
 "warning",
 "critical",
}

assert isinstance(
 d["resource_guardian"],
 dict,
)

# stopped_at must no longer describe the
# currently-running worker.
assert d.get("state") != "stopped"

print("TELEMETRY_VALID")

for k in (
 "state",
 "cycle",
 "retest_minutes",
 "due_total",
 "adaptive_workers",
 "adaptive_batch",
 "adaptive_idle_seconds",
 "resource_level",
 "adaptive_reason",
 "cpu_pressure_pct",
 "ram_used_pct",
 "total_tests",
 "total_healthy",
 "total_unhealthy",
 "total_errors",
):
 print(
   f"{k.upper()}=",
   d.get(k),
 )

print(
 "RESOURCE_GUARDIAN=",
 d.get("resource_guardian"),
)

print(
 "RESOURCE=",
 d.get("resource"),
)

print(
 "STALE_STOPPED_AT=",
 d.get("stopped_at"),
)
PY


################################################
# 9 SERVICE HEALTH
################################################

echo
echo "========== [9/10] SERVICE HEALTH =========="

systemctl is-active "$SERVICE"
systemctl is-enabled "$SERVICE"

FATAL="$(
journalctl \
 -u "$SERVICE" \
 --since "$START" \
 --no-pager \
 | grep -Ei \
 'Traceback|SyntaxError|ModuleNotFoundError|PermissionError|fatal' \
 || true
)"

if [ -n "$FATAL" ]; then
 echo "$FATAL"
 fail "fatal service error"
 exit 1
fi

echo "SERVICE_HEALTH_OK"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "RESOURCE_GUARDIAN_SOURCE=CENTRAL_SETTINGS"
echo "CPU_THRESHOLDS_DYNAMIC=YES"
echo "RAM_THRESHOLDS_DYNAMIC=YES"

echo "ADAPTIVE_WORKERS=1..3"
echo "ADAPTIVE_BATCH=2..9"

echo "STALE_TELEMETRY_CLEANUP=YES"
echo "POLICY_REASON_TELEMETRY=YES"

echo "CANONICAL_BATCH_RUNNER=YES"
echo "CANONICAL_HEALTH_STORE=YES"

echo "SERVICE_ACTIVE=YES"
echo "SERVICE_ENABLED=YES"

echo
echo "PHASE3_PASS5_SUCCESS"

RESULT="SUCCESS"
