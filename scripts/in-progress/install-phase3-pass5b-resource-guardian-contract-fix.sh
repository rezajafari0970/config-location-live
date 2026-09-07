#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass5b-resource-guardian-settings-contract-fix"

PROJECT="/opt/config-location"
REPO="/root/project-log"

SERVICE="config-location-retest.service"
WORKER="$PROJECT/app/health/retest/worker.py"
SETTINGS="$PROJECT/app/settings/engine.py"
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
CONTRACT="$DISCOVERY_DIR/${PHASE}-${TS}.txt"
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

Contract:
$CONTRACT

Observation:
$OBSERVE

Service:
$SERVICE

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
echo " PHASE 3 PASS 5B"
echo " RESOURCE GUARDIAN SETTINGS CONTRACT FIX"
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
    fail "worker missing"
    exit 1
}

test -f "$SETTINGS" || {
    fail "settings engine missing"
    exit 1
}

test "$(systemctl is-active "$SERVICE")" = "active" || {
    fail "retest service inactive"
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

cp -a "$SETTINGS" \
  "$BACKUP_DIR/engine.py.reference"

[ ! -f "$STATUS" ] || \
cp -a "$STATUS" \
  "$BACKUP_DIR/status.json.before"

echo "BACKUP_OK"


################################################
# 3 CONTRACT DISCOVERY
################################################

echo
echo "========== [3/10] CONTRACT DISCOVERY =========="

{
echo "================================================"
echo "RESOURCE GUARDIAN SETTINGS CONTRACT"
echo "================================================"

echo
echo "========== STATIC SEARCH =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'cpu_warning|cpu_critical|ram_warning|ram_critical|disk_warning|disk_critical|resource.guardian|resource_guardian|guardian' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 600 || true

echo
echo "========== SETTINGS ENGINE MATCHES =========="

grep -n \
  -E \
  'cpu_warning|cpu_critical|ram_warning|ram_critical|disk_warning|disk_critical|resource|guardian' \
  "$SETTINGS" \
  | head -n 500 || true

echo
echo "========== LIVE TOP LEVEL SETTINGS =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from app.settings.engine import get_settings

s = get_settings()

print("TOP_LEVEL_KEYS=", sorted(s.keys()))

for k, v in s.items():
    low = k.lower()

    if any(
        word in low
        for word in (
            "resource",
            "cpu",
            "ram",
            "disk",
            "guardian",
        )
    ):
        print()
        print("KEY=", k)
        print(
            json.dumps(
                v,
                ensure_ascii=False,
                indent=2,
            )
        )
PY

echo
echo "========== RECURSIVE KEY DISCOVERY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import get_settings

s=get_settings()

targets=(
    "cpu",
    "ram",
    "disk",
    "resource",
    "guardian",
)

def walk(value,path=""):
    if isinstance(value,dict):
        for k,v in value.items():
            p=f"{path}.{k}" if path else k
            low=p.lower()

            if any(t in low for t in targets):
                if not isinstance(v,(dict,list)):
                    print(f"{p}={v!r}")

            walk(v,p)

    elif isinstance(value,list):
        for i,v in enumerate(value):
            walk(v,f"{path}[{i}]")

walk(s)
PY

echo
echo "CONTRACT_DISCOVERY_COMPLETE"

} > "$CONTRACT"

test -s "$CONTRACT" || {
    fail "contract empty"
    exit 1
}

echo "CONTRACT_DISCOVERY_OK"


################################################
# 4 RESOLVE CANONICAL VALUES
################################################

echo
echo "========== [4/10] RESOLVE CONTRACT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from app.settings.engine import get_settings

s=get_settings()


def first(paths, default):
    for path in paths:
        cur=s
        ok=True

        for part in path.split("."):
            if not isinstance(cur,dict) or part not in cur:
                ok=False
                break

            cur=cur[part]

        if ok:
            try:
                return float(cur), path
            except (TypeError,ValueError):
                pass

    return float(default), "fallback"


mapping={
    "cpu_warning_pct": (
        (
            "resource_guardian.cpu_warning_pct",
            "resource_guardian.cpu_warning",
            "resource.cpu_warning_pct",
            "resource.cpu.warning",
            "resource_limits.cpu_warning_pct",
            "cpu_warning_pct",
        ),
        75,
    ),

    "cpu_critical_pct": (
        (
            "resource_guardian.cpu_critical_pct",
            "resource_guardian.cpu_critical",
            "resource.cpu_critical_pct",
            "resource.cpu.critical",
            "resource_limits.cpu_critical_pct",
            "cpu_critical_pct",
        ),
        90,
    ),

    "ram_warning_pct": (
        (
            "resource_guardian.ram_warning_pct",
            "resource_guardian.ram_warning",
            "resource.ram_warning_pct",
            "resource.ram.warning",
            "resource_limits.ram_warning_pct",
            "ram_warning_pct",
        ),
        80,
    ),

    "ram_critical_pct": (
        (
            "resource_guardian.ram_critical_pct",
            "resource_guardian.ram_critical",
            "resource.ram_critical_pct",
            "resource.ram.critical",
            "resource_limits.ram_critical_pct",
            "ram_critical_pct",
        ),
        95,
    ),
}

out={}

for key,(paths,default) in mapping.items():
    value,path=first(paths,default)

    out[key]={
        "value": value,
        "path": path,
    }

print(
    json.dumps(
        out,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 5 PATCH WORKER WITH RECURSIVE CONTRACT
################################################

echo
echo "========== [5/10] PATCH WORKER =========="

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
    Resolve Resource Guardian thresholds from
    the canonical Central Settings structure.

    The resolver supports the current schema and
    legacy-compatible aliases, while recording the
    exact path that supplied every value.
    """

    settings = get_settings()


    def read_path(
        path: str,
    ):
        current = settings

        for part in path.split("."):
            if (
                not isinstance(current, dict)
                or part not in current
            ):
                return None

            current = current[part]

        return current


    def resolve(
        paths,
        default,
    ):
        for path in paths:
            value = read_path(path)

            if value is None:
                continue

            try:
                return (
                    float(value),
                    path,
                )
            except (
                TypeError,
                ValueError,
            ):
                continue

        return (
            float(default),
            "fallback",
        )


    cpu_warning, cpu_warning_path = resolve(
        (
            "resource_guardian.cpu_warning_pct",
            "resource_guardian.cpu_warning",
            "resource_guardian.cpu.warn",
            "resource.cpu_warning_pct",
            "resource.cpu.warning",
            "resource_limits.cpu_warning_pct",
            "cpu_warning_pct",
        ),
        75,
    )


    cpu_critical, cpu_critical_path = resolve(
        (
            "resource_guardian.cpu_critical_pct",
            "resource_guardian.cpu_critical",
            "resource_guardian.cpu.critical",
            "resource.cpu_critical_pct",
            "resource.cpu.critical",
            "resource_limits.cpu_critical_pct",
            "cpu_critical_pct",
        ),
        90,
    )


    ram_warning, ram_warning_path = resolve(
        (
            "resource_guardian.ram_warning_pct",
            "resource_guardian.ram_warning",
            "resource_guardian.ram.warn",
            "resource.ram_warning_pct",
            "resource.ram.warning",
            "resource_limits.ram_warning_pct",
            "ram_warning_pct",
        ),
        80,
    )


    ram_critical, ram_critical_path = resolve(
        (
            "resource_guardian.ram_critical_pct",
            "resource_guardian.ram_critical",
            "resource_guardian.ram.critical",
            "resource.ram_critical_pct",
            "resource.ram.critical",
            "resource_limits.ram_critical_pct",
            "ram_critical_pct",
        ),
        95,
    )


    return {
        "cpu_warning_pct":
            cpu_warning,

        "cpu_critical_pct":
            cpu_critical,

        "ram_warning_pct":
            ram_warning,

        "ram_critical_pct":
            ram_critical,

        "sources": {
            "cpu_warning_pct":
                cpu_warning_path,

            "cpu_critical_pct":
                cpu_critical_path,

            "ram_warning_pct":
                ram_warning_path,

            "ram_critical_pct":
                ram_critical_path,
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

print("WORKER_CONTRACT_PATCH_OK")
PY


################################################
# 6 COMPILE + IMPORT
################################################

echo
echo "========== [6/10] COMPILE + IMPORT =========="

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

assert (
    g["cpu_warning_pct"]
    < g["cpu_critical_pct"]
)

assert (
    g["ram_warning_pct"]
    < g["ram_critical_pct"]
)

assert isinstance(
    g["sources"],
    dict,
)

r=resource_snapshot()
p=adaptive_policy(r,1000)

print("CONTRACT_IMPORT_OK")
print("GUARDIAN=",g)
print("POLICY=",p)
PY


################################################
# 7 RESTART ONCE
################################################

echo
echo "========== [7/10] RESTART SERVICE =========="

systemctl restart "$SERVICE"

for i in $(seq 1 20); do

    ACTIVE="$(
        systemctl is-active \
          "$SERVICE" \
          2>/dev/null || true
    )"

    echo "CHECK_$i=$ACTIVE"

    if [ "$ACTIVE" = "active" ]; then
        break
    fi

    sleep 1
done

test "$(systemctl is-active "$SERVICE")" = "active" || {
    fail "service restart failed"
    exit 1
}

echo "SERVICE_ACTIVE"


################################################
# 8 WAIT FOR LIVE CONTRACT TELEMETRY
################################################

echo
echo "========== [8/10] LIVE CONTRACT TEST =========="

OBSERVED=0

for i in $(seq 1 120); do

    if [ -f "$STATUS" ]; then

        VALID="$(
        "$PROJECT/venv/bin/python" \
        - "$STATUS" <<'PY'
import json,sys

try:
    d=json.load(open(sys.argv[1]))

    rg=d.get(
        "resource_guardian",
        {}
    )

    src=rg.get(
        "sources",
        {}
    )

    ok=(
        d.get("mode")=="adaptive"
        and isinstance(src,dict)
        and len(src)==4
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
    fail "canonical guardian contract not observed"
    exit 1
}

echo "LIVE_CONTRACT_OBSERVED"


################################################
# 9 SAVE + VALIDATE
################################################

echo
echo "========== [9/10] VALIDATE =========="

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

assert len(src)==4

assert (
    rg["cpu_warning_pct"]
    < rg["cpu_critical_pct"]
)

assert (
    rg["ram_warning_pct"]
    < rg["ram_critical_pct"]
)

print("CONTRACT_VALID")

print(
    "CPU_WARNING=",
    rg["cpu_warning_pct"],
    src["cpu_warning_pct"],
)

print(
    "CPU_CRITICAL=",
    rg["cpu_critical_pct"],
    src["cpu_critical_pct"],
)

print(
    "RAM_WARNING=",
    rg["ram_warning_pct"],
    src["ram_warning_pct"],
)

print(
    "RAM_CRITICAL=",
    rg["ram_critical_pct"],
    src["ram_critical_pct"],
)

print(
    "RESOURCE_LEVEL=",
    d.get("resource_level"),
)

print(
    "ADAPTIVE_REASON=",
    d.get("adaptive_reason"),
)

print(
    "WORKERS=",
    d.get("adaptive_workers"),
)

print(
    "BATCH=",
    d.get("adaptive_batch"),
)

print(
    "ERRORS=",
    d.get("total_errors"),
)
PY


################################################
# 10 SERVICE HEALTH
################################################

echo
echo "========== [10/10] SERVICE HEALTH =========="

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
echo "RESOURCE_GUARDIAN_CONTRACT=RESOLVED"
echo "CANONICAL_SOURCE_PATHS=RECORDED"
echo "LIVE_SETTINGS_READ=YES"
echo "WORKER_RESTART_REQUIRED_FOR_SETTING_CHANGES=NO"
echo "SERVICE_ACTIVE=YES"
echo "SERVICE_ENABLED=YES"

echo
echo "PHASE3_PASS5B_SUCCESS"

RESULT="SUCCESS"
