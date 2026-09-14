#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

REPORT=/var/lib/config-location/country/k9b-r1-conflict-diagnostic.json

echo "=== 1. IDENTITY / PIPELINE CONFLICT INVENTORY ==="

export REPORT

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import os

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

conflicts=[]
stats=Counter()
states=Counter()
pairs=Counter()

identity_newer=0
pipeline_newer=0
same_mtime=0

guard_present=0
guard_missing=0


for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
        stats["bad_identity_json"]+=1
        continue


    if not (
        ident.get("locked") is True
        and ident.get("country_code")
    ):
        continue


    cid=str(
        ident.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        stats["identity_without_pipeline"]+=1
        continue


    try:
        pipe=json.loads(
            pp.read_text()
        )
    except Exception:
        stats["bad_pipeline_json"]+=1
        continue


    stats["checked"]+=1


    ic=str(
        ident.get("country_code")
        or ""
    ).upper()

    pc=str(
        pipe.get("country_code")
        or ""
    ).upper()


    if ic==pc:
        stats["consistent"]+=1
        continue


    stats["conflict"]+=1

    state=str(
        pipe.get("state")
        or "unknown"
    )

    states[state]+=1

    pairs[
        f"{pc or 'NONE'}->{ic}"
    ]+=1


    im=ip.stat().st_mtime_ns
    pm=pp.stat().st_mtime_ns

    if im>pm:
        identity_newer+=1
        age_relation="identity_newer"
    elif pm>im:
        pipeline_newer+=1
        age_relation="pipeline_newer"
    else:
        same_mtime+=1
        age_relation="same"


    metadata=(
        pipe.get("metadata")
        or {}
    )

    if metadata.get(
        "country_identity_guard"
    ) is True:
        guard_present+=1
    else:
        guard_missing+=1


    conflicts.append(
        {
            "config_id":
                cid,

            "identity_country":
                ic,

            "pipeline_country":
                pc or None,

            "pipeline_state":
                state,

            "identity_source":
                ident.get("source"),

            "identity_first_exit_ip":
                ident.get(
                    "first_exit_ip"
                ),

            "pipeline_exit_ip":
                pipe.get(
                    "exit_ip"
                ),

            "identity_mtime_ns":
                im,

            "pipeline_mtime_ns":
                pm,

            "age_relation":
                age_relation,

            "pipeline_guard":
                metadata.get(
                    "country_identity_guard"
                ),

            "pipeline_k7_recovered":
                metadata.get(
                    "k7_recovered"
                ),

            "pipeline_k7e":
                metadata.get(
                    "k7e_hard_fallback"
                ),
        }
    )


print(
    "CHECKED=",
    stats["checked"],
)

print(
    "CONSISTENT=",
    stats["consistent"],
)

print(
    "CONFLICTS=",
    stats["conflict"],
)

print(
    "IDENTITY_WITHOUT_PIPELINE=",
    stats[
        "identity_without_pipeline"
    ],
)

print(
    "CONFLICT_STATES=",
    dict(states),
)

print(
    "COUNTRY_TRANSITIONS=",
    pairs.most_common(40),
)

print(
    "IDENTITY_NEWER=",
    identity_newer,
)

print(
    "PIPELINE_NEWER=",
    pipeline_newer,
)

print(
    "SAME_MTIME=",
    same_mtime,
)

print(
    "GUARD_PRESENT=",
    guard_present,
)

print(
    "GUARD_MISSING=",
    guard_missing,
)


for row in conflicts[:80]:

    print(
        "CONFLICT=",
        row,
    )


out={
    "stats":
        dict(stats),

    "states":
        dict(states),

    "country_transitions":
        dict(pairs),

    "identity_newer":
        identity_newer,

    "pipeline_newer":
        pipeline_newer,

    "same_mtime":
        same_mtime,

    "guard_present":
        guard_present,

    "guard_missing":
        guard_missing,

    "conflicts":
        conflicts,
}


Path(
    os.environ["REPORT"]
).write_text(
    json.dumps(
        out,
        indent=2,
        sort_keys=True,
    )
)


assert stats["conflict"]>=1

print(
    "CONFLICT_DIAGNOSTIC=PASS"
)
PY


echo
echo "=== 2. IDENTITY CREATION CALL SITES ==="

grep -RIn \
--include='*.py' \
-E \
'save_identity_once|country-identity|save_pipeline_result' \
"$R/app/country" \
| head -n 1200


echo
echo "=== 3. COUNTRY IDENTITY SOURCE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.country import country_identity

print(
    inspect.getsource(
        country_identity.save_identity_once
    )
)
PY


echo
echo "=== 4. PIPELINE GUARD SOURCE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.country import pipeline

print(
    inspect.getsource(
        pipeline.save_pipeline_result
    )
)
PY


echo
echo "=== 5. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)
PY


echo
echo "=== 6. SERVICES ==="

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
echo "FIX22K9B_R1_DIAG=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "K9C=BLOCKED_UNTIL_CONSISTENCY_FIXED"
echo "NEXT=FIX22K9B-R2"
echo "======================================================"
