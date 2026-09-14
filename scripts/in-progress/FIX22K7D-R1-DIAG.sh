#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. COUNTRY STORAGE CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.country import storage

for name in dir(storage):

    if (
        name.startswith("save")
        or name.startswith("load")
        or "path" in name.lower()
    ):

        obj=getattr(storage,name)

        if callable(obj):

            try:
                print(
                    "\nFUNCTION=",
                    name,
                    inspect.signature(obj),
                )
                print(
                    inspect.getsource(obj)
                )
            except Exception:
                pass
PY


echo
echo "=== 2. COUNTRY RESULT DIRECTORIES ==="

find \
/var/lib/config-location/country \
-maxdepth 3 \
-type d \
-printf '%p\n' \
| sort


echo
echo "=== 3. FILE COUNTS BY RESULT DIRECTORY ==="

for d in \
/var/lib/config-location/country/pipeline/latest \
/var/lib/config-location/country/latest \
/var/lib/config-location/country/results \
/var/lib/config-location/country/country-identity
do

    if [ -d "$d" ]; then
        echo "$d=$(find "$d" -maxdepth 1 -type f -name '*.json' | wc -l)"
    else
        echo "$d=MISSING"
    fi
done


echo
echo "=== 4. RECOVERED CONFIG CROSS-CHECK ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

report=Path(
    "/var/lib/config-location/country/"
    "k7d-production-recovery.json"
)

assert report.exists()

r=json.loads(
    report.read_text()
)

samples=r.get(
    "samples"
) or []

roots=[
    Path(
        "/var/lib/config-location/country/"
        "pipeline/latest"
    ),
    Path(
        "/var/lib/config-location/country/"
        "latest"
    ),
    Path(
        "/var/lib/config-location/country/"
        "results"
    ),
    Path(
        "/var/lib/config-location/country/"
        "country-identity"
    ),
]

for sample in samples[:20]:

    cid=sample.get(
        "config_id"
    )

    if not cid:
        continue

    print()
    print(
        "CONFIG_ID=",
        cid,
    )

    for root in roots:

        p=root/f"{cid}.json"

        if not p.exists():
            print(
                root,
                "=MISSING",
            )
            continue

        try:
            o=json.loads(
                p.read_text()
            )
        except Exception as exc:
            print(
                root,
                "=BAD_JSON",
                exc,
            )
            continue

        print(
            root,
            {
                "state":
                    o.get("state"),

                "country_code":
                    o.get("country_code"),

                "locked":
                    o.get("locked"),

                "k7_recovered":
                    (
                        (
                            o.get("metadata")
                            or {}
                        ).get(
                            "k7_recovered"
                        )
                    ),
            },
        )
PY


echo
echo "=== 5. WHO WRITES PIPELINE/LATEST ==="

grep -RIn \
--include='*.py' \
-E \
'pipeline/latest|save_country_result|write_text|os.replace' \
"$R/app/country" \
| head -n 1200


echo
echo "=== 6. SERVICE WRITERS ==="

for svc in \
config-location-country-worker.service \
config-location-country-event-consumer.service
do

    echo
    echo "--- $svc ---"

    systemctl cat "$svc" \
    --no-pager
done


echo
echo "=== 7. LAST 10 MINUTES COUNTRY LOGS ==="

journalctl \
-u config-location-country-worker.service \
-u config-location-country-event-consumer.service \
--since "10 minutes ago" \
--no-pager \
-l \
| tail -n 500


echo
echo "=== 8. CURRENT CANONICAL INVENTORY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

for root in (
    Path(
        "/var/lib/config-location/country/"
        "pipeline/latest"
    ),
    Path(
        "/var/lib/config-location/country/"
        "latest"
    ),
    Path(
        "/var/lib/config-location/country/"
        "results"
    ),
):

    if not root.exists():
        continue

    states=Counter()
    known=0
    missing=0
    total=0

    for p in root.glob(
        "*.json"
    ):

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

        if o.get(
            "country_code"
        ):
            known+=1
        else:
            missing+=1


    hard=sum(
        n
        for state,n
        in states.items()
        if state in {
            "ambiguous",
            "unresolved",
        }
    )

    print(
        "ROOT=",
        root,
    )

    print(
        "TOTAL=",
        total,
    )

    print(
        "STATES=",
        dict(states),
    )

    print(
        "COUNTRY_KNOWN=",
        known,
    )

    print(
        "COUNTRY_MISSING=",
        missing,
    )

    print(
        "HARD_UNRESOLVED=",
        hard,
    )

    print()
PY


echo
echo "=== 9. SERVICES ==="

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
echo "FIX22K7D_R1_DIAG=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K7E-ONLY-AFTER-CANONICAL-STORE-RESOLUTION"
echo "======================================================"
