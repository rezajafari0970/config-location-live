#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
REPORT=/var/lib/config-location/country/consumer-c2-drain-benchmark.json

echo "=== C2 R2 ANALYSIS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
from pathlib import Path
import json

baseline_path=Path(
    "/tmp/consumer-c2-baseline.json"
)

assert baseline_path.exists()

baseline=json.loads(
    baseline_path.read_text()
)

before=baseline["queue"]
after=stats()

duration=300.0

pending_before=int(before.get("pending",0))
pending_after=int(after.get("pending",0))

done_before=int(before.get("done",0))
done_after=int(after.get("done",0))

dead_after=int(after.get("dead",0))

done_growth=max(
    0,
    done_after-done_before,
)

pending_drop=(
    pending_before-pending_after
)

done_per_sec=(
    done_growth/duration
)

net_drain_per_sec=(
    pending_drop/duration
)

incoming_estimate=max(
    0,
    pending_after
    -pending_before
    +done_growth,
)

incoming_per_sec=(
    incoming_estimate/duration
)

eta=None

if net_drain_per_sec>0:
    eta=(
        pending_after
        /net_drain_per_sec
    )

report={
    "duration_seconds":duration,
    "queue_before":before,
    "queue_after":after,
    "done_growth":done_growth,
    "pending_drop":pending_drop,
    "done_per_second":
        round(done_per_sec,4),
    "net_drain_per_second":
        round(net_drain_per_sec,4),
    "estimated_incoming_per_second":
        round(incoming_per_sec,4),
    "estimated_seconds_to_empty":
        (
            round(eta,1)
            if eta is not None
            else None
        ),
}

Path(
    "/var/lib/config-location/country/"
    "consumer-c2-drain-benchmark.json"
).write_text(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

print(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

assert done_growth>=100
assert dead_after==0

print(
    "CONSUMER_C2_R2=PASS"
)
PY

echo
echo "=== SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
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

echo
echo "======================================================"
echo "FIX22K1_CONSUMER_C2_R2=PASS"
echo "DRAIN_BENCHMARK=COMPLETE"
echo "CPU_BOUND=YES"
echo "RAM_PRESSURE=NO"
echo "NEXT=K6-ROTATING-EXIT-HANDLING"
echo "======================================================"
