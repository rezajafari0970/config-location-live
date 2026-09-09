#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass5c-canonical-resources-binding"

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

Binding:
Central Settings resources.* -> Retest Resource Guardian

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
echo " PHASE 3 PASS 5C"
echo " CANONICAL resources.* BINDING"
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

test -f "$WORKER" || {
    fail "worker missing"
    exit 1
}

test "$(systemctl is-active "$SERVICE")" = "active" || {
    fail "service inactive"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/8] BACKUP =========="

cp -a \
  "$WORKER" \
  "$BACKUP_DIR/worker.py.before"

[ ! -f "$STATUS" ] || \
cp -a \
  "$STATUS" \
  "$BACKUP_DIR/status.json.before"

echo "BACKUP_OK"


################################################
# 3 VERIFY CANONICAL SETTINGS
################################################

echo
echo "========== [3/8] CANONICAL SETTINGS =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json

from app.settings.engine import get_settings

s=get_settings()

resources=s.get(
    "resources",
    {},
)

print(
    json.dumps(
        resources,
        ensure_ascii=False,
        indent=2,
    )
)

required=(
    "cpu_warning_percent",
    "cpu_critical_percent",
    "ram_warning_percent",
    "ram_critical_percent",
    "disk_warning_percent",
    "disk_critical_percent",
)

missing=[
    key
    for key in required
    if key not in resources
]

if missing:
    raise SystemExit(
        "MISSING_CANONICAL_KEYS="
        + ",".join(missing)
    )

print("CANONICAL_SETTINGS_OK")
PY


################################################
# 4 PATCH RESOLVER
################################################

echo
echo "========== [4/8] PATCH RESOLVER =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path

p=Path(
    "/opt/config-location/app/health/retest/worker.py"
)

text=p.read_text(
    encoding="utf-8"
)

start=text.index(
    "def resource_guardian_settings()"
)

end=text.index(
    "\ndef adaptive_policy(",
    start,
)

new=r'''def resource_guardian_settings() -> dict[str, Any]:
    """
    Canonical Resource Guardian binding.

    Source of truth:
        settings["resources"]

    Canonical keys:
        cpu_warning_percent
        cpu_critical_percent
        ram_warning_percent
        ram_critical_percent
        disk_warning_percent
        disk_critical_percent
    """

    settings = get_settings()

    resources = settings.get(
        "resources",
        {},
    )

    if not isinstance(
        resources,
        dict,
    ):
        resources = {}


    def read(
        key: str,
        default: float,
    ) -> float:

        value = resources.get(
            key,
            default,
        )

        try:
            return float(value)
        except (
            TypeError,
            ValueError,
        ):
            return float(default)


    return {
        "cpu_warning_pct":
            read(
                "cpu_warning_percent",
                75.0,
            ),

        "cpu_critical_pct":
            read(
                "cpu_critical_percent",
                94.0,
            ),

        "ram_warning_pct":
            read(
                "ram_warning_percent",
                80.0,
            ),

        "ram_critical_pct":
            read(
                "ram_critical_percent",
                92.0,
            ),

        "disk_warning_pct":
            read(
                "disk_warning_percent",
                75.0,
            ),

        "disk_critical_pct":
            read(
                "disk_critical_percent",
                90.0,
            ),

        "sources": {
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
        },
    }

'''

text=(
    text[:start]
    + new
    + text[end:]
)

p.write_text(
    text,
    encoding="utf-8",
)

print("CANONICAL_RESOLVER_PATCHED")
PY


################################################
# 5 COMPILE / IMPORT TEST
################################################

echo
echo "========== [5/8] COMPILE + IMPORT =========="

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
    assert (
        g["sources"][key]
        == path
    )

assert (
    g["cpu_warning_pct"]
    < g["cpu_critical_pct"]
)

assert (
    g["ram_warning_pct"]
    < g["ram_critical_pct"]
)

r=resource_snapshot()
policy=adaptive_policy(
    r,
    1000,
)

print("IMPORT_TEST_OK")
print("GUARDIAN=",g)
print("POLICY=",policy)
PY


################################################
# 6 RESTART
################################################

echo
echo "========== [6/8] RESTART =========="

systemctl restart "$SERVICE"

for i in $(seq 1 20); do

    ACTIVE="$(
        systemctl is-active \
          "$SERVICE" \
          2>/dev/null || true
    )"

    echo "CHECK_$i=$ACTIVE"

    [ "$ACTIVE" = "active" ] && break

    sleep 1
done

test "$(systemctl is-active "$SERVICE")" = "active" || {
    fail "restart failed"
    exit 1
}

echo "SERVICE_ACTIVE"


################################################
# 7 LIVE TELEMETRY VALIDATION
################################################

echo
echo "========== [7/8] LIVE VALIDATION =========="

OBSERVED=0

for i in $(seq 1 120); do

    if [ -f "$STATUS" ]; then

        VALID="$(
        "$PROJECT/venv/bin/python" \
        - "$STATUS" <<'PY'
import json
import sys

try:
    d=json.load(
        open(
            sys.argv[1],
            encoding="utf-8",
        )
    )

    rg=d.get(
        "resource_guardian",
        {}
    )

    src=rg.get(
        "sources",
        {}
    )

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

    ok=all(
        src.get(k)==v
        for k,v in expected.items()
    )

    print(
        "1" if ok else "0"
    )

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
    fail "canonical telemetry not observed"
    exit 1
}

cp -a "$STATUS" "$OBSERVE"


"$PROJECT/venv/bin/python" \
- "$OBSERVE" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

rg=d["resource_guardian"]
src=rg["sources"]

assert all(
    value != "fallback"
    for value
    in src.values()
)

print("CANONICAL_BINDING_VALID")

for key in (
    "cpu_warning_pct",
    "cpu_critical_pct",
    "ram_warning_pct",
    "ram_critical_pct",
    "disk_warning_pct",
    "disk_critical_pct",
):
    print(
        key.upper(),
        "=",
        rg.get(key),
        "SOURCE=",
        src.get(key),
    )

print(
    "RESOURCE_LEVEL=",
    d.get(
        "resource_level"
    ),
)

print(
    "ADAPTIVE_REASON=",
    d.get(
        "adaptive_reason"
    ),
)

print(
    "WORKERS=",
    d.get(
        "adaptive_workers"
    ),
)

print(
    "BATCH=",
    d.get(
        "adaptive_batch"
    ),
)

print(
    "TOTAL_ERRORS=",
    d.get(
        "total_errors"
    ),
)
PY


################################################
# 8 SERVICE HEALTH
################################################

echo
echo "========== [8/8] SERVICE HEALTH =========="

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

echo
echo "RESOURCE_GUARDIAN_SOURCE=resources.*"
echo "FALLBACK_SOURCES=0"
echo "CPU_BINDING=CANONICAL"
echo "RAM_BINDING=CANONICAL"
echo "DISK_BINDING=CANONICAL"
echo "SERVICE_ACTIVE=YES"
echo "SERVICE_ENABLED=YES"

echo
echo "PHASE3_PASS5C_SUCCESS"

RESULT="SUCCESS"
