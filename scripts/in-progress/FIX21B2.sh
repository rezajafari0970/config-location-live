#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

P="$R/app/health/lifecycle/policy.py"
OUT=/var/lib/config-location/health-lifecycle/fix21-semantics-contract.json

echo "=== 1. SOURCE CONSTANT VERIFY ==="

export P

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["P"])
tree=ast.parse(p.read_text())

values={}

for node in ast.walk(tree):

    if not isinstance(
        node,
        ast.AnnAssign,
    ):
        continue

    if not isinstance(
        node.target,
        ast.Name,
    ):
        continue

    name=node.target.id

    if name not in {
        "deep_quarantine_after_unhealthy",
        "delete_candidate_after_unhealthy",
        "error_never_delete",
        "production_delete_enabled",
    }:
        continue

    try:
        values[name]=ast.literal_eval(
            node.value
        )
    except Exception:
        pass

print(
    "POLICY_CONSTANTS=",
    values,
)

assert (
    values[
        "deep_quarantine_after_unhealthy"
    ]
    == 2
)

assert (
    values[
        "delete_candidate_after_unhealthy"
    ]
    == 4
)

assert (
    values[
        "error_never_delete"
    ]
    is True
)

assert (
    values[
        "production_delete_enabled"
    ]
    is False
)

print(
    "SOURCE_POLICY=PASS"
)
PY


echo "=== 2. SELFTESTS ==="

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_consecutive

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_policy

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_safety_gates

echo "SELFTESTS=PASS"


echo "=== 3. LIVE POLICY ==="

"$PY" <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "policy-latest.json"
)

o=json.loads(p.read_text())

bad_error=[]
bad_candidate=[]
production=[]

for d in o.get(
    "decisions",
    []
):

    if d.get(
        "production_delete_allowed"
    ):
        production.append(
            d.get("config_id")
        )

    if (
        d.get("policy_state")
        == "error_retry"
        and (
            d.get(
                "delete_candidate_shadow"
            )
            or
            d.get(
                "production_delete_allowed"
            )
        )
    ):
        bad_error.append(
            d.get("config_id")
        )

    if d.get(
        "delete_candidate_shadow"
    ):

        streak=int(
            d.get(
                "consecutive_unhealthy",
                0,
            )
        )

        if streak < 4:
            bad_candidate.append(
                (
                    d.get("config_id"),
                    streak,
                )
            )

print(
    "PRODUCTION_DELETE_TRUE=",
    len(production),
)

print(
    "ERROR_DELETE_VIOLATIONS=",
    len(bad_error),
)

print(
    "THRESHOLD_VIOLATIONS=",
    len(bad_candidate),
)

assert production == []
assert bad_error == []
assert bad_candidate == []

print(
    "LIVE_POLICY=PASS"
)
PY


echo "=== 4. SAFETY ==="

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.safety_gates \
>/dev/null

"$PY" <<'PY'
import json
from pathlib import Path

o=json.loads(
    Path(
        "/var/lib/config-location/"
        "health-lifecycle/"
        "safety-latest.json"
    ).read_text()
)

print(
    "CONFIGURED_DELETE=",
    o.get(
        "configured_production_delete"
    ),
)

print(
    "DELETE_ALLOWED=",
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


echo "=== 5. WRITE CONTRACT ==="

export OUT

"$PY" <<'PY'
import json
import os

from pathlib import Path
from datetime import (
    datetime,
    timezone,
)

p=Path(os.environ["OUT"])

o={
    "schema_version":1,
    "stage":"FIX21B",
    "status":"PASS",

    "generated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),

    "semantics":{

        "healthy":{
            "publish":True,
            "destructive":False,
            "resets_unhealthy_streak":True,
        },

        "unhealthy":{
            "publish":False,
            "quarantine_after":1,
            "deep_quarantine_after":2,
            "delete_candidate_after":4,
            "production_delete":False,
        },

        "error":{
            "retry":True,
            "extends_unhealthy_streak":False,
            "delete":False,
        },

        "runtime_failed":{
            "delete":False,
        },

        "unsupported_by_xray":{
            "delete":False,
        },

        "unsupported_by_xray_version":{
            "delete":False,
        },

        "not_tested":{
            "delete":False,
        },
    },

    "production_delete":{
        "configured":False,
        "allowed":False,
        "mode":"shadow_only",
    },

    "verified":[
        "lifecycle_selftests",
        "consecutive_tracking",
        "policy_thresholds",
        "error_never_delete",
        "safety_freeze",
        "production_delete_disabled",
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
    "CONTRACT_WRITTEN=",
    p,
)
PY


echo "=== 6. SERVICES ==="

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
echo "UNHEALTHY_DELETE_CANDIDATE_THRESHOLD=4"
echo "ERROR_NEVER_DELETE=PASS"
echo "PRODUCTION_DELETE=DISABLED"
echo "SAFETY_GATES=PASS"
echo "SERVICES=ACTIVE"
echo "CONTRACT=$OUT"
echo "========================================"
