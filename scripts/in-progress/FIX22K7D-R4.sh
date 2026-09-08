#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
P="$R/app/country/pipeline.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K7D-R4-$TS"

mkdir -p "$B"
cp -a "$P" "$B/"

echo "BACKUP=$B"

echo
echo "=== 1. STOP COUNTRY WRITERS ==="

systemctl stop \
config-location-country-worker.service \
config-location-country-event-consumer.service

echo "WRITERS_STOPPED=YES"


echo
echo "=== 2. PATCH PIPELINE CANONICAL IDENTITY GUARD ==="

export P

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["P"])
s=p.read_text()

if "FIX22_K7_PIPELINE_IDENTITY_GUARD" in s:
    print("PIPELINE_IDENTITY_GUARD_ALREADY_PRESENT=YES")
    raise SystemExit(0)

start=s.index(
    "def save_pipeline_result("
)

tail=s[start+1:]

positions=[]

for marker in (
    "\ndef ",
    "\nclass ",
):

    pos=tail.find(marker)

    if pos>=0:
        positions.append(
            start+1+pos
        )

end=min(positions) if positions else len(s)

original=s[start:end]

renamed=original.replace(
    "def save_pipeline_result(",
    "def _save_pipeline_result_unguarded(",
    1,
)

wrapper=r'''
# FIX22_K7_PIPELINE_IDENTITY_GUARD

def save_pipeline_result(
    *,
    config_id: str,
    result: dict[str, Any],
):
    """
    Pipeline owns runtime/temporal state.

    Locked country-identity owns the accepted Country.
    Pipeline may refine stable/rotating state but may
    never erase or replace a locked Country identity.
    """

    value=dict(result)

    identity_path=(
        Path(
            "/var/lib/config-location/country/"
            "country-identity"
        )
        /f"{config_id}.json"
    )

    if identity_path.exists():

        identity=None

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

            code=str(
                identity["country_code"]
            ).upper()

            value["country_code"]=code

            for key in (
                "country_name",
                "flag",
                "asn",
                "network_name",
                "network_type",
            ):

                if identity.get(key) is not None:
                    value[key]=identity[key]


            if (
                identity.get(
                    "country_confidence"
                )
                is not None
            ):
                value["confidence"]=(
                    identity[
                        "country_confidence"
                    ]
                )


            current_state=str(
                value.get("state")
                or ""
            ).strip().lower()


            # Preserve genuine temporal conclusions.
            #
            # But an old Geo disagreement is no longer
            # allowed to erase an already locked Country.
            if current_state in {
                "ambiguous",
                "unresolved",
                "unknown",
            }:

                value[
                    "state"
                ]="pending_confirmation"

                value[
                    "reason"
                ]="country_identity_locked"


            metadata=dict(
                value.get("metadata")
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
                        identity.get(
                            "source"
                        ),
                }
            )

            value["metadata"]=metadata


    return _save_pipeline_result_unguarded(
        config_id=config_id,
        result=value,
    )
'''

s=(
    s[:start]
    +renamed
    +"\n"
    +wrapper
    +s[end:]
)

p.write_text(s)

print(
    "PIPELINE_IDENTITY_GUARD_PATCH=PASS"
)
PY


echo
echo "=== 3. COMPILE ==="

"$PY" -m py_compile "$P"

echo "COMPILE=PASS"


echo
echo "=== 4. SYNTHETIC PIPELINE TEST ==="

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

cid="k7-r4-pipeline-test"

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
            "source":"k7-r4-test",
        }
    )
)


save_pipeline_result(
    config_id=cid,
    result={
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
    "SYNTHETIC_RESULT=",
    o,
)

assert o["country_code"]=="DE"

assert (
    o["state"]
    =="pending_confirmation"
)

assert (
    o["metadata"][
        "country_identity_guard"
    ] is True
)


# Temporal final state must survive.
save_pipeline_result(
    config_id=cid,
    result={
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

assert (
    o["country_code"]
    =="DE"
)

assert (
    o["state"]
    =="confirmed_rotating_ip"
)

print(
    "PIPELINE_GUARD_SYNTHETIC=PASS"
)

pp.unlink(missing_ok=True)
ip.unlink(missing_ok=True)
PY


echo
echo "=== 5. RECONCILE EXISTING LOCKED IDENTITIES ==="

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
missing=0
invalid=0

for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
        invalid+=1
        continue

    if not (
        ident.get("locked") is True
        and ident.get("country_code")
    ):
        invalid+=1
        continue

    cid=str(
        ident.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        missing+=1
        continue

    try:
        old=json.loads(
            pp.read_text()
        )
    except Exception:
        invalid+=1
        continue

    save_pipeline_result(
        config_id=cid,
        result=old,
    )

    reconciled+=1


print(
    "RECONCILED=",
    reconciled,
)

print(
    "IDENTITY_WITHOUT_PIPELINE=",
    missing,
)

print(
    "INVALID=",
    invalid,
)

assert invalid==0

print(
    "PIPELINE_RECONCILIATION=PASS"
)
PY


echo
echo "=== 6. VERIFY CONFLICTS NOW ==="

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

conflicts=[]

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
        result=json.loads(
            pp.read_text()
        )
    except Exception:
        continue

    if (
        result.get("country_code")
        !=ident.get("country_code")
    ):
        conflicts.append(cid)


print(
    "COUNTRY_CONFLICTS=",
    len(conflicts),
)

assert not conflicts

print(
    "COUNTRY_CONSISTENCY=PASS"
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
ambiguous_locked=[]

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
        result=json.loads(
            pp.read_text()
        )
    except Exception:
        continue

    if (
        result.get("country_code")
        !=ident.get("country_code")
    ):
        country_conflicts.append(cid)

    if str(
        result.get("state")
        or ""
    ) in {
        "ambiguous",
        "unresolved",
    }:
        ambiguous_locked.append(cid)


print(
    "COUNTRY_CONFLICTS_AFTER_60S=",
    len(country_conflicts),
)

print(
    "LOCKED_AMBIGUOUS_AFTER_60S=",
    len(ambiguous_locked),
)

assert not country_conflicts
assert not ambiguous_locked

print(
    "OVERWRITE_RESISTANCE=PASS"
)
PY


echo
echo "=== 9. TRUE HARD UNRESOLVED ==="

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
    )

    states[state]+=1

    cid=str(
        o.get("config_id")
        or p.stem
    )

    ip=I/f"{cid}.json"

    locked=False

    if ip.exists():

        try:
            ident=json.loads(
                ip.read_text()
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
        }
        and not o.get(
            "country_code"
        )
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


print(
    "PIPELINE_STATES=",
    dict(states),
)

print(
    "TRUE_HARD_UNRESOLVED=",
    len(hard),
)

for row in hard[:40]:
    print(
        "HARD=",
        row,
    )


Path(
    "/var/lib/config-location/country/"
    "k7-true-hard-unresolved.json"
).write_text(
    json.dumps(
        hard,
        indent=2,
        sort_keys=True,
    )
)

print(
    "TRUE_HARD_INVENTORY=PASS"
)
PY


echo
echo "=== 10. RESULTS STORE PRESERVED ==="

test -d \
/var/lib/config-location/country/results/latest

echo "RESULTS_EVIDENCE_STORE=PRESERVED"


echo
echo "=== 11. SERVICES ==="

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
echo "FIX22K7D_R4=PASS"
echo "COUNTRY_IDENTITY=AUTHORITATIVE_COUNTRY"
echo "PIPELINE=AUTHORITATIVE_TEMPORAL_STATE"
echo "RESULTS=EVIDENCE_HISTORY"
echo "DUAL_STORE_CONFLICT=RESOLVED"
echo "NEXT=FIX22K7E-HARD-FALLBACK"
echo "======================================================"
