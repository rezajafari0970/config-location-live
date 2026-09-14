#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

M="$R/app/country"

BIN="$R/bin/country-shadow-daemon"

UNIT=/etc/systemd/system/config-location-country-worker.service

D=/var/lib/config-location/country/worker

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22H1C-$TS"

mkdir -p "$B" "$D"

if [ -f "$UNIT" ]; then
    cp -a "$UNIT" "$B/"
fi

if [ -f "$BIN" ]; then
    cp -a "$BIN" "$B/"
fi

echo "BACKUP=$B"


echo "=== 1. CREATE DAEMON MODULE ==="

cat >"$M/daemon.py" <<'PY'
from __future__ import annotations

import os
import signal
import time
import traceback

from datetime import datetime, timezone

from .worker import (
    run_country_worker_once,
)


STOP=False


def utc_now() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def handle_signal(
    signum,
    frame,
):
    global STOP

    STOP=True

    print(
        "COUNTRY_DAEMON_SIGNAL",
        signum,
        flush=True,
    )


def env_int(
    name: str,
    default: int,
    *,
    minimum: int,
    maximum: int,
) -> int:

    raw=os.environ.get(
        name,
        str(default),
    )

    try:
        value=int(raw)
    except Exception:
        value=default

    return max(
        minimum,
        min(
            maximum,
            value,
        ),
    )


def main() -> int:

    signal.signal(
        signal.SIGTERM,
        handle_signal,
    )

    signal.signal(
        signal.SIGINT,
        handle_signal,
    )


    max_jobs=env_int(
        "COUNTRY_MAX_JOBS_PER_CYCLE",
        3,
        minimum=1,
        maximum=10,
    )

    interval=env_int(
        "COUNTRY_CYCLE_INTERVAL",
        45,
        minimum=15,
        maximum=3600,
    )


    print(
        "COUNTRY_SHADOW_DAEMON_START",
        "max_jobs=",
        max_jobs,
        "interval=",
        interval,
        "mode=shadow",
        flush=True,
    )


    cycle=0


    while not STOP:

        cycle += 1

        started=time.monotonic()


        try:

            report=run_country_worker_once(
                max_jobs=max_jobs
            )


            print(
                "COUNTRY_CYCLE",
                cycle,
                "time=",
                utc_now(),
                "eligible=",
                report.get(
                    "eligible_due"
                ),
                "selected=",
                report.get(
                    "selected"
                ),
                "processed=",
                report.get(
                    "processed"
                ),
                "states=",
                report.get(
                    "states"
                ),
                flush=True,
            )


        except RuntimeError as e:

            # A second Country worker must never
            # fight with the active owner.
            if str(e)==(
                "country_worker_already_running"
            ):

                print(
                    "COUNTRY_CYCLE_LOCKED",
                    cycle,
                    flush=True,
                )

            else:

                print(
                    "COUNTRY_CYCLE_RUNTIME_ERROR",
                    cycle,
                    repr(e),
                    flush=True,
                )


        except Exception as e:

            # Country failure must never terminate
            # Fetcher or Health services.
            print(
                "COUNTRY_CYCLE_ERROR",
                cycle,
                type(e).__name__,
                str(e)[:500],
                flush=True,
            )

            traceback.print_exc()


        elapsed=(
            time.monotonic()
            - started
        )


        remaining=max(
            0.0,
            interval-elapsed,
        )


        # Sleep interruptibly so systemd stop
        # does not have to wait a whole interval.
        end=time.monotonic()+remaining

        while (
            not STOP
            and time.monotonic()<end
        ):
            time.sleep(
                min(
                    1.0,
                    end-time.monotonic(),
                )
            )


    print(
        "COUNTRY_SHADOW_DAEMON_STOP",
        "cycles=",
        cycle,
        flush=True,
    )

    return 0


if __name__=="__main__":
    raise SystemExit(
        main()
    )
PY


echo "=== 2. COMPILE ==="

"$PY" -m py_compile \
"$M/daemon.py" \
"$M/worker.py" \
"$M/pipeline.py"

echo "COMPILE=PASS"


echo "=== 3. CREATE WRAPPER ==="

cat >"$BIN" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

export PYTHONPATH=/opt/config-location
export PYTHONUNBUFFERED=1

exec /opt/config-location/venv/bin/python \
-m app.country.daemon
SH

chmod 0755 "$BIN"

echo "WRAPPER=PASS"


echo "=== 4. CREATE SYSTEMD SHADOW UNIT ==="

cat >"$UNIT" <<'UNIT'
[Unit]
Description=Config Location Country Detection Shadow Worker

After=network-online.target \
config-location-fetcher.service \
config-location-health-adaptive.service

Wants=network-online.target

Requires=config-location-fetcher.service


[Service]
Type=simple

ExecStart=/opt/config-location/bin/country-shadow-daemon

Restart=always
RestartSec=5

TimeoutStopSec=30
KillMode=control-group

Nice=12

IOSchedulingClass=best-effort
IOSchedulingPriority=7

CPUAccounting=true
MemoryAccounting=true
TasksAccounting=true

LimitNOFILE=8192
TasksMax=512

NoNewPrivileges=true
PrivateTmp=true

ProtectSystem=full
ProtectHome=true

ReadWritePaths=/var/lib/config-location
ReadWritePaths=/var/log/config-location
ReadWritePaths=/run

Environment=PYTHONPATH=/opt/config-location
Environment=PYTHONUNBUFFERED=1

Environment=COUNTRY_MAX_JOBS_PER_CYCLE=3
Environment=COUNTRY_CYCLE_INTERVAL=45

StandardOutput=journal
StandardError=journal


[Install]
WantedBy=multi-user.target
UNIT


systemctl daemon-reload

echo "SYSTEMD_UNIT=PASS"


echo "=== 5. SAFETY CONTRACT ==="

systemctl cat \
config-location-country-worker.service

ENABLED=$(
    systemctl is-enabled \
    config-location-country-worker.service \
    2>/dev/null || true
)

echo "ENABLED_BEFORE=$ENABLED"

if [ "$ENABLED" = "enabled" ]; then
    systemctl disable \
    config-location-country-worker.service
fi

echo "PERMANENT_ENABLE=NO"


echo "=== 6. BASELINE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

states=Counter()

for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    states[
        str(
            o.get("state")
        )
    ] += 1

print(
    "BASELINE_RESULTS=",
    sum(states.values()),
)

print(
    "BASELINE_STATES=",
    dict(states),
)
PY


echo "=== 7. START SHADOW DAEMON ==="

systemctl stop \
config-location-country-worker.service \
2>/dev/null || true

systemctl reset-failed \
config-location-country-worker.service \
2>/dev/null || true

systemctl start \
config-location-country-worker.service

sleep 3

X=$(
    systemctl is-active \
    config-location-country-worker.service
)

echo "COUNTRY_SERVICE=$X"

test "$X" = active

echo "SHADOW_DAEMON_STARTED=PASS"


echo "=== 8. OBSERVE THREE CYCLES ==="

# cycle 1 starts immediately.
# With 45-second intervals, 100 seconds is
# enough to see at least three starts.
sleep 100


echo "=== 9. JOURNAL ==="

journalctl \
-u config-location-country-worker.service \
--since "-3 minutes" \
--no-pager \
| tail -n 160


echo "=== 10. DAEMON PROGRESS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

W=Path(
    "/var/lib/config-location/"
    "country/worker/state.json"
)

R=Path(
    "/var/lib/config-location/"
    "country/worker/last-run.json"
)

states=Counter()

for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    states[
        str(
            o.get("state")
        )
    ] += 1


worker=json.loads(
    W.read_text()
)

report=json.loads(
    R.read_text()
)


print(
    "COUNTRY_RESULTS=",
    sum(states.values()),
)

print(
    "COUNTRY_STATES=",
    dict(states),
)

print(
    "WORKER_TRACKED=",
    len(
        worker.get(
            "records",
            {}
        )
    ),
)

print(
    "LAST_SELECTED=",
    report.get(
        "selected"
    ),
)

print(
    "LAST_PROCESSED=",
    report.get(
        "processed"
    ),
)

print(
    "LAST_STATES=",
    report.get(
        "states"
    ),
)


assert (
    len(
        worker.get(
            "records",
            {}
        )
    )
    >= 16
)

assert (
    report.get(
        "mode"
    )
    == "shadow"
)

assert (
    int(
        report.get(
            "processed",
            0,
        )
    )
    >= 1
)

print(
    "SHADOW_PROGRESS=PASS"
)
PY


echo "=== 11. SERVICE ISOLATION ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(
        systemctl is-active \
        "$svc" \
        2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active
done

echo "PRODUCTION_ISOLATION=PASS"


echo "=== 12. COUNTRY SERVICE HEALTH ==="

X=$(
    systemctl is-active \
    config-location-country-worker.service
)

echo "COUNTRY_SERVICE=$X"

test "$X" = active

RESTARTS=$(
    systemctl show \
    config-location-country-worker.service \
    -p NRestarts \
    --value
)

echo "COUNTRY_SERVICE_RESTARTS=$RESTARTS"

test "$RESTARTS" -eq 0

echo "COUNTRY_DAEMON_STABILITY=PASS"


echo "=== 13. SANDBOX LEAK CHECK ==="

COUNT=$(
    find \
    /var/lib/config-location/health-sandboxes \
    -maxdepth 1 \
    -type d \
    -name "country-*" \
    2>/dev/null \
    | wc -l
)

echo "COUNTRY_SANDBOX_RESIDUAL=$COUNT"

# A running job may briefly own one sandbox at the
# exact sampling instant. Historical leakage is forbidden.
test "$COUNT" -le 1

echo "SANDBOX_LEAK_SLA=PASS"


echo "=== 14. STILL NOT ENABLED ==="

ENABLED=$(
    systemctl is-enabled \
    config-location-country-worker.service \
    2>/dev/null || true
)

echo "COUNTRY_SERVICE_ENABLED=$ENABLED"

test "$ENABLED" != enabled

echo "PERMANENT_ENABLE=NO"


echo "========================================"
echo "FIX22H1C=PASS"
echo "COUNTRY_SHADOW_DAEMON=RUNNING"
echo "RATE_LIMIT=3_JOBS_PER_45_SECONDS"
echo "COUNTRY_SERVICE_RESTARTS=0"
echo "HEALTH_FETCHER_ISOLATION=PASS"
echo "PERMANENT_SERVICE_ENABLED=NO"
echo "COUNTRY_PUBLICATION=DISABLED"
echo "REMARK_MUTATION=DISABLED"
echo "SUBSCRIPTION_MUTATION=DISABLED"
echo "BACKUP=$B"
echo "========================================"
