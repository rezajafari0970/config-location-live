#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. FIND REAL HEALTHY RESULTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

healthy=[]

for p in sorted(
    H.glob("*.json"),
    key=lambda x:
        x.stat().st_mtime,
    reverse=True,
):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    if str(
        o.get(
            "state",
            "",
        )
    ).lower()=="healthy":

        healthy.append(
            (
                p,
                o,
            )
        )

    if len(healthy)>=10:
        break


print(
    "HEALTHY_SAMPLES=",
    len(healthy),
)

assert healthy


for p,o in healthy:

    print()
    print(
        "FILE=",
        p.name,
    )

    print(
        "config_id=",
        o.get("config_id"),
    )

    print(
        "state=",
        o.get("state"),
    )

    print(
        "xray_started=",
        o.get("xray_started"),
    )

    print(
        "download_verified=",
        o.get(
            "download_verified"
        ),
    )

    print(
        "upload_verified=",
        o.get(
            "upload_verified"
        ),
    )

    print(
        "job_id=",
        o.get("job_id"),
    )

    print(
        "started_at=",
        o.get("started_at"),
    )

    print(
        "finished_at=",
        o.get("finished_at"),
    )

    print(
        "health_decision=",
        (
            o.get("metadata")
            or {}
        ).get(
            "health_decision"
        ),
    )
PY


echo "=== 2. DRY-RUN CURRENT GATE WITHOUT ENQUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

counts={
    "healthy":0,
    "xray":0,
    "download":0,
    "upload":0,
    "decision":0,
    "all":0,
}

examples=[]


for p in H.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue


    state=(
        str(
            o.get(
                "state",
                "",
            )
        ).lower()
        =="healthy"
    )

    xray=bool(
        o.get(
            "xray_started",
            False,
        )
    )

    down=bool(
        o.get(
            "download_verified",
            False,
        )
    )

    up=bool(
        o.get(
            "upload_verified",
            False,
        )
    )

    d=(
        (
            o.get("metadata")
            or {}
        ).get(
            "health_decision"
        )
        or {}
    )

    decision=bool(
        isinstance(d,dict)
        and d.get(
            "healthy",
            False,
        )
    )


    counts["healthy"]+=int(state)

    if state:
        counts["xray"]+=int(xray)
        counts["download"]+=int(down)
        counts["upload"]+=int(up)
        counts["decision"]+=int(
            decision
        )

        if (
            state
            and xray
            and down
            and up
            and decision
        ):
            counts["all"]+=1

        elif len(examples)<10:
            examples.append({
                "config_id":
                    o.get(
                        "config_id"
                    ),
                "xray":
                    xray,
                "download":
                    down,
                "upload":
                    up,
                "decision":
                    decision,
                "raw_decision":
                    d,
            })


print(
    "GATE_COUNTS=",
    counts,
)

print(
    "FAILED_EXAMPLES=",
    examples,
)

assert counts["healthy"]>0
PY


echo "=== 3. RECENT RESULT DISTRIBUTION ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json,time

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

cut=time.time()-300

states=Counter()

recent=0

for p in H.glob("*.json"):

    if p.stat().st_mtime < cut:
        continue

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        states["corrupt"]+=1
        continue

    recent+=1

    states[
        str(
            o.get(
                "state",
                "unknown",
            )
        )
    ]+=1


print(
    "LAST_5_MIN_RESULTS=",
    recent,
)

print(
    "LAST_5_MIN_STATES=",
    dict(states),
)
PY


echo "=== 4. CURRENT HOOK SOURCE ==="

sed -n '1,280p' \
"$R/app/country/health_hook.py"


echo "=== 5. PATCH PRESENCE ==="

grep -n \
'FIX22K1 RESULT_STORE_EVENT' \
"$R/app/health/core/production_scheduler.py"

echo "RESULT_STORE_HOOK_PRESENT=YES"


echo "=== 6. SERVICES ==="

for svc in \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-fetcher.service
do
    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )
    echo "$svc=$X"
    test "$X" = active
done


echo "========================================"
echo "FIX22K1C9=PASS"
echo "MODE=GATE_DIAGNOSTIC"
echo "PRODUCTION_CHANGED=NO"
echo "========================================"
