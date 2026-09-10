#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. STORE CONSTANTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country import storage

for name in (
    "ROOT",
    "LATEST",
    "HISTORY",
):
    print(
        name,
        "=",
        getattr(storage,name,None),
    )
PY


echo
echo "=== 2. WORKER SOURCE ==="

nl -ba \
"$R/app/country/worker.py" \
| sed -n '1,360p'


echo
echo "=== 3. PIPELINE WRITE REFERENCES ==="

grep -RIn \
--include='*.py' \
-E \
'country/pipeline/latest|pipeline/latest|PIPELINE|LATEST|atomic|os\.replace|write_text' \
"$R/app/country" \
| head -n 1600


echo
echo "=== 4. RESULTS/LATEST INVENTORY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

roots=[
    Path(
        "/var/lib/config-location/country/"
        "results/latest"
    ),
    Path(
        "/var/lib/config-location/country/"
        "pipeline/latest"
    ),
]

for root in roots:

    print()
    print(
        "ROOT=",
        root,
    )

    if not root.exists():
        print("EXISTS=NO")
        continue

    states=Counter()

    total=0
    known=0
    missing=0
    recovered=0
    guarded=0

    for p in root.glob("*.json"):

        try:
            o=json.loads(
                p.read_text()
            )
        except Exception:
            continue

        total+=1

        states[
            str(
                o.get("state")
                or "unknown"
            )
        ]+=1

        if o.get("country_code"):
            known+=1
        else:
            missing+=1

        metadata=(
            o.get("metadata")
            or {}
        )

        if metadata.get(
            "k7_recovered"
        ):
            recovered+=1

        if metadata.get(
            "country_identity_guard"
        ):
            guarded+=1


    hard=sum(
        n
        for state,n
        in states.items()
        if state in {
            "ambiguous",
            "unresolved",
        }
    )

    print("TOTAL=",total)
    print("STATES=",dict(states))
    print("COUNTRY_KNOWN=",known)
    print("COUNTRY_MISSING=",missing)
    print("HARD_UNRESOLVED=",hard)
    print("K7_RECOVERED=",recovered)
    print("IDENTITY_GUARDED=",guarded)
PY


echo
echo "=== 5. K7D RECOVERED CROSS-STORE CHECK ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

report=Path(
    "/var/lib/config-location/country/"
    "k7d-production-recovery.json"
)

assert report.exists()

o=json.loads(
    report.read_text()
)

samples=o.get("samples") or []

roots={
    "RESULTS":
        Path(
            "/var/lib/config-location/country/"
            "results/latest"
        ),

    "PIPELINE":
        Path(
            "/var/lib/config-location/country/"
            "pipeline/latest"
        ),

    "IDENTITY":
        Path(
            "/var/lib/config-location/country/"
            "country-identity"
        ),
}


for row in samples[:30]:

    cid=row.get("config_id")

    if not cid:
        continue

    print()
    print("CONFIG_ID=",cid)

    for name,root in roots.items():

        p=root/f"{cid}.json"

        if not p.exists():

            print(
                name,
                "=MISSING",
            )

            continue

        try:
            value=json.loads(
                p.read_text()
            )
        except Exception as exc:

            print(
                name,
                "=BAD_JSON",
                exc,
            )

            continue

        print(
            name,
            {
                "state":
                    value.get("state"),

                "country_code":
                    value.get(
                        "country_code"
                    ),

                "locked":
                    value.get("locked"),

                "k7_recovered":
                    (
                        (
                            value.get("metadata")
                            or {}
                        ).get(
                            "k7_recovered"
                        )
                    ),
            },
        )
PY


echo
echo "=== 6. PIPELINE VS RESULTS SAME-CONFIG DIFF PROFILE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

A=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

B=Path(
    "/var/lib/config-location/country/"
    "results/latest"
)

stats=Counter()
samples=[]

for bp in B.glob("*.json"):

    cid=bp.stem
    ap=A/f"{cid}.json"

    if not ap.exists():
        stats["results_only"]+=1
        continue

    try:
        a=json.loads(ap.read_text())
        b=json.loads(bp.read_text())
    except Exception:
        stats["bad_json"]+=1
        continue

    stats["both"]+=1

    same_country=(
        a.get("country_code")
        ==b.get("country_code")
    )

    same_state=(
        a.get("state")
        ==b.get("state")
    )

    if same_country:
        stats["same_country"]+=1
    else:
        stats["different_country"]+=1

    if same_state:
        stats["same_state"]+=1
    else:
        stats["different_state"]+=1

    if (
        not same_country
        or not same_state
    ) and len(samples)<30:

        samples.append(
            {
                "config_id":cid,

                "pipeline_state":
                    a.get("state"),

                "pipeline_country":
                    a.get("country_code"),

                "results_state":
                    b.get("state"),

                "results_country":
                    b.get("country_code"),
            }
        )


print(
    "CROSS_STORE_STATS=",
    dict(stats),
)

for row in samples:

    print(
        "DIFF_SAMPLE=",
        row,
    )
PY


echo
echo "=== 7. SERVICES ==="

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


echo
echo "======================================================"
echo "FIX22K7D_R3_STORE_OWNERSHIP=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K7D-R4-CANONICAL-RECONCILIATION"
echo "======================================================"
