#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

STORE="$R/app/country/storage.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K7D-R2-$TS"

mkdir -p "$B"
cp -a "$STORE" "$B/"

echo "BACKUP=$B"

echo
echo "=== 1. STOP COUNTRY WRITERS ==="

systemctl stop \
config-location-country-event-consumer.service \
config-location-country-worker.service

echo "WRITERS_STOPPED=YES"


echo
echo "=== 2. PATCH STORAGE IDENTITY GUARD ==="

export STORE

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["STORE"])
s=p.read_text()

if "FIX22_K7_IDENTITY_WRITE_GUARD" in s:
    print("IDENTITY_WRITE_GUARD_ALREADY_PRESENT=YES")
    raise SystemExit(0)

start=s.index(
    "def save_country_result("
)

# Find next top-level function.
tail=s[start+1:]

next_pos=None

for marker in (
    "\ndef load_",
    "\ndef read_",
    "\ndef list_",
    "\ndef delete_",
    "\ndef ",
):

    x=tail.find(marker)

    if x>=0:
        pos=start+1+x

        if (
            next_pos is None
            or pos<next_pos
        ):
            next_pos=pos

if next_pos is None:
    next_pos=len(s)

original=s[start:next_pos]

# Rename canonical implementation.
renamed=original.replace(
    "def save_country_result(",
    "def _save_country_result_unguarded(",
    1,
)

wrapper=r'''
# FIX22_K7_IDENTITY_WRITE_GUARD

def save_country_result(
    result,
):
    """
    Canonical Country write boundary.

    Once K6/K7 Country Identity is locked, an older
    worker is not allowed to overwrite that Country
    with ambiguous/unresolved output.
    """

    import json as _json
    from pathlib import Path as _Path

    try:
        value=result.to_dict()
    except AttributeError:
        value=dict(result)

    config_id=str(
        value.get("config_id")
        or ""
    )

    if config_id:

        identity_path=(
            _Path(
                "/var/lib/config-location/country/"
                "country-identity"
            )
            /f"{config_id}.json"
        )

        if identity_path.exists():

            try:
                identity=_json.loads(
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

                if identity.get("country_name"):
                    value["country_name"]=identity[
                        "country_name"
                    ]

                if identity.get("flag"):
                    value["flag"]=identity["flag"]

                if identity.get("asn"):
                    value["asn"]=identity["asn"]

                if identity.get("network_name"):
                    value["network_name"]=identity[
                        "network_name"
                    ]

                if identity.get("network_type"):
                    value["network_type"]=identity[
                        "network_type"
                    ]

                if identity.get("country_confidence") is not None:
                    value["confidence"]=identity[
                        "country_confidence"
                    ]

                current_state=str(
                    value.get("state")
                    or ""
                )

                # Country is known. An old ambiguous/
                # unresolved result may not erase it.
                if current_state in {
                    "ambiguous",
                    "unresolved",
                }:
                    value[
                        "state"
                    ]="pending_confirmation"

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
                    }
                )

                value["metadata"]=metadata


                class _GuardedResult:
                    def __init__(self,v):
                        self._v=v

                    def to_dict(self):
                        return dict(self._v)

                    def __getattr__(self,name):
                        try:
                            return self._v[name]
                        except KeyError as exc:
                            raise AttributeError(
                                name
                            ) from exc


                result=_GuardedResult(
                    value
                )


    return _save_country_result_unguarded(
        result
    )
'''

s=(
    s[:start]
    +renamed
    +"\n"
    +wrapper
    +s[next_pos:]
)

p.write_text(s)

print("IDENTITY_WRITE_GUARD_PATCH=PASS")
PY


echo
echo "=== 3. COMPILE ==="

"$PY" -m py_compile "$STORE"

echo "COMPILE=PASS"


echo
echo "=== 4. SYNTHETIC OVERWRITE TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.storage import (
    save_country_result,
)

from app.country.event_consumer import (
    _CountryResultAdapter,
)

identity_root=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

pipeline_root=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

cid="k7d-r2-write-guard-test"

identity_root.mkdir(
    parents=True,
    exist_ok=True,
)

ipath=identity_root/f"{cid}.json"

ipath.write_text(
    json.dumps(
        {
            "schema_version":1,
            "config_id":cid,
            "locked":True,
            "country_code":"DE",
            "country_name":"Germany",
            "source":"synthetic-test",
        }
    )
)

save_country_result(
    _CountryResultAdapter(
        {
            "schema_version":1,
            "config_id":cid,
            "state":"ambiguous",
            "country_code":None,
            "country_name":None,
            "exit_ip":"1.1.1.1",
            "metadata":{},
        }
    )
)

p=pipeline_root/f"{cid}.json"

assert p.exists()

o=json.loads(
    p.read_text()
)

print(
    "GUARDED_RESULT=",
    o,
)

assert o["country_code"]=="DE"

assert o["state"]!="ambiguous"

assert (
    o["metadata"][
        "country_identity_guard"
    ] is True
)

print(
    "IDENTITY_OVERWRITE_BLOCKED=PASS"
)

p.unlink(
    missing_ok=True
)

ipath.unlink(
    missing_ok=True
)
PY


echo
echo "=== 5. RECONCILE ALL LOCKED IDENTITIES ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.storage import (
    save_country_result,
)

from app.country.event_consumer import (
    _CountryResultAdapter,
)


PIPE=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

IDENT=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

reconciled=0
missing_pipeline=0
invalid=0


for ip in IDENT.glob("*.json"):

    try:
        identity=json.loads(
            ip.read_text()
        )
    except Exception:
        invalid+=1
        continue

    if not (
        identity.get("locked") is True
        and identity.get("country_code")
    ):
        invalid+=1
        continue

    cid=str(
        identity.get("config_id")
        or ip.stem
    )

    pp=PIPE/f"{cid}.json"

    if not pp.exists():
        missing_pipeline+=1
        continue

    try:
        old=json.loads(
            pp.read_text()
        )
    except Exception:
        invalid+=1
        continue

    # Re-save through the new canonical guard.
    save_country_result(
        _CountryResultAdapter(
            old
        )
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
    "INVALID=",
    invalid,
)

assert invalid==0

print(
    "LOCKED_IDENTITY_RECONCILIATION=PASS"
)
PY


echo
echo "=== 6. VERIFY ZERO LOCKED/AMBIGUOUS CONFLICT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

PIPE=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

IDENT=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

conflicts=[]

for ip in IDENT.glob("*.json"):

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

    pp=PIPE/f"{cid}.json"

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
        !=identity.get("country_code")
        or str(
            result.get("state")
            or ""
        ) in {
            "ambiguous",
            "unresolved",
        }
    ):
        conflicts.append(cid)


print(
    "LOCKED_IDENTITY_CONFLICTS=",
    len(conflicts),
)

for cid in conflicts[:20]:
    print(
        "CONFLICT=",
        cid,
    )

assert not conflicts

print(
    "CANONICAL_IDENTITY_CONSISTENCY=PASS"
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
echo "=== 8. 60s OVERWRITE RESISTANCE TEST ==="

sleep 60

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

PIPE=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

IDENT=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

conflicts=[]

for ip in IDENT.glob("*.json"):

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

    pp=PIPE/f"{cid}.json"

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
        !=identity.get("country_code")
        or str(
            result.get("state")
            or ""
        ) in {
            "ambiguous",
            "unresolved",
        }
    ):
        conflicts.append(cid)


print(
    "CONFLICTS_AFTER_60S=",
    len(conflicts),
)

assert not conflicts

print(
    "OVERWRITE_RESISTANCE=PASS"
)
PY


echo
echo "=== 9. TRUE HARD-UNRESOLVED ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

PIPE=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

IDENT=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

states=Counter()

hard=[]

for p in PIPE.glob("*.json"):

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

    identity=IDENT/f"{cid}.json"

    if (
        state in {
            "ambiguous",
            "unresolved",
        }
        and not o.get(
            "country_code"
        )
        and not identity.exists()
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
    "STATES=",
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
    "TRUE_UNRESOLVED_INVENTORY=PASS"
)
PY


echo
echo "=== 10. SERVICES ==="

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


echo
echo "======================================================"
echo "FIX22K7D_R2=PASS"
echo "CANONICAL_STORE=pipeline/latest"
echo "IDENTITY_WRITE_GUARD=ACTIVE"
echo "OLD_WORKER_OVERWRITE=BLOCKED"
echo "NEXT=FIX22K7E-HARD-FALLBACK"
echo "======================================================"
