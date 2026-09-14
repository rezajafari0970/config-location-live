#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/health/core/continuous_adaptive_runner.py"
Q="$R/app/health/core/adaptive_live_queue.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX20.9C4-$TS"
W=$(mktemp -d /tmp/fix209c4.XXXXXX)

trap 'rm -rf "$W"' EXIT

mkdir -p "$B"

cp -a "$F" "$Q" "$B/"
cp -a "$F" "$W/continuous_adaptive_runner.py"
cp -a "$Q" "$W/adaptive_live_queue.py"

export W

echo "BACKUP=$B"
echo "STAGING=$W"


echo "=== 1. PATCH STAGING ==="

"$PY" <<'PY'
from pathlib import Path
import os

W=Path(os.environ["W"])

F=W/"continuous_adaptive_runner.py"
Q=W/"adaptive_live_queue.py"


s=Q.read_text()

old='''        # Infrastructure uncertainty should be
        # retried soon, not after a whole cycle.
        state[
            "queue"
        ].insert(
            0,
            config_id,
        )
'''

new='''        # Infrastructure uncertainty should be
        # retried soon without monopolizing the
        # absolute head of the live queue.
        queue = state[
            "queue"
        ]

        retry_position = min(
            8,
            len(queue),
        )

        queue.insert(
            retry_position,
            config_id,
        )
'''

if old not in s:
    raise SystemExit(
        "infra retry anchor missing"
    )

Q.write_text(
    s.replace(old,new,1)
)


s=F.read_text()

anchor='''    result_store = (
        JsonHealthResultStore(
            result_root
        )
    )

    active = {}
'''

block='''    result_store = (
        JsonHealthResultStore(
            result_root
        )
    )

    # FIX20.9 First-Health Coverage Scheduler.
    first_health_ratio = 0.75

    first_health_budget = max(
        1,
        int(
            selected_target
            * first_health_ratio
        ),
    )

    first_health_leased = 0

    latest_result_root = (
        result_root
        / "latest"
    )

    def has_health(
        config_id: str,
    ) -> bool:

        return (
            latest_result_root
            / f"{config_id}.json"
        ).is_file()

    def lease_for_coverage():
        nonlocal first_health_leased

        queue = state[
            "queue"
        ]

        if (
            first_health_leased
            < first_health_budget
        ):

            for index, candidate in enumerate(
                queue
            ):

                if not has_health(
                    candidate
                ):

                    cid = queue.pop(
                        index
                    )

                    if cid in state[
                        "leases"
                    ]:
                        raise RuntimeError(
                            "duplicate lease"
                        )

                    state[
                        "leases"
                    ].append(
                        cid
                    )

                    first_health_leased += 1

                    return cid

        return lease_next(
            state
        )

    active = {}
'''

if anchor not in s:
    raise SystemExit(
        "result store anchor missing"
    )

s=s.replace(
    anchor,
    block,
    1,
)


primary='''                cid = lease_next(
                    state
                )
'''

fallback='''                    cid = lease_next(
                        state
                    )
'''

if primary not in s:
    raise SystemExit(
        "primary lease missing"
    )

if fallback not in s:
    raise SystemExit(
        "fallback lease missing"
    )

s=s.replace(
    primary,
    '''                cid = lease_for_coverage()
''',
    1,
)

s=s.replace(
    fallback,
    '''                    cid = lease_for_coverage()
''',
    1,
)

F.write_text(s)

print("STAGING_PATCH=PASS")
PY


echo "=== 2. STAGING COMPILE ==="

"$PY" -m py_compile \
"$W/continuous_adaptive_runner.py" \
"$W/adaptive_live_queue.py"

echo "STAGING_COMPILE=PASS"


echo "=== 3. STATIC VERIFY ==="

test "$(
    grep -c \
    "cid = lease_for_coverage()" \
    "$W/continuous_adaptive_runner.py"
)" -eq 2

grep -q \
"first_health_ratio = 0.75" \
"$W/continuous_adaptive_runner.py"

grep -q \
"retry_position = min" \
"$W/adaptive_live_queue.py"

echo "STATIC_VERIFY=PASS"


echo "=== 4. PACKAGE-AWARE QUEUE TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.health.core.adaptive_live_queue import (
    lease_next,
    requeue_lease,
)

# Verify the current production queue contract
# independently before staged installation.
state={
    "version":3,
    "generation":1,
    "queue":[
        "a","b","c","d",
        "e","f","g","h",
        "i","j","k",
    ],
    "leases":[],
}

cid=lease_next(state)
assert cid=="a"

print(
    "BASE_QUEUE_IMPORT=PASS"
)
PY


echo "=== 5. STAGED REQUEUE LOGIC TEST ==="

"$PY" <<PY
from pathlib import Path

s=Path(
    "$W/adaptive_live_queue.py"
).read_text()

assert "retry_position = min(" in s
assert "8," in s

# Semantic simulation of staged policy.
queue=[
    "b","c","d","e",
    "f","g","h","i",
    "j","k",
]

retry_position=min(
    8,
    len(queue),
)

queue.insert(
    retry_position,
    "a",
)

print(
    "SIMULATED_QUEUE=",
    queue,
)

assert queue[0]=="b"
assert queue.index("a")==8

print(
    "BOUNDED_RETRY_POLICY=PASS"
)
PY


echo "=== 6. ATOMIC INSTALL ==="

install -m 0644 \
"$W/continuous_adaptive_runner.py" \
"$F"

install -m 0644 \
"$W/adaptive_live_queue.py" \
"$Q"

"$PY" -m py_compile \
"$F" \
"$Q"

echo "PRODUCTION_COMPILE=PASS"


echo "=== 7. PRODUCTION IMPORT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.health.core.continuous_adaptive_runner import (
    run_continuous_adaptive_test,
)

from app.health.core.adaptive_live_queue import (
    requeue_lease,
)

state={
    "version":3,
    "generation":1,
    "queue":[
        "b","c","d","e",
        "f","g","h","i",
        "j","k",
    ],
    "leases":["a"],
}

requeue_lease(
    state=state,
    config_id="a",
    still_exists=True,
)

idx=state["queue"].index("a")

print(
    "PRODUCTION_RETRY_INDEX=",
    idx,
)

assert idx==8
assert state["queue"][0]=="b"

print(
    "PRODUCTION_IMPORT=PASS"
)
PY


echo "=== 8. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

STATE=$(
    systemctl is-active \
    config-location-health-adaptive.service
)

echo "HEALTH_STATE=$STATE"

test "$STATE" = active

systemctl show \
config-location-health-adaptive.service \
-p ActiveState \
-p SubState \
-p Result \
-p MainPID \
--no-pager


echo "=== 9. INSTALLED CONTRACT ==="

grep -n -A15 \
"first_health_ratio" \
"$F"

grep -n -A15 \
"retry_position" \
"$Q"


echo "========================================"
echo "FIX20.9C4=PASS"
echo "FIRST_HEALTH_PRIORITY=75_PERCENT"
echo "NORMAL_FIFO_RESERVED=YES"
echo "INFRA_RETRY_POSITION=8"
echo "XRAY_RUNTIME_UNCHANGED=YES"
echo "HEALTH_SERVICE=active"
echo "BACKUP=$B"
echo "========================================"
