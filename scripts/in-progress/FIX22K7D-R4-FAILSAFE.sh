#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. RESTORE WRITERS ==="

systemctl restart \
config-location-country-worker.service \
config-location-country-event-consumer.service

sleep 4

for svc in \
config-location-country-worker.service \
config-location-country-event-consumer.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo "WRITERS_RESTORED=PASS"


echo
echo "=== 2. EXACT PIPELINE SAVE SIGNATURES ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect
from app.country import pipeline

for name in (
    "save_pipeline_result",
    "_save_pipeline_result_unguarded",
):

    fn=getattr(
        pipeline,
        name,
        None,
    )

    print()
    print(
        "FUNCTION=",
        name,
    )

    print(
        "SIGNATURE=",
        inspect.signature(fn),
    )

    print(
        inspect.getsource(fn)
    )
PY


echo
echo "=== 3. PROCESS_COUNTRY SAVE CALL WINDOW ==="

nl -ba \
"$R/app/country/pipeline.py" \
| sed -n '140,360p'


echo
echo "=== 4. SERVICES ==="

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
echo "FIX22K7D_R4_FAILSAFE=PASS"
echo "WRITERS_RESTORED=YES"
echo "PRODUCTION_RECONCILIATION=NOT_STARTED"
echo "NEXT=FIX22K7D-R4-R2"
echo "======================================================"
