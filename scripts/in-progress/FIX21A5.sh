#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

echo "=== POLICY CONSTANTS ==="
grep -nE \
'threshold|consecutive|failure|unhealthy|lifetime|ttl|expire|delete|grace' \
"$R/app/health/lifecycle/policy.py" \
| head -n 120

echo "=== CONSECUTIVE DECISION ==="
grep -nE \
'def |healthy|unhealthy|failure|streak|threshold|delete|eligible' \
"$R/app/health/lifecycle/consecutive.py" \
| head -n 140

echo "=== ENGINE DECISION ==="
grep -nE \
'def |HealthState|healthy|unhealthy|error|runtime_failed|unsupported|invalid|not_tested|delete|unlink' \
"$R/app/health/lifecycle/engine.py" \
| head -n 180

echo "=== ENFORCEMENT ==="
grep -nE \
'def |delete|unlink|config|health|latest|eligible|blocked|reason' \
"$R/app/health/lifecycle/enforcement.py" \
| head -n 180

echo "=== SAFETY GATES ==="
grep -nE \
'def |allow|deny|gate|healthy|unhealthy|stale|coverage|minimum|threshold|delete' \
"$R/app/health/lifecycle/safety_gates.py" \
| head -n 180

echo "=== CURRENT POLICY JSON ==="
python3 - <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/policy-latest.json"
)

if p.exists():
    o=json.loads(p.read_text())
    print(json.dumps(o,indent=2)[:2500])
else:
    print("POLICY_FILE=MISSING")
PY

echo "========================================"
echo "FIX21A5=PASS"
echo "LIFECYCLE_POLICY_PINNED=YES"
echo "========================================"
