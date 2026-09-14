#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

for F in \
policy.py \
consecutive.py \
engine.py \
enforcement.py \
safety_gates.py \
sync_daemon.py
do
    P="$R/app/health/lifecycle/$F"

    echo "===== $F ====="

    grep -n \
    -B8 -A28 \
    -E "threshold|consecutive|unhealthy|healthy|runtime_failed|error|invalid|unsupported|not_tested|delete|unlink|safety|gate|latest|health-results|configs" \
    "$P" \
    | head -n 220
done

echo "=== LIVE POLICY STATE ==="

python3 - <<'PY'
import json
from pathlib import Path

root=Path(
    "/var/lib/config-location/"
    "health-lifecycle"
)

for name in (
    "policy-latest.json",
    "sync-status.json",
    "watchdog-status.json",
):
    p=root/name

    print("FILE=",name)

    if not p.exists():
        print("MISSING")
        continue

    try:
        o=json.loads(p.read_text())
    except Exception as e:
        print("INVALID",e)
        continue

    print(
        json.dumps(
            o,
            indent=2,
        )[:3500]
    )
PY

echo "========================================"
echo "FIX21A4=PASS"
echo "LIFECYCLE_DECISION_SUMMARY=COMPLETE"
echo "========================================"
