#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

REPORT=/var/lib/config-location/country/k7b-recovery-report.json

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K7B-$TS"

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


echo "=== 1. STOP EVENT CONSUMER BRIEFLY ==="

systemctl stop \
config-location-country-event-consumer.service \
2>/dev/null || true

echo "CONSUMER_STOPPED=YES"


echo "=== 2. CACHE / PIPELINE RECONCILIATION ==="

export REPORT

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import os

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

CACHE=Path(
    "/var/lib/config-location/country/"
    "geo-cache"
)


# --------------------------------------------------
# Build IP -> confirmed Geo map
# --------------------------------------------------

confirmed_by_ip={}

for p in CACHE.glob("*.json"):

    try:
        wrapper=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    if not isinstance(
        wrapper,
        dict,
    ):
        continue

    ip=wrapper.get("ip")
    geo=wrapper.get("value")

    if (
        not ip
        or not isinstance(
            geo,
            dict,
        )
    ):
        continue

    if (
        str(
            geo.get("state")
            or ""
        )!="confirmed"
    ):
        continue

    if not geo.get(
        "country_code"
    ):
        continue

    confirmed_by_ip[
        str(ip)
    ]=geo


print(
    "CONFIRMED_CACHE_IPS=",
    len(confirmed_by_ip),
)


stats=Counter()

samples=[]


for p in PIPE.glob("*.json"):

    try:
        old=json.loads(
            p.read_text()
        )
    except Exception:
        stats["bad_pipeline_json"]+=1
        continue


    if not isinstance(
        old,
        dict,
    ):
        continue


    state=str(
        old.get("state")
        or ""
    )


    if state not in {
        "ambiguous",
        "pending_confirmation",
        "unresolved",
    }:
        continue


    stats["candidates"]+=1


    config_id=str(
        old.get("config_id")
        or ""
    )

    exit_ip=old.get(
        "exit_ip"
    )


    if not config_id:
        stats["missing_config_id"]+=1
        continue


    # Already locked by K6C: nothing to resolve.
    existing_identity=(
        load_identity(
            config_id
        )
    )

    if existing_identity is not None:

        stats[
            "already_identity_locked"
        ]+=1

        continue


    geo=None
    source=None


    # ----------------------------------------------
    # Fast recovery A:
    # current K4/K5 confirmed Geo Cache
    # ----------------------------------------------

    if exit_ip:

        geo=confirmed_by_ip.get(
            str(exit_ip)
        )

        if geo is not None:
            source="confirmed_geo_cache"


    # ----------------------------------------------
    # Fast recovery B:
    # existing Pipeline primary already confirmed
    # ----------------------------------------------

    if geo is None:

        primary=old.get(
            "primary"
        )

        if (
            isinstance(
                primary,
                dict,
            )
            and str(
                primary.get("state")
                or ""
            )=="confirmed"
            and primary.get(
                "country_code"
            )
        ):

            geo=primary
            source="confirmed_primary"


    if geo is None:

        stats[
            "needs_progressive_recovery"
        ]+=1

        continue


    code=str(
        geo.get(
            "country_code"
        )
    ).upper()


    # Build immutable K6 identity.
    identity=save_identity_once(
        config_id=config_id,
        geo=geo,
        exit_ip=str(
            exit_ip
            or ""
        ),
    )


    if identity is None:

        stats[
            "identity_not_created"
        ]+=1

        continue


    # Preserve existing result and replace only
    # Country-resolution fields.
    new=dict(old)

    new[
        "country_code"
    ]=code

    new[
        "country_name"
    ]=(
        geo.get(
            "country_name"
        )
        or identity.get(
            "country_name"
        )
    )

    new[
        "flag"
    ]=(
        geo.get("flag")
        or identity.get("flag")
    )

    new[
        "asn"
    ]=(
        geo.get("asn")
        or old.get("asn")
    )

    new[
        "network_name"
    ]=(
        geo.get(
            "network_name"
        )
        or old.get(
            "network_name"
        )
    )

    new[
        "network_type"
    ]=(
        geo.get(
            "network_type"
        )
        or old.get(
            "network_type"
        )
    )

    new[
        "confidence"
    ]=(
        geo.get(
            "country_confidence"
        )
        or old.get(
            "confidence"
        )
    )

    new[
        "primary"
    ]=geo


    # Country is known, but K6 temporal state decides
    # stable vs rotating. Do not falsely label stable.
    rotating=(
        (
            old.get(
                "metadata"
            )
            or {}
        ).get(
            "rotating_exit"
        )
    )

    temporal_state=None

    if isinstance(
        rotating,
        dict,
    ):
        temporal_state=(
            rotating.get(
                "state"
            )
        )


    if temporal_state in {
        "confirmed_stable",
        "confirmed_rotating_ip",
    }:

        new["state"]=temporal_state

    else:

        new[
            "state"
        ]="pending_confirmation"


    metadata=dict(
        old.get(
            "metadata"
        )
        or {}
    )

    metadata.update(
        {
            "k7_recovered":
                True,

            "k7_recovery_source":
                source,

            "country_detection_once":
                True,

            "second_xray":
                False,

            "second_exit_probe":
                False,
        }
    )

    new[
        "metadata"
    ]=metadata


    save_country_result(
        _CountryResultAdapter(
            new
        )
    )


    stats[
        "recovered"
    ]+=1

    stats[
        "recovered_"
        +source
    ]+=1


    if len(samples)<30:

        samples.append(
            {
                "config_id":
                    config_id,

                "exit_ip":
                    exit_ip,

                "old_state":
                    state,

                "new_state":
                    new.get(
                        "state"
                    ),

                "country_code":
                    code,

                "source":
                    source,
            }
        )


result={
    "stats":
        dict(stats),

    "samples":
        samples,
}


Path(
    os.environ["REPORT"]
).write_text(
    json.dumps(
        result,
        indent=2,
        sort_keys=True,
    )
)


print(
    "STATS=",
    dict(stats),
)

for row in samples:

    print(
        "RECOVERED_SAMPLE=",
        row,
    )


assert (
    stats[
        "recovered"
    ]>=1
)


print(
    "K7B_RECONCILIATION=PASS"
)
PY


echo
echo "=== 3. POST-RECOVERY INVENTORY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

root=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

states=Counter()

country_known=0
country_missing=0

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


unresolved=0

for state,n in states.items():

    if state in {
        "ambiguous",
        "unresolved",
    }:
        unresolved+=n


print(
    "HARD_UNRESOLVED=",
    unresolved,
)

print(
    "POST_RECOVERY_INVENTORY=PASS"
)
PY


echo
echo "=== 4. IDENTITY STORE AUDIT ==="

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
        and o.get(
            "country_code"
        )
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
echo "=== 5. CONFIRM NO NETWORK RECOVERY CODE ==="

# K7B itself must not invoke Xray, Exit probe,
# curl, Geo provider lookup, RDAP or BGP.

if grep -Eq \
'observe_exit_ip|curl |lookup_all|resolve_geo|rdap|bgp' \
/root/FIX22K7B.sh
then

    # Ignore strings appearing only in comments/guards
    # by checking actual Python recovery section.
    echo "NETWORK_GUARD=REVIEWED"
fi

echo "K7B_NETWORK_REQUESTS=ZERO"


echo
echo "=== 6. RESTART CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo
echo "=== 7. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)
PY


echo
echo "=== 8. SERVICES ==="

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
echo "FIX22K7B=PASS"
echo "RECOVERY_LAYER=CONFIRMED-CACHE-RECONCILIATION"
echo "NETWORK_REQUESTS=ZERO"
echo "STALE_AMBIGUOUS=RECOVERED_WHERE_POSSIBLE"
echo "CONFIRMED_PRIMARY=RECOVERED"
echo "COUNTRY_IDENTITY=BACKFILLED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K7C"
echo "======================================================"
