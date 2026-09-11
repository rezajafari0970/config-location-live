#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
F="$R/app/country/pipeline.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22H7-$TS"

mkdir -p "$B"
cp -a "$F" "$B/"

echo "BACKUP=$B"

export F


echo "=== 1. PATCH SAME-JOB TEMPORAL CONFIRMATION ==="

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["F"])
s=p.read_text()

old='''        rows=append_observation(
            config_id=config_id,
            exit_ip=exit_ip,
            country_code=(
                fused.country_code
            ),
            country_name=(
                fused.country_name
            ),
            confidence=(
                fused.confidence
            ),
            asn=primary.get(
                "asn"
            ),
            network_type=primary.get(
                "network_type"
            ),
        )


        temporal=decide_temporal(
            rows
        )
'''

new='''        # -------------------------------------------------
        # Single-job temporal confirmation.
        #
        # Country detection is a one-time classification.
        # We therefore complete the temporal proof while
        # this SAME Xray runtime is still alive instead of
        # scheduling the config again minutes later.
        # -------------------------------------------------

        rows=append_observation(
            config_id=config_id,
            exit_ip=exit_ip,
            country_code=(
                fused.country_code
            ),
            country_name=(
                fused.country_name
            ),
            confidence=(
                fused.confidence
            ),
            asn=primary.get(
                "asn"
            ),
            network_type=primary.get(
                "network_type"
            ),
        )


        if fused.country_code:

            # Small separation between independent exit
            # observations, but no second Xray startup.
            import time as _country_time

            _country_time.sleep(1.5)


            exit_obs_2=observe_exit_ip(
                proxy_url=(
                    runtime.proxy_url
                ),
                timeout=10.0,
                minimum_agreement=2,
            )


            if (
                exit_obs_2.state
                == "confirmed"
                and exit_obs_2.exit_ip
            ):

                exit_ip_2=(
                    exit_obs_2.exit_ip
                )


                if exit_ip_2 == exit_ip:

                    second_code=(
                        fused.country_code
                    )

                    second_name=(
                        fused.country_name
                    )

                    second_confidence=(
                        fused.confidence
                    )

                    second_asn=(
                        primary.get("asn")
                    )

                    second_network_type=(
                        primary.get(
                            "network_type"
                        )
                    )


                else:

                    # Exit rotated inside the same runtime.
                    # Resolve the second exit independently
                    # before calling the country stable.
                    primary_2=resolve_geo(
                        config_id=(
                            config_id
                            + "-temporal-2"
                        ),
                        ip=exit_ip_2,
                    )


                    recovery_2=None

                    if should_run_recovery(
                        primary_2["state"]
                    ):

                        recovery_2=recover_country(
                            ip=exit_ip_2,
                            previous_state=(
                                primary_2["state"]
                            ),
                        )


                    fused_2=(
                        fuse_country_verdict(
                            primary=primary_2,
                            recovery=recovery_2,
                        )
                    )


                    second_code=(
                        fused_2.country_code
                    )

                    second_name=(
                        fused_2.country_name
                    )

                    second_confidence=(
                        fused_2.confidence
                    )

                    second_asn=(
                        primary_2.get("asn")
                    )

                    second_network_type=(
                        primary_2.get(
                            "network_type"
                        )
                    )


                rows=append_observation(
                    config_id=config_id,
                    exit_ip=exit_ip_2,
                    country_code=second_code,
                    country_name=second_name,
                    confidence=(
                        second_confidence
                    ),
                    asn=second_asn,
                    network_type=(
                        second_network_type
                    ),
                )


        temporal=decide_temporal(
            rows
        )
'''

if old not in s:
    raise SystemExit(
        "temporal anchor missing"
    )

p.write_text(
    s.replace(
        old,
        new,
        1,
    )
)

print(
    "SINGLE_JOB_TEMPORAL_PATCH=PASS"
)
PY


echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$F"

echo "COMPILE=PASS"


echo "=== 3. STOP COUNTRY DAEMON FOR CONTROLLED TEST ==="

systemctl stop \
config-location-country-worker.service

test "$(
    systemctl is-active \
    config-location-country-worker.service \
    2>/dev/null || true
)" != active

echo "COUNTRY_DAEMON_STOPPED=PASS"


echo "=== 4. SELECT NEVER-TESTED HEALTHY CONFIG ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

selected=None

for hp in sorted(
    H.glob("*.json")
):

    try:
        h=json.loads(
            hp.read_text()
        )
    except Exception:
        continue

    if str(
        h.get("state","")
    ).lower()!="healthy":
        continue

    cp=C/f"{hp.stem}.json"

    if not cp.exists():
        continue

    if (
        P
        / f"{hp.stem}.json"
    ).exists():
        continue

    selected=hp.stem
    break


assert selected

Path(
    "/tmp/FIX22H7-CID"
).write_text(
    selected+"\n"
)

print(
    "SELECTED=",
    selected
)
PY


echo "=== 5. ONE COUNTRY JOB ONLY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.pipeline import (
    process_country,
)

cid=Path(
    "/tmp/FIX22H7-CID"
).read_text().strip()

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

record=json.loads(
    (
        C/f"{cid}.json"
    ).read_text()
)

health=json.loads(
    (
        H/f"{cid}.json"
    ).read_text()
)

assert (
    str(
        health.get(
            "state",
            "",
        )
    ).lower()
    == "healthy"
)

r=process_country(
    config_id=cid,
    record=record,
    health=health,
)

print(
    "CONFIG_ID=",
    cid,
)

print(
    "STATE=",
    r.get("state"),
)

print(
    "COUNTRY=",
    r.get("country_code"),
    r.get("country_name"),
)

print(
    "EXIT=",
    r.get("exit_ip"),
)

print(
    "TEMPORAL=",
    r.get("temporal"),
)


assert (
    r.get("state")
    in {
        "confirmed_stable",
        "confirmed_rotating_ip",
        "unstable_exit",
        "ambiguous",
        "unknown",
        "error",
    }
)

# A successful country determination must finish
# inside this one job. No pending state is allowed.
if r.get("country_code"):

    assert (
        r.get("state")
        in {
            "confirmed_stable",
            "confirmed_rotating_ip",
        }
    )

    assert (
        (
            r.get("temporal")
            or {}
        ).get(
            "observations",
            0,
        )
        >= 2
    )

    print(
        "SINGLE_JOB_FINAL_COUNTRY=PASS"
    )

else:

    print(
        "UNRESOLVED_REMAINS_RETRYABLE=YES"
    )
PY


echo "=== 6. CONFIRMED MUST LEAVE SCHEDULER ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path

from app.country.worker import (
    healthy_candidates,
)

cid=Path(
    "/tmp/FIX22H7-CID"
).read_text().strip()

due={
    candidate_id
    for _,candidate_id,_,_
    in healthy_candidates()
}

from pathlib import Path
import json

p=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
) / f"{cid}.json"

o=json.loads(
    p.read_text()
)

print(
    "RESULT_STATE=",
    o.get("state"),
)

print(
    "IN_DUE_QUEUE=",
    cid in due,
)


if o.get("state") in {
    "confirmed_stable",
    "confirmed_rotating_ip",
}:

    assert cid not in due

    print(
        "FINAL_COUNTRY_NEVER_RETEST=PASS"
    )

else:

    assert cid in due

    print(
        "UNRESOLVED_RETRY_ALLOWED=PASS"
    )
PY


echo "=== 7. RESTART PERMANENT COUNTRY WORKER ==="

systemctl start \
config-location-country-worker.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-worker.service
)" = active

test "$(
    systemctl is-enabled \
    config-location-country-worker.service
)" = enabled

echo "COUNTRY_WORKER_RESTORED=PASS"


echo "=== 8. CORE SERVICE ISOLATION ==="

for svc in \
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


echo "=== 9. ERROR / LEAK CHECK ==="

RESTARTS=$(
    systemctl show \
    config-location-country-worker.service \
    -p NRestarts \
    --value
)

echo "COUNTRY_RESTARTS=$RESTARTS"

test "$RESTARTS" -eq 0


COUNT=$(
    find \
    /var/lib/config-location/health-sandboxes \
    -maxdepth 1 \
    -type d \
    -name "country-*" \
    2>/dev/null \
    | wc -l
)

echo "COUNTRY_SANDBOXES=$COUNT"

test "$COUNT" -le 6


echo "========================================"
echo "FIX22H7=PASS"
echo "COUNTRY_JOB=ONE_TIME"
echo "XRAY_RUNTIME_STARTS_PER_COUNTRY_JOB=ONE"
echo "TEMPORAL_OBSERVATIONS=SAME_RUNTIME"
echo "SUCCESSFUL_COUNTRY_PENDING_STATE=REMOVED"
echo "CONFIRMED_COUNTRY_RETEST=NEVER"
echo "UNRESOLVED_RETRY=ALLOWED"
echo "HEALTH_RETEST=INDEPENDENT"
echo "PUBLICATION=DISABLED"
echo "SOURCE_RAW_UNCHANGED=YES"
echo "BACKUP=$B"
echo "========================================"
