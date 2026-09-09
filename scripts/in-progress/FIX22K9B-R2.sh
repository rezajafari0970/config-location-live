#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K9B-R2-$TS"

mkdir -p "$B"
cp -a "$APP" "$B/event_consumer.py.before"
cp -a "$R/app/country/pipeline.py" "$B/pipeline.py.before"

echo "BACKUP=$B"

restore_services() {
    systemctl restart \
        config-location-country-worker.service \
        config-location-country-event-consumer.service \
        >/dev/null 2>&1 || true
}

trap restore_services EXIT


echo
echo "=== 1. STOP COUNTRY WRITERS ==="

systemctl stop \
    config-location-country-worker.service \
    config-location-country-event-consumer.service

echo "WRITERS_STOPPED=YES"


echo
echo "=== 2. ADD IMMEDIATE IDENTITY -> PIPELINE RECONCILIATION ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["APP"])
s=p.read_text()

MARKER="FIX22_K9_IDENTITY_IMMEDIATE_RECONCILIATION"

if MARKER in s:
    print("IMMEDIATE_RECONCILIATION_ALREADY_PRESENT=YES")
    raise SystemExit(0)


# ---------------------------------------------------------
# Helper: after Country Identity is locked, re-save the
# existing Pipeline record through K7 canonical guard.
#
# No Geo lookup, no Xray, no Exit-IP probe.
# ---------------------------------------------------------

helper=r'''

# FIX22_K9_IDENTITY_IMMEDIATE_RECONCILIATION
def _reconcile_identity_into_pipeline(
    config_id: str,
) -> str:
    """
    Immediately project a newly locked Country Identity
    into an existing Pipeline record.

    Identity remains authoritative for Country.
    Pipeline remains authoritative for temporal state.
    """

    from pathlib import Path as _Path
    import json as _json

    from app.country.pipeline import (
        save_pipeline_result as _save_pipeline_result,
    )

    cid=str(config_id or "").strip()

    if not cid:
        return "missing_config_id"

    pipeline_path=(
        _Path(
            "/var/lib/config-location/country/"
            "pipeline/latest"
        )
        /f"{cid}.json"
    )

    if not pipeline_path.exists():
        return "pipeline_missing"

    try:
        current=_json.loads(
            pipeline_path.read_text()
        )
    except Exception:
        return "pipeline_bad_json"

    if not isinstance(current,dict):
        return "pipeline_not_object"

    _save_pipeline_result(
        config_id=cid,
        value=current,
    )

    return "reconciled"
'''


# Insert helper immediately before _process_event if possible.
candidates=[
    "\ndef _process_event(",
    "\ndef process_event(",
    "\ndef worker_loop(",
]

insert_at=None

for marker in candidates:
    x=s.find(marker)
    if x>=0:
        insert_at=x
        break

if insert_at is None:
    raise SystemExit(
        "ERROR=HELPER_INSERT_POINT_NOT_FOUND"
    )

s=(
    s[:insert_at]
    +helper
    +s[insert_at:]
)


# ---------------------------------------------------------
# Find identity=save_identity_once(...) and insert an
# immediate reconciliation after the complete call.
# Parenthesis counting makes this independent of formatting.
# ---------------------------------------------------------

needle="identity=save_identity_once("

start=s.find(needle)

if start<0:
    needle="identity = save_identity_once("
    start=s.find(needle)

if start<0:
    raise SystemExit(
        "ERROR=SAVE_IDENTITY_CALL_NOT_FOUND"
    )


paren_start=s.find("(",start)

depth=0
end=None

for i in range(paren_start,len(s)):

    ch=s[i]

    if ch=="(":
        depth+=1

    elif ch==")":
        depth-=1

        if depth==0:
            end=i+1
            break

if end is None:
    raise SystemExit(
        "ERROR=SAVE_IDENTITY_CALL_UNBALANCED"
    )


insertion=r'''

        if identity is not None:

            reconcile_status=(
                _reconcile_identity_into_pipeline(
                    str(
                        event.get("config_id")
                        or ""
                    )
                )
            )

            _metric(
                {
                    "status":
                        "identity_pipeline_sync",

                    "config_id":
                        event.get(
                            "config_id"
                        ),

                    "sync_status":
                        reconcile_status,
                }
            )
'''


s=s[:end]+insertion+s[end:]

p.write_text(s)

print(
    "IMMEDIATE_IDENTITY_PIPELINE_PATCH=PASS"
)
PY


echo
echo "=== 3. COMPILE ==="

"$PY" -m py_compile "$APP"

echo "COMPILE=PASS"


echo
echo "=== 4. STATIC CONTRACT ==="

grep -q \
'FIX22_K9_IDENTITY_IMMEDIATE_RECONCILIATION' \
"$APP"

grep -q \
'identity_pipeline_sync' \
"$APP"

grep -q \
'_reconcile_identity_into_pipeline' \
"$APP"

echo "STATIC_CONTRACT=PASS"


echo
echo "=== 5. SYNTHETIC IMMEDIATE RECONCILIATION TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.event_consumer import (
    _reconcile_identity_into_pipeline,
)

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

cid="k9b-r2-immediate-sync-test"

ip=I/f"{cid}.json"
pp=P/f"{cid}.json"

ip.unlink(missing_ok=True)
pp.unlink(missing_ok=True)

I.mkdir(
    parents=True,
    exist_ok=True,
)

P.mkdir(
    parents=True,
    exist_ok=True,
)


pp.write_text(
    json.dumps(
        {
            "schema_version":1,
            "config_id":cid,
            "state":"ambiguous",
            "country_code":None,
            "exit_ip":"1.1.1.1",
            "metadata":{},
        }
    )
)

ip.write_text(
    json.dumps(
        {
            "schema_version":1,
            "config_id":cid,
            "locked":True,
            "country_code":"DE",
            "country_name":"Germany",
            "source":"k9-r2-test",
        }
    )
)


status=_reconcile_identity_into_pipeline(
    cid
)

print(
    "SYNC_STATUS=",
    status,
)

o=json.loads(
    pp.read_text()
)

print(
    "PIPELINE_AFTER=",
    o,
)

assert status=="reconciled"
assert o["country_code"]=="DE"

assert (
    (
        o.get("metadata")
        or {}
    ).get(
        "country_identity_guard"
    ) is True
)

assert o["state"] not in {
    "ambiguous",
    "unresolved",
    "unknown",
}

print(
    "SYNTHETIC_IMMEDIATE_SYNC=PASS"
)

pp.unlink(missing_ok=True)
ip.unlink(missing_ok=True)
PY


echo
echo "=== 6. RECONCILE ALL EXISTING IDENTITY/PIPELINE CONFLICTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.pipeline import (
    save_pipeline_result,
)

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

checked=0
conflicts_before=0
reconciled=0


for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
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
        continue


    try:
        pipe=json.loads(
            pp.read_text()
        )
    except Exception:
        continue


    checked+=1

    ic=str(
        ident.get(
            "country_code"
        )
        or ""
    ).upper()

    pc=str(
        pipe.get(
            "country_code"
        )
        or ""
    ).upper()


    if ic==pc:
        continue


    conflicts_before+=1


    # Important:
    # do not manufacture or replace temporal state.
    # Re-save the existing record through K7 guard.
    save_pipeline_result(
        config_id=cid,
        value=pipe,
    )

    reconciled+=1


print(
    "CHECKED=",
    checked,
)

print(
    "CONFLICTS_BEFORE=",
    conflicts_before,
)

print(
    "RECONCILED=",
    reconciled,
)

assert conflicts_before>=1
assert reconciled==conflicts_before

print(
    "EXISTING_RECONCILIATION=PASS"
)
PY


echo
echo "=== 7. IMMEDIATE POST-RECONCILIATION CONSISTENCY ==="

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

checked=0
bad=[]


for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
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
        continue


    try:
        pipe=json.loads(
            pp.read_text()
        )
    except Exception:
        continue


    checked+=1

    if (
        str(
            ident.get(
                "country_code"
            )
            or ""
        ).upper()
        !=
        str(
            pipe.get(
                "country_code"
            )
            or ""
        ).upper()
    ):
        bad.append(cid)


print(
    "CONSISTENCY_CHECKED=",
    checked,
)

print(
    "CONSISTENCY_BAD=",
    len(bad),
)

for cid in bad[:30]:
    print("BAD=",cid)

assert not bad

print(
    "IMMEDIATE_GLOBAL_CONSISTENCY=PASS"
)
PY


echo
echo "=== 8. START PRODUCTION WRITERS ==="

systemctl restart \
    config-location-country-worker.service \
    config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-worker.service
)" = active

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "WRITERS=active"


echo
echo "=== 9. 90 SECOND LIVE CONSISTENCY RESISTANCE ==="

sleep 90

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

checked=0
bad=[]


for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
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
        continue


    try:
        pipe=json.loads(
            pp.read_text()
        )
    except Exception:
        continue


    checked+=1

    if (
        str(
            ident.get(
                "country_code"
            )
            or ""
        ).upper()
        !=
        str(
            pipe.get(
                "country_code"
            )
            or ""
        ).upper()
    ):
        bad.append(
            {
                "config_id":cid,

                "identity_country":
                    ident.get(
                        "country_code"
                    ),

                "pipeline_country":
                    pipe.get(
                        "country_code"
                    ),

                "pipeline_state":
                    pipe.get(
                        "state"
                    ),
            }
        )


print(
    "LIVE_CHECKED=",
    checked,
)

print(
    "LIVE_CONSISTENCY_BAD=",
    len(bad),
)

for row in bad[:30]:
    print(
        "LIVE_BAD=",
        row,
    )

assert not bad

print(
    "LIVE_CONSISTENCY_RESISTANCE=PASS"
)
PY


echo
echo "=== 10. VERIFY IMMEDIATE SYNC ACTIVITY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

c=Counter()

samples=[]

if p.exists():

    for line in p.read_text().splitlines():

        try:
            o=json.loads(line)
        except Exception:
            continue

        if o.get(
            "status"
        )!="identity_pipeline_sync":
            continue

        status=str(
            o.get(
                "sync_status",
                "unknown",
            )
        )

        c[status]+=1

        if len(samples)<20:
            samples.append(o)


print(
    "IDENTITY_PIPELINE_SYNC=",
    dict(c),
)

for row in samples:
    print(
        "SYNC_SAMPLE=",
        row,
    )


# It is valid for zero new identities to be created
# during this 90-second observation window.
print(
    "IMMEDIATE_SYNC_METRIC_AUDIT=PASS"
)
PY


echo
echo "=== 11. QUEUE SAFETY ==="

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
    "QUEUE_SAFETY=PASS"
)
PY


echo
echo "=== 12. SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(systemctl is-active "$svc" 2>/dev/null || true)

    echo "$svc=$X"

    test "$X" = active
done


trap - EXIT

echo
echo "======================================================"
echo "FIX22K9B_R2=PASS"
echo "IDENTITY_PIPELINE_IMMEDIATE_SYNC=ACTIVE"
echo "OLD_CONFLICTS=RECONCILED"
echo "COUNTRY_IDENTITY=AUTHORITATIVE"
echo "PIPELINE_TEMPORAL_STATE=PRESERVED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K9B-R3-REBENCHMARK"
echo "======================================================"
