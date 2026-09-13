#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
F="$R/app/country/worker.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22H5-$TS"

mkdir -p "$B"
cp -a "$F" "$B/"

echo "BACKUP=$B"

export F


echo "=== 1. PATCH ONE-TIME COUNTRY CONTRACT ==="

"$PY" <<'PY'
from pathlib import Path
import os
import ast

p=Path(os.environ["F"])
s=p.read_text()

tree=ast.parse(s)

# Replace RETRY_SECONDS completely.
start=None
end=None

for node in tree.body:
    if (
        isinstance(node, ast.Assign)
        and any(
            isinstance(t, ast.Name)
            and t.id=="RETRY_SECONDS"
            for t in node.targets
        )
    ):
        start=node.lineno-1
        end=node.end_lineno
        break

if start is None:
    raise SystemExit(
        "RETRY_SECONDS anchor missing"
    )

lines=s.splitlines(
    keepends=True
)

new='''RETRY_SECONDS={
    # Never-tested Healthy configs.
    "missing":0,

    # Country exists but needs temporal completion.
    "pending_confirmation":
        2 * 60,

    # Unresolved results retry more aggressively.
    "unknown":
        3 * 60,

    "ambiguous":
        3 * 60,

    "unstable_exit":
        3 * 60,

    "error":
        5 * 60,

    "rotating":
        5 * 60,

    # FINAL country states.
    # These must NEVER be scheduled again.
    "confirmed_stable":None,
    "confirmed_rotating_ip":None,
    "confirmed":None,
}
'''

lines[start:end]=[
    new+"\n"
]

s="".join(lines)

# Patch healthy_candidates retry handling.
old='''        retry=RETRY_SECONDS.get(
            cstate,
            30 * 60,
        )


        due=(
            last_run
            + retry
        )


        if now < due:
            continue
'''

new='''        retry=RETRY_SECONDS.get(
            cstate,
            3 * 60,
        )

        # Country is a one-time classification.
        #
        # Once a country verdict is confirmed,
        # this config_id permanently leaves the
        # Country scheduler. Periodic Health tests
        # continue independently.
        if retry is None:
            continue

        due=(
            last_run
            + retry
        )

        if now < due:
            continue
'''

if old not in s:
    raise SystemExit(
        "retry scheduling anchor missing"
    )

s=s.replace(
    old,
    new,
    1,
)

# Remove confirmed states from priority map.
s=s.replace(
'''            "confirmed_rotating_ip":5,
            "confirmed_stable":6,
''',
'',
1,
)

p.write_text(s)

print(
    "ONE_TIME_COUNTRY_PATCH=PASS"
)
PY


echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$F"

echo "COMPILE=PASS"


echo "=== 3. SEMANTICS SELFTEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.worker import (
    RETRY_SECONDS,
)

assert RETRY_SECONDS[
    "confirmed_stable"
] is None

assert RETRY_SECONDS[
    "confirmed_rotating_ip"
] is None

assert RETRY_SECONDS[
    "confirmed"
] is None

assert RETRY_SECONDS[
    "missing"
] == 0

assert RETRY_SECONDS[
    "unknown"
] > 0

assert RETRY_SECONDS[
    "unstable_exit"
] > 0

print(
    "CONFIRMED_COUNTRY_RETEST=DISABLED"
)

print(
    "UNRESOLVED_COUNTRY_RETRY=ENABLED"
)

print(
    "ONE_TIME_COUNTRY_CONTRACT=PASS"
)
PY


echo "=== 4. LIVE SCHEDULER VERIFY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from collections import Counter

from app.country.worker import (
    healthy_candidates,
    country_state,
)

rows=healthy_candidates()

states=Counter(
    country_state(cid)
    for _,cid,_,_
    in rows
)

print(
    "DUE_TOTAL=",
    len(rows),
)

print(
    "DUE_STATES=",
    dict(states),
)

assert (
    states.get(
        "confirmed_stable",
        0,
    )
    == 0
)

assert (
    states.get(
        "confirmed_rotating_ip",
        0,
    )
    == 0
)

assert (
    states.get(
        "confirmed",
        0,
    )
    == 0
)

print(
    "CONFIRMED_NOT_SCHEDULED=PASS"
)
PY


echo "=== 5. HEALTH GATE AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.worker import (
    healthy_candidates,
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

rows=healthy_candidates()

checked=0

for _,cid,_,_ in rows[:250]:

    hp=H/f"{cid}.json"

    assert hp.exists()

    o=json.loads(
        hp.read_text()
    )

    assert str(
        o.get(
            "state",
            "",
        )
    ).lower()=="healthy"

    checked+=1

print(
    "HEALTHY_GATE_CHECKED=",
    checked,
)

assert checked > 0

print(
    "COUNTRY_AFTER_HEALTH_ONLY=PASS"
)
PY


echo "=== 6. RESTART COUNTRY WORKER ==="

systemctl restart \
config-location-country-worker.service

sleep 5

ACTIVE=$(
    systemctl is-active \
    config-location-country-worker.service
)

ENABLED=$(
    systemctl is-enabled \
    config-location-country-worker.service
)

echo "ACTIVE=$ACTIVE"
echo "ENABLED=$ENABLED"

test "$ACTIVE" = active
test "$ENABLED" = enabled


echo "=== 7. SHORT REAL OBSERVATION ==="

sleep 95

journalctl \
-u config-location-country-worker.service \
--since "-2 minutes" \
--no-pager \
| tail -n 120


echo "=== 8. STABILITY ==="

RESTARTS=$(
    systemctl show \
    config-location-country-worker.service \
    -p NRestarts \
    --value
)

echo "RESTARTS=$RESTARTS"

test "$RESTARTS" -eq 0


ERRORS=$(
    journalctl \
    -u config-location-country-worker.service \
    --since "-3 minutes" \
    --no-pager \
    | grep -Ec \
    'Traceback|COUNTRY_CYCLE_ERROR|COUNTRY_CYCLE_RUNTIME_ERROR' \
    || true
)

echo "ERROR_LINES=$ERRORS"

test "$ERRORS" -eq 0


echo "=== 9. SERVICE ISOLATION ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done


echo "=== 10. SAFETY FREEZE ==="

"$PY" <<'PY'
from pathlib import Path
import json

o=json.loads(
    Path(
        "/var/lib/config-location/"
        "country/worker-safety.json"
    ).read_text()
)

assert o[
    "publication_enabled"
] is False

assert o[
    "remark_mutation_enabled"
] is False

assert o[
    "subscription_mutation_enabled"
] is False

assert o[
    "source_raw_mutation_enabled"
] is False

print(
    "SAFETY_FREEZE=PASS"
)
PY


echo "========================================"
echo "FIX22H5=PASS"
echo "COUNTRY_CLASSIFICATION=ONE_TIME_ONLY"
echo "CONFIRMED_COUNTRY_RETEST=DISABLED"
echo "HEALTH_RETEST=INDEPENDENT"
echo "HEALTHY_GATE=REQUIRED"
echo "UNRESOLVED_COUNTRY_RETRY=ENABLED"
echo "COUNTRY_PUBLICATION=DISABLED"
echo "SOURCE_RAW_UNCHANGED=YES"
echo "BACKUP=$B"
echo "========================================"
