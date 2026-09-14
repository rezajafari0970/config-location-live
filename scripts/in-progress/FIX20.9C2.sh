#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/health/core/continuous_adaptive_runner.py"
Q="$R/app/health/core/adaptive_live_queue.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX20.9C2-$TS"

mkdir -p "$B"

cp -a "$F" "$Q" "$B/"

echo "BACKUP=$B"

export F Q

"$PY" <<'PY'
from pathlib import Path
import os

F=Path(os.environ["F"])
Q=Path(os.environ["Q"])


# =========================================================
# 1. adaptive_live_queue.py
#
# infra retry must remain fast but may not permanently
# monopolize queue[0].
# =========================================================

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
        # retried soon, but must not permanently
        # monopolize queue[0].
        #
        # Keep a small fairness window ahead of
        # the retry so first-health / normal FIFO
        # work continues to make progress.
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
        "requeue anchor not found"
    )

s=s.replace(
    old,
    new,
    1,
)

Q.write_text(s)


# =========================================================
# 2. continuous_adaptive_runner.py
#
# Add bounded first-health selector.
# =========================================================

s=F.read_text()

anchor='''    result_store = (
        JsonHealthResultStore(
            result_root
        )
    )

    active = {}
'''

replacement='''    result_store = (
        JsonHealthResultStore(
            result_root
        )
    )

    # FIX20.9:
    # Reserve a bounded portion of every cycle
    # for configs that have never received a
    # Health result.
    #
    # This prevents a live Fetch stream from
    # waiting for an entire multi-thousand-item
    # retest rotation.
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
        """
        Prefer an uncovered config while the
        bounded first-health budget remains.

        Existing FIFO order is preserved within
        both covered and uncovered classes.
        """

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
        "result_store anchor not found"
    )

s=s.replace(
    anchor,
    replacement,
    1,
)


# Replace only the two refill lease calls.
old='''                cid = lease_next(
                    state
                )
'''

new='''                cid = lease_for_coverage()
'''

count=s.count(old)

if count < 2:
    raise SystemExit(
        f"expected >=2 lease anchors, got {count}"
    )

s=s.replace(
    old,
    new,
    2,
)

F.write_text(s)

print(
    "PATCH_APPLIED=YES"
)
PY


echo "=== COMPILE ==="

"$PY" -m py_compile \
"$F" \
"$Q"

echo "PY_COMPILE=PASS"


echo "=== STATIC CONTRACT ==="

grep -n \
-B8 -A90 \
"first_health_ratio" \
"$F"

grep -n \
-B8 -A35 \
"retry_position" \
"$Q"


echo "=== QUEUE SELFTEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.health.core.adaptive_live_queue import (
    lease_next,
    requeue_lease,
)

state={
    "version":3,
    "generation":1,
    "queue":[
        "a","b","c","d",
        "e","f","g","h",
        "i","j",
    ],
    "leases":[],
}

cid=lease_next(state)

assert cid=="a"

requeue_lease(
    state=state,
    config_id="a",
    still_exists=True,
)

print(
    "QUEUE_AFTER_RETRY=",
    state["queue"],
)

assert (
    state["queue"][0]
    == "b"
)

assert (
    state["queue"].index("a")
    > 0
)

print(
    "BOUNDED_RETRY=PASS"
)
PY


echo "=== RESTART HEALTH SERVICE ==="

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


echo "========================================"
echo "FIX20.9C2=PASS"
echo "FIRST_HEALTH_PRIORITY=75_PERCENT"
echo "NORMAL_FIFO_CAPACITY=25_PERCENT_MINIMUM"
echo "INFRA_RETRY_BOUNDED=PASS"
echo "XRAY_RUNTIME_UNCHANGED=YES"
echo "HEALTH_SERVICE=active"
echo "BACKUP=$B"
echo "========================================"
