#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. UNRESOLVED / AMBIGUOUS COUNTRY INVENTORY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

roots=[
    Path("/var/lib/config-location/country/pipeline/latest"),
    Path("/var/lib/config-location/country/latest"),
]

files=[]

for root in roots:
    if root.exists():
        files.extend(root.glob("*.json"))

seen=set()
rows=[]

for p in files:
    if p in seen:
        continue
    seen.add(p)

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    state=str(o.get("state") or "").lower()

    if state not in {
        "ambiguous",
        "unresolved",
        "pending_confirmation",
    }:
        continue

    rows.append((p,o))


print("UNRESOLVED_FILES=",len(rows))

states=Counter()
has_ip=0
has_country=0
ipv4=0
ipv6=0
geo_states=Counter()

samples=[]

for p,o in rows:

    state=str(o.get("state") or "unknown")
    states[state]+=1

    ip=o.get("exit_ip")
    if ip:
        has_ip+=1
        if ":" in str(ip):
            ipv6+=1
        else:
            ipv4+=1

    if o.get("country_code"):
        has_country+=1

    primary=o.get("primary") or {}
    if isinstance(primary,dict):
        geo_states[
            str(primary.get("state") or "unknown")
        ]+=1

    if len(samples)<30:
        samples.append({
            "file":p.name,
            "config_id":o.get("config_id"),
            "state":state,
            "exit_ip":ip,
            "country_code":o.get("country_code"),
            "primary_state":(
                primary.get("state")
                if isinstance(primary,dict)
                else None
            ),
            "primary_country":(
                primary.get("country_code")
                if isinstance(primary,dict)
                else None
            ),
            "asn":o.get("asn"),
            "network_name":o.get("network_name"),
        })


print("STATES=",dict(states))
print("HAS_EXIT_IP=",has_ip)
print("HAS_COUNTRY=",has_country)
print("IPV4=",ipv4)
print("IPV6=",ipv6)
print("PRIMARY_GEO_STATES=",dict(geo_states))

for s in samples:
    print("SAMPLE=",s)

print("K7_UNRESOLVED_INVENTORY=PASS")
PY


echo
echo "=== 2. GEO CACHE MISS / AMBIGUOUS PROFILE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

root=Path(
    "/var/lib/config-location/country/geo-cache"
)

states=Counter()
countries=Counter()
ambiguous=0
confirmed=0

for p in root.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    v=o.get("value") or {}

    if not isinstance(v,dict):
        continue

    state=str(v.get("state") or "unknown")
    states[state]+=1

    code=v.get("country_code")
    if code:
        countries[str(code).upper()]+=1

    if state=="ambiguous":
        ambiguous+=1

    if state=="confirmed":
        confirmed+=1


print("GEO_CACHE_STATES=",dict(states))
print("GEO_CACHE_CONFIRMED=",confirmed)
print("GEO_CACHE_AMBIGUOUS=",ambiguous)
print("TOP_COUNTRIES=",countries.most_common(20))

print("K7_CACHE_PROFILE=PASS")
PY


echo
echo "=== 3. PROVIDER FAILURE / DISAGREEMENT PROFILE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

root=Path(
    "/var/lib/config-location/country/geo-cache"
)

provider_errors=Counter()
provider_success=Counter()
disagreements=Counter()

shown=0

for p in root.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    v=o.get("value") or {}

    if not isinstance(v,dict):
        continue

    evidence=v.get("evidence") or []

    countries=[]

    if isinstance(evidence,list):

        for e in evidence:

            if not isinstance(e,dict):
                continue

            provider=str(
                e.get("provider") or "unknown"
            )

            if e.get("success") is True:
                provider_success[provider]+=1
            else:
                err=str(
                    e.get("error") or "unknown"
                )
                provider_errors[
                    provider+" | "+err[:120]
                ]+=1

            code=e.get("country_code")
            if code:
                countries.append(
                    str(code).upper()
                )


    unique=sorted(set(countries))

    if len(unique)>=2:
        disagreements[
            " vs ".join(unique)
        ]+=1

        if shown<20:
            print(
                "DISAGREEMENT_SAMPLE=",
                {
                    "ip":o.get("ip"),
                    "countries":unique,
                    "state":v.get("state"),
                    "evidence":evidence,
                },
            )
            shown+=1


print("PROVIDER_SUCCESS=",dict(provider_success))

print(
    "TOP_PROVIDER_ERRORS=",
    provider_errors.most_common(30),
)

print(
    "COUNTRY_DISAGREEMENTS=",
    disagreements.most_common(30),
)

print("K7_PROVIDER_PROFILE=PASS")
PY


echo
echo "=== 4. COUNTRY IDENTITY COVERAGE ==="

"$PY" <<'PY'
from pathlib import Path
import json

root=Path(
    "/var/lib/config-location/country/country-identity"
)

valid=0
invalid=0

for p in root.glob("*.json"):

    try:
        o=json.loads(p.read_text())
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


print("IDENTITY_VALID=",valid)
print("IDENTITY_INVALID=",invalid)

assert invalid==0

print("K7_IDENTITY_COVERAGE=PASS")
PY


echo
echo "=== 5. ROTATING HISTORY PROFILE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

root=Path(
    "/var/lib/config-location/country/rotating-exit-history"
)

states=Counter()
reasons=Counter()

multi=0
country_changed=0

for p in root.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    obs=o.get("observations") or []

    if len(obs)>=2:
        multi+=1

    v=o.get("last_verdict") or {}

    state=v.get("state","unknown")
    reason=v.get("reason","unknown")

    states[state]+=1
    reasons[reason]+=1

    if str(reason).startswith("country_change"):
        country_changed+=1


print("MULTI_OBSERVATION=",multi)
print("STATES=",dict(states))
print("REASONS=",dict(reasons))
print("COUNTRY_CHANGE_CASES=",country_changed)

print("K7_ROTATING_PROFILE=PASS")
PY


echo
echo "=== 6. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY


echo
echo "=== 7. SERVICES ==="

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
echo "FIX22K7A=PASS"
echo "MODE=UNRESOLVED-ROOT-CAUSE-INVENTORY"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K7B"
echo "======================================================"
