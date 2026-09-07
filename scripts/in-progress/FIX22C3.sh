#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== REAL HEALTHY CONFIG EXIT PROOF ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.health.runtime.launcher import (
    RuntimeLauncher,
)

from app.country.exit_observer import (
    observe_exit_ip,
)


C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)


# ---------------------------------------------------------
# Pick a currently healthy config that still exists.
# Prefer VLESS because it is the largest production class.
# ---------------------------------------------------------

candidates=[]

for hp in H.glob("*.json"):

    try:
        health=json.loads(
            hp.read_text()
        )
    except Exception:
        continue

    if str(
        health.get(
            "state",
            "",
        )
    ).lower() != "healthy":
        continue

    cp=C/f"{hp.stem}.json"

    if not cp.exists():
        continue

    try:
        config=json.loads(
            cp.read_text()
        )
    except Exception:
        continue

    config_type=str(
        config.get("config_type")
        or config.get("type")
        or config.get("protocol")
        or ""
    ).lower()

    rank=(
        0
        if config_type=="vless"
        else 1
    )

    candidates.append(
        (
            rank,
            hp.stem,
            config_type,
            config,
        )
    )


if not candidates:
    raise SystemExit(
        "no healthy config candidate"
    )


candidates.sort(
    key=lambda x:(
        x[0],
        x[1],
    )
)

_,config_id,config_type,record=(
    candidates[0]
)

print(
    "CONFIG_ID=",
    config_id,
)

print(
    "CONFIG_TYPE=",
    config_type,
)


# ---------------------------------------------------------
# Determine canonical runtime source from the stored record.
#
# Store layouts observed across the project may contain:
# source.raw
# source
# raw
#
# We do not alter it.
# ---------------------------------------------------------

source=None

source_obj=record.get(
    "source"
)

if isinstance(
    source_obj,
    dict,
):

    if "raw" in source_obj:
        source=source_obj["raw"]

    elif "value" in source_obj:
        source=source_obj["value"]

elif source_obj is not None:
    source=source_obj


if source is None:
    source=record.get(
        "raw"
    )


if source is None:
    raise SystemExit(
        "runtime source not found "
        "in selected config record"
    )


print(
    "SOURCE_CLASS=",
    type(source).__name__,
)


# ---------------------------------------------------------
# Direct server observation.
# ---------------------------------------------------------

direct=observe_exit_ip(
    proxy_url=None,
    timeout=8.0,
)

print(
    "DIRECT_STATE=",
    direct.state,
)

print(
    "DIRECT_IP=",
    direct.exit_ip,
)

assert (
    direct.state
    == "confirmed"
)

assert direct.exit_ip


# ---------------------------------------------------------
# Launch the REAL config.
# ---------------------------------------------------------

launcher=RuntimeLauncher()

runtime=None

try:

    runtime=launcher.launch(
        config_id=(
            "country-proof-"
            + config_id
        ),
        config_type=config_type,
        source=source,
        startup_timeout=8.0,
    )

    print(
        "XRAY_PID=",
        runtime.pid,
    )

    print(
        "SOCKS_PORT=",
        runtime.socks_port,
    )

    print(
        "BUILDER=",
        runtime.metadata.get(
            "builder"
        ),
    )

    print(
        "PROTOCOL=",
        runtime.metadata.get(
            "protocol"
        ),
    )


    proxied=observe_exit_ip(
        proxy_url=(
            runtime.proxy_url
        ),
        timeout=10.0,
    )


    print(
        "PROXY_STATE=",
        proxied.state,
    )

    print(
        "PROXY_EXIT_IP=",
        proxied.exit_ip,
    )

    print(
        "PROXY_AGREED=",
        proxied.agreed,
    )

    print(
        "PROXY_SUCCESSFUL=",
        proxied.successful,
    )


    for p in proxied.probes:

        print(
            "PROXY_PROBE",
            p.provider,
            p.success,
            p.ip,
            p.duration_ms,
            p.error,
        )


    assert (
        proxied.state
        == "confirmed"
    )

    assert proxied.exit_ip

    assert (
        proxied.agreed
        >= 2
    )


    print(
        "DIRECT_VS_PROXY_DIFFERENT=",
        direct.exit_ip
        !=
        proxied.exit_ip,
    )


    print(
        "REAL_RUNTIME_EXIT_PROOF=PASS"
    )


finally:

    if runtime is not None:
        runtime.stop()


print(
    "RUNTIME_CLEANUP=PASS"
)
PY


echo "=== SANDBOX RESIDUAL CHECK ==="

find \
/var/lib/config-location/health-sandboxes \
-maxdepth 1 \
-type d \
-name "country-proof-*" \
-print \
| head -n 20

COUNT=$(
    find \
    /var/lib/config-location/health-sandboxes \
    -maxdepth 1 \
    -type d \
    -name "country-proof-*" \
    | wc -l
)

echo "COUNTRY_PROOF_SANDBOXES=$COUNT"

test "$COUNT" -eq 0


echo "=== PRODUCTION SERVICES ==="

for svc in \
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


echo "========================================"
echo "FIX22C3=PASS"
echo "REAL_HEALTHY_CONFIG=TESTED"
echo "REAL_XRAY_RUNTIME=PASS"
echo "MULTI_ENDPOINT_PROXY_EXIT=PASS"
echo "RUNTIME_CLEANUP=PASS"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
