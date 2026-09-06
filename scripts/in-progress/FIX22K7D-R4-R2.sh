#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
P="$R/app/country/pipeline.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K7D-R4-R2-$TS"

mkdir -p "$B"
cp -a "$P" "$B/pipeline.py.before"

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
echo "=== 2. FIX EXACT PIPELINE SIGNATURE ==="

export P

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["P"])
s=p.read_text()

start=s.index(
    "# FIX22_K7_PIPELINE_IDENTITY_GUARD"
)

end=s.index(
    "\ndef process_country(",
    start,
)

replacement=r'''# FIX22_K7_PIPELINE_IDENTITY_GUARD

def save_pipeline_result(
    *,
    config_id: str,
    value: dict[str, Any],
) -> None:
    """
    Pipeline owns temporal/runtime state.

    Locked country-identity owns accepted Country.
    Pipeline may refine stable/rotating state but may
    not erase or replace a locked Country.
    """

    guarded=dict(value)

    identity_path=(
        Path(
            "/var/lib/config-location/country/"
            "country-identity"
        )
        / f"{config_id}.json"
    )

    identity=None

    if identity_path.exists():
        try:
            identity=json.loads(
                identity_path.read_text()
            )
        except Exception:
            identity=None


    if (
        isinstance(identity,dict)
        and identity.get("locked") is True
        and identity.get("country_code")
    ):

        guarded["country_code"]=str(
            identity["country_code"]
        ).upper()


        for key in (
            "country_name",
            "flag",
            "asn",
            "network_name",
            "network_type",
        ):
            if identity.get(key) is not None:
                guarded[key]=identity[key]


        if (
            identity.get(
                "country_confidence"
            )
            is not None
        ):
            guarded["confidence"]=(
                identity[
                    "country_confidence"
                ]
            )


        state=str(
            guarded.get("state")
            or ""
        ).strip().lower()


        # Do not destroy genuine temporal conclusions.
        # Only Geo-uncertain states are normalized.
        if state in {
            "ambiguous",
            "unresolved",
            "unknown",
        }:
            guarded[
                "state"
            ]="pending_confirmation"

            guarded[
                "reason"
            ]="country_identity_locked"


        metadata=dict(
            guarded.get("metadata")
            or {}
        )

        metadata.update(
            {
                "country_identity_guard":
                    True,

                "country_identity_locked":
                    True,

                "country_detection_once":
                    True,

                "country_identity_source":
                    identity.get("source"),
            }
        )

        guarded["metadata"]=metadata


    return _save_pipeline_result_unguarded(
        config_id=config_id,
        value=guarded,
    )
'''

p.write_text(
    s[:start]
    +replacement
    +s[end:]
)

print(
    "PIPELINE_SIGNATURE_FIX=PASS"
)
PY


echo
echo "=== 3. COMPILE + SIGNATURE VERIFY ==="

"$PY" -m py_compile "$P"

PYTHONPATH="$R" "$PY" <<'PY'
import inspect
from app.country.pipeline import (
    save_pipeline_result,
    _save_pipeline_result_unguarded,
)

print(
    "PUBLIC_SIGNATURE=",
    inspect.signature(
        save_pipeline_result
    )
)

print(
    "PRIVATE_SIGNATURE=",
    inspect.signature(
        _save_pipeline_result_unguarded
    )
)

assert "value" in inspect.signature(
    save_pipeline_result
).parameters

assert "value" in inspect.signature(
    _save_pipeline_result_unguarded
).parameters

print(
    "SIGNATURE_CONTRACT=PASS"
)
PY


echo
echo "=== 4. SYNTHETIC IDENTITY GUARD TEST ==="

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

cid="k7-r4-r2-test"

ip=I/f"{cid}.json"
pp=P/f"{cid}.json"

ip.unlink(missing_ok=True)
pp.unlink(missing_ok=True)

I.mkdir(
    parents=True,
    exist_ok=True,
)

ip.write_text(
    json.dumps(
        {
            "schema_version":1,
            "config_id":cid,
            "locked":True,
            "country_code":"DE",
            "country_name":"Germany",
            "source":"k7-r4-r2-test",
        }
    )
)


# Old ambiguous writer must not erase Country.
save_pipeline_result(
    config_id=cid,
    value={
        "schema_version":1,
        "config_id":cid,
        "state":"ambiguous",
        "country_code":None,
        "exit_ip":"1.1.1.1",
        "metadata":{},
    },
)

assert pp.exists()

o=json.loads(
    pp.read_text()
)

print(
    "AMBIGUOUS_GUARDED=",
    o,
)

assert o["country_code"]=="DE"
assert o["state"]=="pending_confirmation"

assert (
    o["metadata"][
        "country_identity_guard"
    ] is True
)


# Genuine temporal final state must remain final.
save_pipeline_result(
    config_id=cid,
    value={
        "schema_version":1,
        "config_id":cid,
        "state":"confirmed_rotating_ip",
        "country_code":None,
        "exit_ip":"2.2.2.2",
        "metadata":{},
    },
)

o=json.loads(
    pp.read_text()
)

print(
    "TEMPORAL_GUARDED=",
    o,
)

assert o["country_code"]=="DE"

assert (
    o["state"]
    =="confirmed_rotating_ip"
)

print(
    "SYNTHETIC_GUARD=PASS"
)

pp.unlink(missing_ok=True)
ip.unlink(missing_ok=True)
PY


echo
echo "=== 5. RECONCILE LOCKED IDENTITIES INTO PIPELINE ==="

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

reconciled=0
missing_pipeline=0
invalid_identity=0


for ip in I.glob("*.json"):

    try:
        identity=json.loads(
            ip.read_text()
        )
    except Exception:
        invalid_identity+=1
        continue


    if not (
        identity.get("locked") is True
        and identity.get("country_code")
    ):
        invalid_identity+=1
        continue


    cid=str(
        identity.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        missing_pipeline+=1
        continue


    try:
        current=json.loads(
            pp.read_text()
        )
    except Exception:
        continue


    save_pipeline_result(
        config_id=cid,
        value=current,
    )

    reconciled+=1


print(
    "RECONCILED=",
    reconciled,
)

print(
    "IDENTITY_WITHOUT_PIPELINE=",
    missing_pipeline,
)

print(
    "INVALID_IDENTITY=",
    invalid_identity,
)

print(
    "RECONCILIATION=PASS"
)
PY


echo
echo "=== 6. IMMEDIATE CONSISTENCY AUDIT ==="

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

country_conflicts=[]
ambiguous_locked=[]


for ip in I.glob("*.json"):

    try:
        identity=json.loads(
            ip.read_text()
        )
    except Exception:
        continue

    if not (
        identity.get("locked") is True
        and identity.get("country_code")
    ):
        continue


    cid=str(
        identity.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue


    try:
        result=json.loads(
            pp.read_text()
        )
    except Exception:
        continue


    if (
        str(result.get("country_code") or "").upper()
        !=
        str(identity.get("country_code") or "").upper()
    ):
        country_conflicts.append(cid)


    if str(
        result.get("state")
        or ""
    ).lower() in {
        "ambiguous",
        "unresolved",
        "unknown",
    }:
        ambiguous_locked.append(cid)


print(
    "COUNTRY_CONFLICTS=",
    len(country_conflicts),
)

print(
    "LOCKED_UNCERTAIN_STATES=",
    len(ambiguous_locked),
)

assert not country_conflicts
assert not ambiguous_locked

print(
    "IMMEDIATE_CONSISTENCY=PASS"
)
PY


echo
echo "=== 7. START WRITERS ==="

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
echo "=== 8. 60 SECOND OVERWRITE RESISTANCE ==="

sleep 60

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

country_conflicts=[]
uncertain_locked=[]


for ip in I.glob("*.json"):

    try:
        identity=json.loads(
            ip.read_text()
        )
    except Exception:
        continue


    if not (
        identity.get("locked") is True
        and identity.get("country_code")
    ):
        continue


    cid=str(
        identity.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue


    try:
        result=json.loads(
            pp.read_text()
        )
    except Exception:
        continue


    if (
        str(result.get("country_code") or "").upper()
        !=
        str(identity.get("country_code") or "").upper()
    ):
        country_conflicts.append(cid)


    if str(
        result.get("state")
        or ""
    ).lower() in {
        "ambiguous",
        "unresolved",
        "unknown",
    }:
        uncertain_locked.append(cid)


print(
    "COUNTRY_CONFLICTS_AFTER_60S=",
    len(country_conflicts),
)

print(
    "LOCKED_UNCERTAIN_AFTER_60S=",
    len(uncertain_locked),
)

assert not country_conflicts
assert not uncertain_locked

print(
    "OVERWRITE_RESISTANCE=PASS"
)
PY


echo
echo "=== 9. TRUE HARD UNRESOLVED INVENTORY ==="

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

states=Counter()
hard=[]


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


    cid=str(
        o.get("config_id")
        or p.stem
    )

    identity_path=I/f"{cid}.json"

    locked=False

    if identity_path.exists():

        try:
            ident=json.loads(
                identity_path.read_text()
            )

            locked=(
                ident.get("locked") is True
                and bool(
                    ident.get(
                        "country_code"
                    )
                )
            )

        except Exception:
            pass


    if (
        state in {
            "ambiguous",
            "unresolved",
            "unknown",
        }
        and not o.get("country_code")
        and not locked
    ):
        hard.append(
            {
                "config_id":cid,
                "exit_ip":
                    o.get("exit_ip"),
                "state":state,
            }
        )


out=Path(
    "/var/lib/config-location/country/"
    "k7-true-hard-unresolved.json"
)

out.write_text(
    json.dumps(
        hard,
        indent=2,
        sort_keys=True,
    )
)


print(
    "PIPELINE_STATES=",
    dict(states),
)

print(
    "TRUE_HARD_UNRESOLVED=",
    len(hard),
)

for row in hard[:30]:
    print(
        "HARD=",
        row,
    )

print(
    "HARD_INVENTORY_PATH=",
    out,
)

print(
    "TRUE_HARD_INVENTORY=PASS"
)
PY


echo
echo "=== 10. RESULTS EVIDENCE STORE CHECK ==="

test -d \
/var/lib/config-location/country/results/latest

echo "RESULTS_STORE=PRESERVED"


echo
echo "=== 11. ALL SERVICES ==="

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


trap - EXIT

echo
echo "======================================================"
echo "FIX22K7D_R4_R2=PASS"
echo "COUNTRY_IDENTITY=AUTHORITATIVE_COUNTRY"
echo "PIPELINE=AUTHORITATIVE_TEMPORAL_STATE"
echo "RESULTS=EVIDENCE_HISTORY"
echo "DUAL_STORE_CONFLICT=RESOLVED"
echo "NEXT=FIX22K7E-HARD-FALLBACK"
echo "======================================================"
