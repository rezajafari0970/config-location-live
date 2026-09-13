#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
MOD="$R/app/panel/read_model.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/PANEL-A2-R2-$TS"

mkdir -p "$B"
cp -a "$MOD" "$B/read_model.py.before"

echo "BACKUP=$B"

export MOD

echo
echo "=== 1. PATCH REAL PRODUCTION SCHEMAS ==="

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["MOD"])
s=p.read_text()

MARK="PANEL_A2_R2_REAL_SCHEMA_MAPPING"

if MARK in s:
    print("SCHEMA_FIX_ALREADY_PRESENT=YES")
    raise SystemExit(0)

# Health uses `state`, not status.
old='''    health_status=(
        (health or {}).get(
            "status"
        )
        or (health or {}).get(
            "health_status"
        )
        or "unknown"
    )
'''

new='''    # PANEL_A2_R2_REAL_SCHEMA_MAPPING
    health_status=(
        (health or {}).get(
            "state"
        )
        or (health or {}).get(
            "status"
        )
        or (health or {}).get(
            "health_status"
        )
        or "unknown"
    )
'''

if old not in s:
    raise SystemExit(
        "ERROR=HEALTH_MAPPING_BLOCK_NOT_FOUND"
    )

s=s.replace(old,new,1)


# Config timestamps are *_at.
s=s.replace(
'''        "last_seen":
            config.get(
                "last_seen"
            ),

        "first_seen":
            config.get(
                "first_seen"
            ),
''',
'''        "last_seen":
            config.get(
                "last_seen_at"
            )
            or config.get(
                "last_seen"
            ),

        "first_seen":
            config.get(
                "first_seen_at"
            )
            or config.get(
                "first_seen"
            ),
''',
1,
)


# Production rotating state.
s=s.replace(
'''        "rotating":
            state.lower()
            =="confirmed_rotating",
''',
'''        "rotating":
            state.lower()
            in {
                "confirmed_rotating",
                "confirmed_rotating_ip",
            },
''',
1,
)


p.write_text(s)

print(
    "REAL_SCHEMA_MAPPING_PATCH=PASS"
)
PY


echo
echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$MOD"

echo "COMPILE=PASS"


echo
echo "=== 3. HEALTH SCHEMA PROOF ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

from app.panel.read_model import (
    query_configs,
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

actual=Counter()

for p in H.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    actual[
        str(
            o.get("state")
            or "unknown"
        )
    ]+=1


model=query_configs(
    limit=500,
)

model_health=Counter(
    row["health_status"]
    for row in model["items"]
)

print(
    "ACTUAL_HEALTH_STATES=",
    dict(actual),
)

print(
    "MODEL_SAMPLE_HEALTH=",
    dict(model_health),
)

assert sum(actual.values())>0

assert any(
    k!="unknown"
    for k in actual
)

assert any(
    k!="unknown"
    for k in model_health
)

print(
    "HEALTH_SCHEMA_MAPPING=PASS"
)
PY


echo
echo "=== 4. ROTATING STATE PROOF ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.panel.read_model import (
    build_config_view,
)

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

tested=0

for p in P.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    if o.get("state")!="confirmed_rotating_ip":
        continue

    cid=str(
        o.get("config_id")
        or p.stem
    )

    row=build_config_view(
        cid,
        {
            "id":cid,
            "type":
                o.get("config_type")
                or "unknown",
            "source_ids":[],
        },
    )

    print(
        "ROTATING_SAMPLE=",
        {
            "config_id":cid,
            "state":
                row[
                    "country_state"
                ],
            "rotating":
                row[
                    "rotating"
                ],
        },
    )

    assert (
        row["country_state"]
        =="confirmed_rotating_ip"
    )

    assert row["rotating"] is True

    tested+=1

    if tested>=20:
        break


print(
    "ROTATING_TESTED=",
    tested,
)

assert tested>0

print(
    "ROTATING_MAPPING=PASS"
)
PY


echo
echo "=== 5. TIMESTAMP SCHEMA PROOF ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.read_model import (
    query_configs,
)

r=query_configs(
    limit=100,
)

rows=r["items"]

with_first=sum(
    1
    for x in rows
    if x.get("first_seen")
)

with_last=sum(
    1
    for x in rows
    if x.get("last_seen")
)

print(
    "WITH_FIRST_SEEN=",
    with_first,
)

print(
    "WITH_LAST_SEEN=",
    with_last,
)

assert with_first>0
assert with_last>0

print(
    "TIMESTAMP_MAPPING=PASS"
)
PY


echo
echo "=== 6. FULL DASHBOARD SUMMARY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.read_model import (
    dashboard_summary,
)

s=dashboard_summary()

print(
    "TOTAL_CONFIGS=",
    s["total_configs"],
)

print(
    "COUNTRY_KNOWN=",
    s["country_known"],
)

print(
    "COUNTRY_UNRESOLVED=",
    s["country_unresolved"],
)

print(
    "COUNTRY_ROTATING=",
    s["country_rotating"],
)

print(
    "COUNTRY_COVERAGE_PERCENT=",
    s["country_coverage_percent"],
)

print(
    "HEALTH=",
    s["health"],
)

print(
    "COUNTRY_STATES=",
    s["country_states"],
)

assert s["total_configs"]>0

assert any(
    k!="unknown"
    for k in s["health"]
)

assert (
    s["country_rotating"]
    >0
)

print(
    "DASHBOARD_SCHEMA=PASS"
)
PY


echo
echo "=== 7. READ-ONLY RECHECK ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/panel/read_model.py"
)

src=p.read_text()
tree=ast.parse(src)

forbidden={
    "write_text",
    "write_bytes",
    "unlink",
    "mkdir",
    "rename",
    "touch",
    "rmdir",
    "remove",
    "rmtree",
    "system",
    "run",
    "Popen",
    "check_call",
    "check_output",
}

bad=[]

for node in ast.walk(tree):

    if not isinstance(node,ast.Call):
        continue

    f=node.func

    name=(
        f.attr
        if isinstance(f,ast.Attribute)
        else
        f.id
        if isinstance(f,ast.Name)
        else None
    )

    if name in forbidden:
        bad.append(
            (
                node.lineno,
                name,
            )
        )

print(
    "WRITE_CALLS=",
    bad,
)

assert not bad

print(
    "READ_ONLY_CONTRACT=PASS"
)
PY


echo
echo "=== 8. SERVICES ==="

for S in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service
do

    X=$(
        systemctl is-active \
        "$S" 2>/dev/null || true
    )

    echo "$S=$X"

    test "$X" = active
done


echo
echo "======================================================"
echo "PANEL_A2_R2=PASS"
echo "HEALTH_SCHEMA=CORRECT"
echo "ROTATING_SCHEMA=CORRECT"
echo "TIMESTAMPS=CORRECT"
echo "READ_ONLY=YES"
echo "PANEL_RESTART=NO"
echo "NEXT=PANEL-A3-COUNTRY-API"
echo "======================================================"
