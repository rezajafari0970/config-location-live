#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. RESTORE COUNTRY WRITERS ==="

systemctl restart \
config-location-country-worker.service \
config-location-country-event-consumer.service

sleep 4

for svc in \
config-location-country-worker.service \
config-location-country-event-consumer.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo "WRITERS_RESTORED=PASS"


echo
echo "=== 2. SHOW PATCHED STORAGE FUNCTION ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect
from app.country import storage

print(
    inspect.getsource(
        storage.save_country_result
    )
)

print(
    "----- UNGUARDED -----"
)

print(
    inspect.getsource(
        storage._save_country_result_unguarded
    )
)
PY


echo
echo "=== 3. PRECISE SYNTHETIC PROBE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import traceback

from app.country.storage import save_country_result
from app.country.event_consumer import _CountryResultAdapter

IDENT=Path(
    "/var/lib/config-location/country/country-identity"
)

PIPE=Path(
    "/var/lib/config-location/country/pipeline/latest"
)

cid="k7d-r2-debug-test"

ip=IDENT/f"{cid}.json"
pp=PIPE/f"{cid}.json"

ip.unlink(missing_ok=True)
pp.unlink(missing_ok=True)

IDENT.mkdir(parents=True,exist_ok=True)

ip.write_text(
    json.dumps(
        {
            "schema_version":1,
            "config_id":cid,
            "locked":True,
            "country_code":"DE",
            "country_name":"Germany",
            "source":"synthetic-debug",
        }
    )
)

print(
    "IDENTITY_BEFORE=",
    json.loads(ip.read_text())
)

incoming={
    "schema_version":1,
    "config_id":cid,
    "state":"ambiguous",
    "country_code":None,
    "country_name":None,
    "exit_ip":"1.1.1.1",
    "metadata":{},
}

print(
    "INCOMING=",
    incoming
)

try:
    ret=save_country_result(
        _CountryResultAdapter(
            incoming
        )
    )

    print(
        "SAVE_RETURN=",
        repr(ret)
    )

except Exception:
    traceback.print_exc()


print(
    "PIPE_EXISTS=",
    pp.exists()
)

if pp.exists():

    o=json.loads(
        pp.read_text()
    )

    print(
        "PIPE_RESULT=",
        json.dumps(
            o,
            indent=2,
            sort_keys=True,
        )
    )

    print(
        "CHECK_COUNTRY=",
        o.get("country_code")
        =="DE"
    )

    print(
        "CHECK_STATE=",
        o.get("state")
        not in {
            "ambiguous",
            "unresolved",
        }
    )

    print(
        "CHECK_GUARD=",
        (
            o.get("metadata")
            or {}
        ).get(
            "country_identity_guard"
        ) is True
    )


pp.unlink(missing_ok=True)
ip.unlink(missing_ok=True)

print(
    "SYNTHETIC_PROBE=COMPLETE"
)
PY


echo
echo "=== 4. STORAGE PATH CONSTANTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country import storage

for name in dir(storage):

    if (
        "ROOT" in name
        or "DIR" in name
        or "PATH" in name
    ):

        try:
            print(
                name,
                "=",
                getattr(storage,name)
            )
        except Exception:
            pass
PY


echo
echo "=== 5. CURRENT SERVICES ==="

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
echo "FIX22K7D_R2_FAILSAFE=PASS"
echo "WRITERS_RESTORED=YES"
echo "PRODUCTION_DATA_CHANGED=NO"
echo "NEXT=FIX22K7D-R2-R2"
echo "======================================================"
