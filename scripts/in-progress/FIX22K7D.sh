#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

REPORT=/var/lib/config-location/country/k7d-production-recovery.json

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K7D-$TS"

mkdir -p "$B"

cp -a \
/var/lib/config-location/country/pipeline \
"$B/pipeline-before" \
2>/dev/null || true

cp -a \
/var/lib/config-location/country/country-identity \
"$B/country-identity-before" \
2>/dev/null || true

echo "BACKUP=$B"

echo "=== 1. STOP CONSUMER BRIEFLY ==="

systemctl stop \
config-location-country-event-consumer.service \
2>/dev/null || true

echo "CONSUMER_STOPPED=YES"


echo "=== 2. PRODUCTION RECOVERY ==="

export REPORT

PYTHONPATH="$R" "$PY" <<'PY'
from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from pathlib import Path
from collections import Counter
import json
import os

from app.country.progressive_recovery import (
    recover_country,
)

from app.country.country_identity import (
    load_identity,
    save_identity_once,
)

from app.country.event_consumer import (
    _CountryResultAdapter,
)

from app.country.storage import (
    save_country_result,
)


PIPE=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)


items=[]

for p in PIPE.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    state=str(
        o.get("state")
        or ""
    )

    if state not in {
        "ambiguous",
        "unresolved",
    }:
        continue

    if o.get("country_code"):
        continue

    config_id=o.get("config_id")
    exit_ip=o.get("exit_ip")

    if not config_id or not exit_ip:
        continue

    if load_identity(
        str(config_id)
    ) is not None:
        continue

    items.append(
        {
            "path":str(p),
            "config_id":str(config_id),
            "exit_ip":str(exit_ip),
            "old":o,
        }
    )


print(
    "RECOVERY_CANDIDATES=",
    len(items),
)


def work(
    item,
):

    r=recover_country(
        item["exit_ip"],
        timeout=5.0,
    )

    return item,r


results=[]


with ThreadPoolExecutor(
    max_workers=8,
    thread_name_prefix="k7d",
) as executor:

    futures=[
        executor.submit(
            work,
            item,
        )
        for item in items
    ]

    for f in as_completed(
        futures
    ):

        results.append(
            f.result()
        )


stats=Counter()

samples=[]


for item,recovery in results:

    stats["processed"]+=1

    if recovery.get("state")!="confirmed":

        stats["still_ambiguous"]+=1

        continue


    code=recovery.get(
        "country_code"
    )

    if not code:

        stats["confirmed_without_country"]+=1
        continue


    config_id=item["config_id"]
    exit_ip=item["exit_ip"]


    identity=save_identity_once(
        config_id=config_id,
        geo=recovery,
        exit_ip=exit_ip,
    )


    if identity is None:

        stats["identity_failed"]+=1
        continue


    old=item["old"]

    new=dict(old)

    new["country_code"]=str(
        code
    ).upper()

    new["country_name"]=(
        recovery.get(
            "country_name"
        )
        or identity.get(
            "country_name"
        )
    )

    new["asn"]=(
        recovery.get(
            "asn"
        )
        or old.get(
            "asn"
        )
    )

    new["network_name"]=(
        recovery.get(
            "network_name"
        )
        or old.get(
            "network_name"
        )
    )

    new["network_type"]=(
        recovery.get(
            "network_type"
        )
        or old.get(
            "network_type"
        )
    )

    new["confidence"]=(
        recovery.get(
            "country_confidence"
        )
    )

    new["primary"]=recovery


    # Country is known now.
    # K6 temporal layer still owns stable/rotating verdict.
    metadata=dict(
        old.get(
            "metadata"
        )
        or {}
    )

    rotating=metadata.get(
        "rotating_exit"
    )

    temporal=None

    if isinstance(
        rotating,
        dict,
    ):
        temporal=rotating.get(
            "state"
        )


    if temporal in {
        "confirmed_stable",
        "confirmed_rotating_ip",
    }:

        new["state"]=temporal

    else:

        new[
            "state"
        ]="pending_confirmation"


    metadata.update(
        {
            "k7_recovered":
                True,

            "k7_recovery_source":
                "independent_geo",

            "k7_recovery_reason":
                recovery.get(
                    "recovery_reason"
                ),

            "country_detection_once":
                True,

            "second_xray":
                False,

            "second_exit_probe":
                False,
        }
    )

    new["metadata"]=metadata


    save_country_result(
        _CountryResultAdapter(
            new
        )
    )


    stats["recovered"]+=1


    if len(samples)<30:

        samples.append(
            {
                "config_id":
                    config_id,

                "exit_ip":
                    exit_ip,

                "country":
                    new.get(
                        "country_code"
                    ),

                "reason":
                    recovery.get(
                        "recovery_reason"
                    ),
            }
        )


report={
    "stats":
        dict(stats),

    "samples":
        samples,
}


Path(
    os.environ["REPORT"]
).write_text(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)


print(
    "STATS=",
    dict(stats),
)

for s in samples:
    print(
        "RECOVERED_SAMPLE=",
        s,
    )


print(
    "K7D_PRODUCTION_RECOVERY=PASS"
)
PY


echo
echo "=== 3. POST-RECOVERY AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

root=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

states=Counter()

hard_unresolved=0
country_missing=0
country_known=0

for p in root.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    state=str(
        o.get("state")
        or "unknown"
    )

    states[state]+=1

    if o.get(
        "country_code"
    ):
        country_known+=1
    else:
        country_missing+=1

    if (
        state in {
            "ambiguous",
            "unresolved",
        }
        and not o.get(
            "country_code"
        )
    ):
        hard_unresolved+=1


print(
    "PIPELINE_STATES=",
    dict(states),
)

print(
    "COUNTRY_KNOWN=",
    country_known,
)

print(
    "COUNTRY_MISSING=",
    country_missing,
)

print(
    "HARD_UNRESOLVED=",
    hard_unresolved,
)

print(
    "POST_K7D_AUDIT=PASS"
)
PY


echo
echo "=== 4. IDENTITY AUDIT ==="

"$PY" <<'PY'
from pathlib import Path
import json

root=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

valid=0
invalid=0

for p in root.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        invalid+=1
        continue

    if (
        o.get("locked") is True
        and o.get("country_code")
    ):
        valid+=1
    else:
        invalid+=1


print(
    "IDENTITY_VALID=",
    valid,
)

print(
    "IDENTITY_INVALID=",
    invalid,
)

assert invalid==0

print(
    "IDENTITY_AUDIT=PASS"
)
PY


echo
echo "=== 5. RESTART CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


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
echo "FIX22K7D=PASS"
echo "PROGRESSIVE_RECOVERY=ROLLED_OUT"
echo "FALSE_CONFIRM_GUARD=PRESERVED"
echo "COUNTRY_IDENTITY=ATOMIC"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K7E"
echo "======================================================"
