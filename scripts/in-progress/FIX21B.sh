#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

L="$R/app/health/lifecycle"
OUT=/var/lib/config-location/health-lifecycle/fix21-semantics-contract.json

echo "=== 1. COMPILE ==="

"$PY" -m py_compile \
"$L/policy.py" \
"$L/consecutive.py" \
"$L/engine.py" \
"$L/enforcement.py" \
"$L/safety_gates.py"

echo "COMPILE=PASS"


echo "=== 2. EXISTING LIFECYCLE SELFTESTS ==="

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_consecutive

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_policy

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_safety_gates

echo "LIFECYCLE_SELFTESTS=PASS"


echo "=== 3. POLICY CONFIG VERIFY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.health.lifecycle.policy import (
    LifecyclePolicyConfig,
)

c=LifecyclePolicyConfig()

print(
    "DEEP_QUARANTINE_AFTER=",
    c.deep_quarantine_after_unhealthy,
)

print(
    "DELETE_CANDIDATE_AFTER=",
    c.delete_candidate_after_unhealthy,
)

print(
    "ERROR_NEVER_DELETE=",
    c.error_never_delete,
)

print(
    "PRODUCTION_DELETE_ENABLED=",
    c.production_delete_enabled,
)

assert (
    c.deep_quarantine_after_unhealthy
    == 2
)

assert (
    c.delete_candidate_after_unhealthy
    == 4
)

assert (
    c.error_never_delete
    is True
)

assert (
    c.production_delete_enabled
    is False
)

print(
    "POLICY_CONFIG=PASS"
)
PY


echo "=== 4. LIVE POLICY SAFETY ==="

"$PY" <<'PY'
import json
from pathlib import Path
from collections import Counter

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "policy-latest.json"
)

o=json.loads(
    p.read_text()
)

decisions=o.get(
    "decisions",
    []
)

states=Counter()

violations=[]

for d in decisions:

    state=str(
        d.get(
            "policy_state",
            "unknown",
        )
    )

    states[state]+=1

    if (
        d.get(
            "production_delete_allowed"
        )
        is True
    ):
        violations.append(
            d.get("config_id")
        )

print(
    "POLICY_STATES=",
    dict(states),
)

print(
    "PRODUCTION_DELETE_TRUE=",
    len(violations),
)

assert violations == []

print(
    "LIVE_DELETE_FREEZE=PASS"
)
PY


echo "=== 5. ERROR SEMANTICS ==="

"$PY" <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "policy-latest.json"
)

o=json.loads(
    p.read_text()
)

bad=[]

for d in o.get(
    "decisions",
    []
):

    if (
        d.get("policy_state")
        == "error_retry"
    ):

        if (
            d.get(
                "delete_candidate_shadow"
            )
            or
            d.get(
                "production_delete_allowed"
            )
        ):
            bad.append(
                d.get("config_id")
            )

print(
    "ERROR_DELETE_VIOLATIONS=",
    len(bad),
)

assert bad == []

print(
    "ERROR_NEVER_DELETE=PASS"
)
PY


echo "=== 6. CANDIDATE THRESHOLD ==="

"$PY" <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "policy-latest.json"
)

o=json.loads(
    p.read_text()
)

bad=[]

candidates=0

for d in o.get(
    "decisions",
    []
):

    if d.get(
        "delete_candidate_shadow"
    ):

        candidates += 1

        streak=int(
            d.get(
                "consecutive_unhealthy",
                0,
            )
        )

        if streak < 4:
            bad.append(
                (
                    d.get("config_id"),
                    streak,
                )
            )

print(
    "DELETE_CANDIDATES=",
    candidates,
)

print(
    "THRESHOLD_VIOLATIONS=",
    len(bad),
)

assert bad == []

print(
    "DELETE_THRESHOLD=PASS"
)
PY


echo "=== 7. SAFETY SNAPSHOT ==="

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.safety_gates \
>/dev/null

"$PY" <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "safety-latest.json"
)

o=json.loads(
    p.read_text()
)

print(
    "FAILED_GATES=",
    o.get("failed_gates"),
)

print(
    "CONFIGURED_DELETE=",
    o.get(
        "configured_production_delete"
    ),
)

print(
    "PRODUCTION_DELETE_ALLOWED=",
    o.get(
        "production_delete_allowed"
    ),
)

assert (
    o.get(
        "configured_production_delete"
    )
    is False
)

assert (
    o.get(
        "production_delete_allowed"
    )
    is False
)

print(
    "SAFETY_FREEZE=PASS"
)
PY


echo "=== 8. WRITE SEMANTICS CONTRACT ==="

export OUT

"$PY" <<'PY'
import json
import os

from pathlib import Path
from datetime import (
    datetime,
    timezone,
)

p=Path(
    os.environ["OUT"]
)

o={
    "schema_version":1,

    "stage":"FIX21B",

    "generated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),

    "health_semantics":{

        "healthy":{
            "publish":True,
            "reset_unhealthy_streak":True,
            "destructive":False,
        },

        "unhealthy":{
            "publish":False,
            "increments_unhealthy_streak":True,
            "quarantine_after":1,
            "deep_quarantine_after":2,
            "delete_candidate_after":4,
        },

        "error":{
            "retry":True,
            "destructive":False,
            "delete":False,
        },

        "runtime_failed":{
            "retry_or_diagnostic":True,
            "destructive":False,
        },

        "unsupported_by_xray":{
            "destructive":False,
        },

        "unsupported_by_xray_version":{
            "destructive":False,
        },

        "invalid":{
            "destructive_from_health":False,
        },

        "not_tested":{
            "destructive":False,
        },
    },

    "production_delete":{
        "enabled":False,
        "allowed":False,
        "mode":"shadow_only",
    },

    "invariants":[
        "single_unhealthy_never_deletes",
        "error_never_deletes",
        "runtime_failure_never_deletes",
        "unsupported_never_deletes",
        "not_tested_never_deletes",
        "delete_candidate_requires_four_consecutive_unhealthy",
        "production_delete_remains_disabled",
    ],
}

tmp=p.with_name(
    "."+p.name+".tmp"
)

tmp.write_text(
    json.dumps(
        o,
        indent=2,
        sort_keys=True,
    )+"\n"
)

tmp.chmod(0o640)
tmp.replace(p)

print(
    json.dumps(
        o,
        indent=2,
    )
)
PY


echo "=== 9. SERVICES ==="

for svc in \
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


echo "========================================"
echo "FIX21B=PASS"
echo "HEALTH_SEMANTICS=FORMALIZED"
echo "DELETE_THRESHOLD=4_UNHEALTHY"
echo "ERROR_NEVER_DELETE=PASS"
echo "PRODUCTION_DELETE=DISABLED"
echo "LIFECYCLE_SELFTESTS=PASS"
echo "SERVICES=ACTIVE"
echo "CONTRACT=$OUT"
echo "========================================"
