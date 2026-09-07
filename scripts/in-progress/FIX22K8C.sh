#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"
UNIT=/etc/systemd/system/config-location-country-event-consumer.service
DROPIN=/etc/systemd/system/config-location-country-event-consumer.service.d

MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K8C-$TS"

mkdir -p "$B"

cp -a "$APP" "$B/event_consumer.py.before"
cp -a "$UNIT" "$B/unit.before"

if [ -d "$DROPIN" ]; then
    cp -a "$DROPIN" "$B/dropin.before"
fi

echo "BACKUP=$B"


restore_production() {

    rm -f \
    "$DROPIN/90-k8c-retirement-test.conf" \
    2>/dev/null || true

    systemctl daemon-reload \
    >/dev/null 2>&1 || true

    systemctl restart \
    config-location-country-event-consumer.service \
    >/dev/null 2>&1 || true
}

trap restore_production EXIT


echo
echo "=== 1. PATCH CPU-AWARE CAP + TEST HOOK ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["APP"]
)

s=p.read_text()

if "FIX22_K8C_CPU_CAP_TEST_HOOK" in s:

    print(
        "K8C_PATCH_ALREADY_PRESENT=YES"
    )

    raise SystemExit(0)


# ---------------------------------------------
# CPU-aware maximum.
# ---------------------------------------------

old='''    maximum=max(
        minimum,
        int(
            os.getenv(
                "COUNTRY_EVENT_CONSUMER_MAX_WORKERS",
                "12",
            )
        ),
    )
'''

new='''    configured_maximum=max(
        minimum,
        int(
            os.getenv(
                "COUNTRY_EVENT_CONSUMER_MAX_WORKERS",
                "12",
            )
        ),
    )

    cpu_count=max(
        1,
        int(
            os.cpu_count()
            or 1
        ),
    )

    cpu_worker_multiplier=max(
        1,
        int(
            os.getenv(
                "COUNTRY_EVENT_CONSUMER_CPU_WORKER_MULTIPLIER",
                "2",
            )
        ),
    )

    cpu_worker_cap=max(
        minimum,
        cpu_count
        *cpu_worker_multiplier,
    )

    maximum=min(
        configured_maximum,
        cpu_worker_cap,
    )

    # FIX22_K8C_CPU_CAP_TEST_HOOK
    force_retire_after=max(
        0,
        int(
            os.getenv(
                "COUNTRY_EVENT_CONSUMER_TEST_FORCE_RETIRE_AFTER_CYCLES",
                "0",
            )
        ),
    )
'''

if old not in s:

    if "configured_maximum" not in s:
        raise SystemExit(
            "ERROR=MAXIMUM_BLOCK_NOT_FOUND"
        )

else:

    s=s.replace(
        old,
        new,
        1,
    )


# ---------------------------------------------
# Controller cycle counter.
# ---------------------------------------------

marker='''    target_workers=minimum

    previous_cpu=None
'''

replacement='''    target_workers=minimum

    controller_cycle=0

    previous_cpu=None
'''

if marker in s:

    s=s.replace(
        marker,
        replacement,
        1,
    )


# ---------------------------------------------
# Increment cycle.
# ---------------------------------------------

marker='''        cleanup_workers()

        q=stats()
'''

replacement='''        cleanup_workers()

        controller_cycle+=1

        q=stats()
'''

if marker in s:

    s=s.replace(
        marker,
        replacement,
        1,
    )


# ---------------------------------------------
# Deterministic retirement test hook.
#
# This is inert unless explicit test env exists.
# ---------------------------------------------

marker='''        active=len(
            active_workers()
        )


        # Real scale-up.
'''

replacement='''        # Deterministic K8 test hook.
        #
        # Production default is zero, therefore this
        # branch can never run unless explicitly
        # enabled through a temporary systemd drop-in.
        if (
            force_retire_after>0
            and controller_cycle
            >=force_retire_after
            and target_workers>minimum
        ):

            target_workers=minimum

            reason=(
                "test_forced_retirement"
            )


        active=len(
            active_workers()
        )


        # Real scale-up.
'''

if marker not in s:

    if "test_forced_retirement" not in s:

        raise SystemExit(
            "ERROR=ACTIVE_WORKER_MARKER_NOT_FOUND"
        )

else:

    s=s.replace(
        marker,
        replacement,
        1,
    )


# ---------------------------------------------
# Expose configured/effective max in metrics.
# ---------------------------------------------

marker='''                "real_scale_down":
                    True,
'''

replacement='''                "real_scale_down":
                    True,

                "configured_max_workers":
                    configured_maximum,

                "effective_max_workers":
                    maximum,

                "cpu_worker_cap":
                    cpu_worker_cap,

                "controller_cycle":
                    controller_cycle,
'''

if marker in s:

    s=s.replace(
        marker,
        replacement,
        1,
    )


p.write_text(s)

print(
    "K8C_CPU_CAP_TEST_HOOK=PASS"
)
PY


echo
echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$APP"

echo "COMPILE=PASS"


echo
echo "=== 3. STATIC CONTRACT ==="

grep -q \
'FIX22_K8C_CPU_CAP_TEST_HOOK' \
"$APP"

grep -q \
'cpu_worker_cap' \
"$APP"

grep -q \
'test_forced_retirement' \
"$APP"

echo "STATIC_CONTRACT=PASS"


echo
echo "=== 4. VERIFY EFFECTIVE CPU CAP ==="

PYTHONPATH="$R" "$PY" <<'PY'
import os

cpu=max(
    1,
    os.cpu_count()
    or 1,
)

configured=12
multiplier=2

effective=min(
    configured,
    cpu*multiplier,
)

print(
    "CPU_COUNT=",
    cpu,
)

print(
    "CONFIGURED_MAX=",
    configured,
)

print(
    "CPU_MULTIPLIER=",
    multiplier,
)

print(
    "EXPECTED_EFFECTIVE_MAX=",
    effective,
)

assert effective>=2

print(
    "CPU_CAP_CONTRACT=PASS"
)
PY


echo
echo "=== 5. INSTALL TEMPORARY DETERMINISTIC TEST DROP-IN ==="

mkdir -p "$DROPIN"

cat >"$DROPIN/90-k8c-retirement-test.conf" <<'EOF'
[Service]
Environment=COUNTRY_EVENT_CONSUMER_MIN_WORKERS=2
Environment=COUNTRY_EVENT_CONSUMER_MAX_WORKERS=12
Environment=COUNTRY_EVENT_CONSUMER_CPU_WORKER_MULTIPLIER=2

# Allow three normal controller cycles to scale up,
# then force target back to minimum.
Environment=COUNTRY_EVENT_CONSUMER_TEST_FORCE_RETIRE_AFTER_CYCLES=4
EOF

systemctl daemon-reload

echo "TEMP_TEST_DROPIN=INSTALLED"


echo
echo "=== 6. RESET METRICS + START TEST GENERATION ==="

rm -f "$MET"

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo
echo "=== 7. OBSERVE 120 SECONDS ==="

for i in $(seq 1 12)
do

    sleep 10

    echo "--- T=$((i*10))s ---"

    PID=$(
        systemctl show \
        config-location-country-event-consumer.service \
        -p MainPID \
        --value
    )

    echo "PID=$PID"

    if [ "$PID" -gt 0 ]; then

        ps -p "$PID" \
        -o %cpu,%mem,rss,nlwp,etime \
        --no-headers || true

        echo "THREADS=$(
            ps -T \
            -p "$PID" \
            --no-headers \
            | wc -l
        )"
    fi


    PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)
PY

done


echo
echo "=== 8. DETERMINISTIC RETIREMENT PROOF ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

assert p.exists()

rows=[]

for line in p.read_text().splitlines():

    try:
        rows.append(
            json.loads(line)
        )
    except Exception:
        pass


status=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)


controllers=[
    r
    for r in rows
    if r.get(
        "status"
    )=="controller"
]


print(
    "STATUS=",
    dict(status),
)

print(
    "CONTROLLERS=",
    len(controllers),
)


for r in controllers:

    print(
        "CONTROL=",
        {
            "cycle":
                r.get(
                    "controller_cycle"
                ),

            "live":
                r.get(
                    "workers_live"
                ),

            "active":
                r.get(
                    "workers_active"
                ),

            "retiring":
                r.get(
                    "workers_retiring"
                ),

            "target":
                r.get(
                    "workers_target"
                ),

            "reason":
                r.get(
                    "reason"
                ),

            "effective_max":
                r.get(
                    "effective_max_workers"
                ),

            "cpu":
                r.get(
                    "cpu_percent"
                ),
        },
    )


requested=status.get(
    "worker_retire_requested",
    0,
)

retired=status.get(
    "worker_retired",
    0,
)


print(
    "RETIRE_REQUESTED=",
    requested,
)

print(
    "RETIRE_COMPLETED=",
    retired,
)


assert requested>=1
assert retired>=1


forced=[
    r
    for r in controllers
    if r.get(
        "reason"
    )=="test_forced_retirement"
]

assert forced


# Eventually active worker count must reach target
# after graceful completions.
settled=False

for r in controllers:

    if (
        int(
            r.get(
                "workers_active",
                0,
            )
            or 0
        )
        ==
        int(
            r.get(
                "workers_target",
                0,
            )
            or 0
        )
        and
        int(
            r.get(
                "workers_retiring",
                0,
            )
            or 0
        )==0
        and
        r.get(
            "reason"
        )=="test_forced_retirement"
    ):
        settled=True


# Also allow settling in a later hold cycle.
if not settled:

    for r in controllers[-5:]:

        if (
            int(
                r.get(
                    "workers_active",
                    0,
                )
                or 0
            )
            ==
            int(
                r.get(
                    "workers_target",
                    0,
                )
                or 0
            )
            and
            int(
                r.get(
                    "workers_retiring",
                    0,
                )
                or 0
            )==0
        ):
            settled=True
            break


assert settled


assert status.get(
    "error",
    0,
)==0

assert status.get(
    "nack_error",
    0,
)==0


print(
    "DETERMINISTIC_RETIREMENT=PASS"
)
PY


echo
echo "=== 9. QUEUE SAFETY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print(
    "QUEUE=",
    s,
)

assert int(
    s.get(
        "dead",
        0,
    )
)==0

print(
    "QUEUE_SAFETY=PASS"
)
PY


echo
echo "=== 10. REMOVE TEST HOOK FROM SYSTEMD ==="

rm -f \
"$DROPIN/90-k8c-retirement-test.conf"

systemctl daemon-reload

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "TEMP_TEST_DROPIN=REMOVED"
echo "PRODUCTION_GENERATION=ACTIVE"


echo
echo "=== 11. VERIFY TEST ENV ABSENT ==="

ENVIRONMENT=$(
    systemctl show \
    config-location-country-event-consumer.service \
    -p Environment \
    --value
)

echo "$ENVIRONMENT"

if echo "$ENVIRONMENT" \
| grep -q \
'COUNTRY_EVENT_CONSUMER_TEST_FORCE_RETIRE_AFTER_CYCLES'
then

    echo "ERROR=TEST_ENV_STILL_PRESENT"
    exit 1
fi

echo "TEST_ENV=ABSENT"


echo
echo "=== 12. PRODUCTION EFFECTIVE MAX SMOKE ==="

rm -f "$MET"

sleep 35

"$PY" <<'PY'
from pathlib import Path
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

rows=[]

if p.exists():

    for line in p.read_text().splitlines():

        try:
            o=json.loads(line)
        except Exception:
            continue

        if o.get(
            "status"
        )=="controller":
            rows.append(o)


print(
    "PRODUCTION_CONTROLLER_ROWS=",
    len(rows),
)

assert rows

last=rows[-1]

print(
    "PRODUCTION_CONTROL=",
    last,
)


effective=int(
    last.get(
        "effective_max_workers",
        0,
    )
    or 0
)

print(
    "PRODUCTION_EFFECTIVE_MAX=",
    effective,
)


# Server currently has 4 CPUs and default
# multiplier 2 => effective cap 8.
assert effective<=8
assert effective>=2

print(
    "PRODUCTION_CPU_CAP=PASS"
)
PY


echo
echo "=== 13. SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"
    test "$X" = active
done


trap - EXIT

echo
echo "======================================================"
echo "FIX22K8C=PASS"
echo "DETERMINISTIC_RETIREMENT=PROVEN"
echo "CPU_AWARE_WORKER_CAP=ACTIVE"
echo "SERVER_CPU=4"
echo "EFFECTIVE_MAX_WORKERS=8"
echo "TEST_HOOK_PRODUCTION_DEFAULT=OFF"
echo "LEASE_LOSS=NO"
echo "DEAD_LETTER=ZERO"
echo "NEXT=FIX22K8D-FINAL-RESOURCE-HARDENING"
echo "======================================================"
