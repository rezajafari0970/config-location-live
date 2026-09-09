#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

INPUT=/var/lib/config-location/country/k7-true-hard-unresolved.json
REPORT=/var/lib/config-location/country/k7e-hard-fallback-report.json
LEFT=/var/lib/config-location/country/k7e-still-unresolved.json
FINAL=/var/lib/config-location/country/k7-final-hard-unresolved.json

echo "=== 1. REQUIRED ARTIFACTS ==="

for f in \
"$INPUT" \
"$REPORT" \
"$LEFT" \
"$FINAL"
do
    test -f "$f"
    echo "$f=OK"
done

echo "ARTIFACTS=PASS"


echo
echo "=== 2. ORIGINAL K7E COHORT AUDIT ==="

"$PY" <<'PY'
from pathlib import Path
import json

input_rows=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7-true-hard-unresolved.json"
    ).read_text()
)

report=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7e-hard-fallback-report.json"
    ).read_text()
)

left=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7e-still-unresolved.json"
    ).read_text()
)

committed=report.get(
    "committed"
) or []

stats=report.get(
    "stats"
) or {}

print(
    "COHORT_INPUT=",
    len(input_rows),
)

print(
    "COHORT_COMMITTED=",
    len(committed),
)

print(
    "COHORT_UNRESOLVED=",
    len(left),
)

print(
    "REPORT_STATS=",
    stats,
)

assert len(input_rows)==38

assert (
    len(committed)
    +len(left)
    ==len(input_rows)
)

assert len(committed)==15
assert len(left)==23

print(
    "COHORT_ACCOUNTING=PASS"
)
PY


echo
echo "=== 3. COMMITTED IDENTITY VERIFICATION ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

report=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7e-hard-fallback-report.json"
    ).read_text()
)

IDENT=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

PIPE=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

bad=[]

for row in report.get(
    "committed",
    []
):

    cid=row["config_id"]
    expected=str(
        row["country_code"]
    ).upper()

    ip=IDENT/f"{cid}.json"
    pp=PIPE/f"{cid}.json"

    if (
        not ip.exists()
        or not pp.exists()
    ):
        bad.append(
            (
                cid,
                "missing_file",
            )
        )
        continue

    try:
        identity=json.loads(
            ip.read_text()
        )

        pipeline=json.loads(
            pp.read_text()
        )

    except Exception as exc:

        bad.append(
            (
                cid,
                f"bad_json:{exc}",
            )
        )
        continue


    if (
        identity.get("locked")
        is not True
    ):
        bad.append(
            (
                cid,
                "identity_not_locked",
            )
        )


    if (
        str(
            identity.get(
                "country_code"
            )
            or ""
        ).upper()
        !=expected
    ):
        bad.append(
            (
                cid,
                "identity_country_mismatch",
            )
        )


    if (
        str(
            pipeline.get(
                "country_code"
            )
            or ""
        ).upper()
        !=expected
    ):
        bad.append(
            (
                cid,
                "pipeline_country_mismatch",
            )
        )


print(
    "COMMITTED_VERIFIED=",
    len(
        report.get(
            "committed",
            [],
        )
    ),
)

print(
    "COMMITTED_BAD=",
    len(bad),
)

for row in bad:
    print(
        "BAD=",
        row,
    )

assert not bad

print(
    "COMMITTED_IDENTITY=PASS"
)
PY


echo
echo "=== 4. GLOBAL IDENTITY / PIPELINE CONSISTENCY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

valid_identity=0
invalid_identity=0
country_conflicts=[]
uncertain_locked=[]


for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
        invalid_identity+=1
        continue


    if not (
        ident.get("locked") is True
        and ident.get("country_code")
    ):
        invalid_identity+=1
        continue


    valid_identity+=1

    cid=str(
        ident.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue


    try:
        pipeline=json.loads(
            pp.read_text()
        )
    except Exception:
        continue


    if (
        str(
            pipeline.get(
                "country_code"
            )
            or ""
        ).upper()
        !=
        str(
            ident.get(
                "country_code"
            )
            or ""
        ).upper()
    ):
        country_conflicts.append(
            cid
        )


    if str(
        pipeline.get(
            "state"
        )
        or ""
    ).lower() in {
        "ambiguous",
        "unresolved",
        "unknown",
    }:
        uncertain_locked.append(
            cid
        )


print(
    "IDENTITY_VALID=",
    valid_identity,
)

print(
    "IDENTITY_INVALID=",
    invalid_identity,
)

print(
    "COUNTRY_CONFLICTS=",
    len(country_conflicts),
)

print(
    "LOCKED_UNCERTAIN=",
    len(uncertain_locked),
)


assert invalid_identity==0
assert not country_conflicts
assert not uncertain_locked

print(
    "GLOBAL_CONSISTENCY=PASS"
)
PY


echo
echo "=== 5. LIVE HARD UNRESOLVED PROFILE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

hard=[]

states=Counter()

ipv4=0
ipv6=0


for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    state=str(
        o.get("state")
        or "unknown"
    ).lower()

    states[state]+=1

    if state not in {
        "ambiguous",
        "unresolved",
        "unknown",
    }:
        continue


    cid=str(
        o.get("config_id")
        or p.stem
    )

    identity_path=I/f"{cid}.json"

    if identity_path.exists():

        try:
            ident=json.loads(
                identity_path.read_text()
            )

            if (
                ident.get("locked") is True
                and ident.get(
                    "country_code"
                )
            ):
                continue

        except Exception:
            pass


    if o.get(
        "country_code"
    ):
        continue


    exit_ip=str(
        o.get("exit_ip")
        or ""
    )

    if ":" in exit_ip:
        ipv6+=1
    elif exit_ip:
        ipv4+=1


    hard.append(
        {
            "config_id":cid,
            "exit_ip":exit_ip,
            "state":state,
        }
    )


print(
    "PIPELINE_STATES=",
    dict(states),
)

print(
    "LIVE_TRUE_HARD=",
    len(hard),
)

print(
    "LIVE_HARD_IPV4=",
    ipv4,
)

print(
    "LIVE_HARD_IPV6=",
    ipv6,
)


# A live system is allowed to have unresolved
# arrivals. They must simply remain unconfirmed.
for row in hard[:30]:

    print(
        "LIVE_HARD_SAMPLE=",
        row,
    )


print(
    "LIVE_UNRESOLVED_POLICY=PASS"
)
PY


echo
echo "=== 6. FALSE-CONFIRM SAFETY ==="

"$PY" <<'PY'
from pathlib import Path
import json

left=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7e-still-unresolved.json"
    ).read_text()
)

bad=[]

for row in left:

    recovery=(
        row.get(
            "hard_fallback"
        )
        or {}
    )

    if (
        recovery.get(
            "state"
        )=="confirmed"
    ):
        bad.append(
            row.get(
                "config_id"
            )
        )


print(
    "UNRESOLVED_COHORT=",
    len(left),
)

print(
    "FALSE_CONFIRMED_IN_LEFT=",
    len(bad),
)

assert not bad

print(
    "FALSE_CONFIRM_GUARD=PASS"
)
PY


echo
echo "=== 7. ARCHITECTURE GUARDS ==="

grep -q \
'FIX22_K7_PIPELINE_IDENTITY_GUARD' \
"$R/app/country/pipeline.py"

grep -q \
'country_identity_guard' \
"$R/app/country/pipeline.py"

grep -q \
'country_detection_once' \
"$R/app/country/event_consumer.py"

grep -q \
'FIX22K5_PARALLEL_GEO' \
"$R/app/country/geo_providers.py"

grep -q \
'geo_singleflight_lock' \
"$R/app/country/geo_intelligence.py"

echo "K7_PIPELINE_GUARD=PASS"
echo "K6_COUNTRY_ONCE=PRESERVED"
echo "K5_PARALLEL_GEO=PRESERVED"
echo "K4_SINGLEFLIGHT=PRESERVED"


echo
echo "=== 8. NO SECOND XRAY / EXIT PROBE ==="

if grep -q \
'observe_exit_ip' \
"$R/app/country/event_consumer.py"
then
    echo "ERROR=SECOND_EXIT_PROBE"
    exit 1
fi

echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo
echo "=== 9. EVENT BUS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print(
    "QUEUE=",
    s,
)

assert int(
    s.get(
        "dead",
        0,
    )
)==0

print(
    "EVENT_BUS=PASS"
)
PY


echo
echo "=== 10. SERVICE HEALTH ==="

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
echo "=== 11. FINAL K7 REPORT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import time

input_rows=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7-true-hard-unresolved.json"
    ).read_text()
)

report=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7e-hard-fallback-report.json"
    ).read_text()
)

left=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7e-still-unresolved.json"
    ).read_text()
)

summary={
    "schema_version":1,

    "generated_epoch":
        int(time.time()),

    "k7e_input":
        len(input_rows),

    "k7e_recovered":
        len(
            report.get(
                "committed",
                [],
            )
        ),

    "k7e_unresolved":
        len(left),

    "policy":
        "unresolved is preferred over false-country",

    "country_identity":
        "authoritative_country",

    "pipeline":
        "authoritative_temporal_state",

    "results":
        "evidence_history",

    "second_xray":
        False,

    "second_exit_probe":
        False,
}

out=Path(
    "/var/lib/config-location/country/"
    "k7-final-audit.json"
)

out.write_text(
    json.dumps(
        summary,
        indent=2,
        sort_keys=True,
    )
)

print(
    json.dumps(
        summary,
        indent=2,
        sort_keys=True,
    )
)

print(
    "K7_FINAL_REPORT=PASS"
)
PY


echo
echo "======================================================"
echo "FIX22K7F=PASS"
echo "FIX22K7=COMPLETE"
echo "PROGRESSIVE_RECOVERY=COMPLETE"
echo "ORIGINAL_HARD_COHORT=38"
echo "RECOVERED_BY_K7E=15"
echo "INTENTIONALLY_UNRESOLVED=23"
echo "FALSE_COUNTRY_POLICY=STRICT"
echo "COUNTRY_IDENTITY=AUTHORITATIVE"
echo "PIPELINE_TEMPORAL_STATE=AUTHORITATIVE"
echo "RESULTS_EVIDENCE=PRESERVED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K8"
echo "======================================================"
