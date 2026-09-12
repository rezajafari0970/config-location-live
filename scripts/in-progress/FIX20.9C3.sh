#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/health/core/continuous_adaptive_runner.py"
Q="$R/app/health/core/adaptive_live_queue.py"

OLD="/opt/config-location/backups/FIX20.9C2-20260901-002319"

echo "=== 1. ROLLBACK FAILED C2 ==="

test -f "$OLD/continuous_adaptive_runner.py"
test -f "$OLD/adaptive_live_queue.py"

cp -a \
"$OLD/continuous_adaptive_runner.py" \
"$F"

cp -a \
"$OLD/adaptive_live_queue.py" \
"$Q"

"$PY" -m py_compile "$F" "$Q"

echo "C2_ROLLBACK=PASS"


echo "=== 2. CREATE C3 BACKUP/STAGING ==="

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX20.9C3-$TS"
W=$(mktemp -d /tmp/fix209c3.XXXXXX)

trap 'rm -rf "$W"' EXIT

mkdir -p "$B"

cp -a "$F" "$Q" "$B/"
cp -a "$F" "$W/continuous_adaptive_runner.py"
cp -a "$Q" "$W/adaptive_live_queue.py"

export W


echo "BACKUP=$B"
echo "STAGING=$W"


echo "=== 3. PATCH STAGING ==="

"$PY" <<'PY'
from pathlib import Path
import os

W=Path(os.environ["W"])

F=W/"continuous_adaptive_runner.py"
Q=W/"adaptive_live_queue.py"


# ---------------------------------------------------------
# bounded infra retry
# ---------------------------------------------------------

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


# ---------------------------------------------------------
# first-health coverage selector
# ---------------------------------------------------------

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
    #
    # Up to 75% of each cycle may be used for
    # configs with no Health result yet.
    #
    # The remaining capacity preserves the
    # existing FIFO/retest circulation.
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

            # Preserve queue order inside the
            # uncovered class: first uncovered
            # member wins.
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


# ---------------------------------------------------------
# Replace lease calls semantically.
#
# There is one primary call and one fallback call
# with different surrounding formatting.
# ---------------------------------------------------------

primary='''                cid = lease_next(
                    state
                )
'''

if primary not in s:
    raise SystemExit(
        "primary lease anchor missing"
    )

s=s.replace(
    primary,
    '''                cid = lease_for_coverage()
''',
    1,
)


fallback='''                    cid = lease_next(
                        state
                    )
'''

if fallback not in s:
    raise SystemExit(
        "fallback lease anchor missing"
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


echo "=== 4. STAGING COMPILE ==="

"$PY" -m py_compile \
"$W/continuous_adaptive_runner.py" \
"$W/adaptive_live_queue.py"

echo "STAGING_COMPILE=PASS"


echo "=== 5. STATIC CONTRACT ==="

grep -q \
"first_health_ratio = 0.75" \
"$W/continuous_adaptive_runner.py"

grep -q \
"cid = lease_for_coverage()" \
"$W/continuous_adaptive_runner.py"

COUNT=$(
    grep -c \
    "cid = lease_for_coverage()" \
    "$W/continuous_adaptive_runner.py"
)

echo "COVERAGE_LEASE_CALLS=$COUNT"

test "$COUNT" -eq 2

grep -q \
"retry_position = min" \
"$W/adaptive_live_queue.py"

echo "STATIC_CONTRACT=PASS"


echo "=== 6. QUEUE UNIT TEST ==="

PYTHONPATH="$R" "$PY" <<PY
import importlib.util
from pathlib import Path

p=Path(
    "$W/adaptive_live_queue.py"
)

spec=importlib.util.spec_from_file_location(
    "fix209_queue",
    p,
)

m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

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

cid=m.lease_next(state)

assert cid=="a"

m.requeue_lease(
    state=state,
    config_id="a",
    still_exists=True,
)

idx=state["queue"].index("a")

print(
    "RETRY_INDEX=",
    idx,
)

assert idx > 0
assert idx <= 8

assert state["queue"][0]=="b"

print(
    "BOUNDED_RETRY=PASS"
)
PY


echo "=== 7. ATOMIC INSTALL ==="

install -m 0644 \
"$W/continuous_adaptive_runner.py" \
"$F"

install -m 0644 \
"$W/adaptive_live_queue.py" \
"$Q"

"$PY" -m py_compile "$F" "$Q"

echo "PRODUCTION_COMPILE=PASS"


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


echo "=== 9. CONTRACT VERIFY ==="

grep -n -A12 \
"first_health_ratio" \
"$F"

grep -n -A15 \
"retry_position" \
"$Q"


echo "========================================"
echo "FIX20.9C3=PASS"
echo "C2_ROLLBACK=PASS"
echo "FIRST_HEALTH_PRIORITY=75_PERCENT"
echo "NORMAL_FIFO_RESERVED=YES"
echo "INFRA_RETRY_BOUNDED=YES"
echo "XRAY_RUNTIME_UNCHANGED=YES"
echo "HEALTH_SERVICE=active"
echo "BACKUP=$B"
echo "========================================"
