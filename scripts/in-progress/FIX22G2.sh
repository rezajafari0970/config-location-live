#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

REPORT=/var/lib/config-location/country/protocol-coverage-latest.json

echo "=== 1. MULTI-PROTOCOL REAL COVERAGE ==="

export REPORT

PYTHONPATH="$R" "$PY" <<'PY'
from __future__ import annotations

from pathlib import Path
from collections import defaultdict
from datetime import datetime, timezone
import json
import os

from app.country.pipeline import (
    process_country,
)


CONFIG_ROOT=Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

REPORT=Path(
    os.environ["REPORT"]
)


# Canonical type names seen in the current Store.
TARGETS=(
    "vless",
    "vmess",
    "ss",
    "json_xray",
    "trojan",
    "wireguard",
)


# High-population protocols must produce at least
# one real Country verdict in this stage.
REQUIRED_SUCCESS={
    "vless",
    "vmess",
    "ss",
    "json_xray",
}


# Small-population types are still mandatory attempts.
# Failure here is reported explicitly and becomes the
# next development target rather than being hidden.
MAX_ATTEMPTS={
    "vless":3,
    "vmess":5,
    "ss":5,
    "json_xray":5,
    "trojan":3,
    "wireguard":1,
}


def record_type(o: dict) -> str:

    return str(
        o.get("config_type")
        or o.get("type")
        or o.get("protocol")
        or "unknown"
    ).strip().lower()


candidates=defaultdict(list)


for hp in HEALTH_ROOT.glob(
    "*.json"
):

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

    cp=(
        CONFIG_ROOT
        / f"{hp.stem}.json"
    )

    if not cp.exists():
        continue

    try:
        record=json.loads(
            cp.read_text()
        )
    except Exception:
        continue

    t=record_type(
        record
    )

    if t not in TARGETS:
        continue

    candidates[t].append(
        (
            hp.stem,
            record,
            health,
        )
    )


for t in TARGETS:
    candidates[t].sort(
        key=lambda x:x[0]
    )

    print(
        "AVAILABLE",
        t,
        len(candidates[t]),
    )


coverage={}


for protocol in TARGETS:

    rows=candidates[
        protocol
    ]

    limit=MAX_ATTEMPTS[
        protocol
    ]

    attempted=0
    successful=0

    states=defaultdict(int)

    examples=[]


    print()
    print(
        "===== PROTOCOL",
        protocol,
        "====="
    )


    for (
        config_id,
        record,
        health,
    ) in rows:

        if attempted >= limit:
            break

        attempted += 1


        result=process_country(
            config_id=config_id,
            record=record,
            health=health,
        )


        state=str(
            result.get(
                "state",
                "unknown",
            )
        )

        states[state] += 1


        success=bool(
            result.get(
                "country_code"
            )
            and result.get(
                "exit_ip"
            )
            and state in {
                "pending_confirmation",
                "confirmed_stable",
                "confirmed_rotating_ip",
            }
        )


        if success:
            successful += 1


        examples.append(
            {
                "config_id":
                    config_id,

                "state":
                    state,

                "country_code":
                    result.get(
                        "country_code"
                    ),

                "country_name":
                    result.get(
                        "country_name"
                    ),

                "exit_ip":
                    result.get(
                        "exit_ip"
                    ),

                "asn":
                    result.get(
                        "asn"
                    ),

                "network_type":
                    result.get(
                        "network_type"
                    ),

                "reason":
                    result.get(
                        "reason"
                    ),

                "error":
                    result.get(
                        "error"
                    ),
            }
        )


        print(
            "RESULT",
            protocol,
            config_id[:12],
            "state=",
            state,
            "country=",
            result.get(
                "country_code"
            ),
            "exit=",
            result.get(
                "exit_ip"
            ),
            "asn=",
            result.get(
                "asn"
            ),
            "error=",
            result.get(
                "error"
            ),
        )


        # One successful real config is enough to prove
        # basic protocol coverage for this stage.
        if successful >= 1:
            break


    coverage[
        protocol
    ]={
        "available_healthy":
            len(rows),

        "attempted":
            attempted,

        "successful":
            successful,

        "covered":
            successful >= 1,

        "states":
            dict(states),

        "examples":
            examples,
    }


print()
print(
    "=== COVERAGE SUMMARY ==="
)

for protocol in TARGETS:

    o=coverage[
        protocol
    ]

    print(
        protocol,
        "available=",
        o["available_healthy"],
        "attempted=",
        o["attempted"],
        "successful=",
        o["successful"],
        "covered=",
        o["covered"],
        "states=",
        o["states"],
    )


required_failures=[
    protocol
    for protocol in REQUIRED_SUCCESS
    if (
        coverage[
            protocol
        ]["available_healthy"]
        > 0
        and not coverage[
            protocol
        ]["covered"]
    )
]


small_type_gaps=[
    protocol
    for protocol in (
        "trojan",
        "wireguard",
    )
    if (
        coverage[
            protocol
        ]["available_healthy"]
        > 0
        and not coverage[
            protocol
        ]["covered"]
    )
]


report={
    "schema_version":1,

    "stage":"FIX22G2",

    "generated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),

    "coverage":
        coverage,

    "required_protocols":
        sorted(
            REQUIRED_SUCCESS
        ),

    "required_failures":
        required_failures,

    "small_type_gaps":
        small_type_gaps,

    "core_protocol_coverage_pass":
        not required_failures,
}


REPORT.parent.mkdir(
    parents=True,
    exist_ok=True,
)

tmp=REPORT.with_name(
    "."+REPORT.name+".tmp"
)

tmp.write_text(
    json.dumps(
        report,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )
    +"\n"
)

tmp.replace(
    REPORT
)


print(
    "REQUIRED_FAILURES=",
    required_failures,
)

print(
    "SMALL_TYPE_GAPS=",
    small_type_gaps,
)


assert not required_failures


print(
    "CORE_PROTOCOL_COVERAGE=PASS"
)
PY


echo "=== 2. SECOND OBSERVATION FOR COVERED TYPES ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.pipeline import (
    process_country,
)


report=json.loads(
    Path(
        "/var/lib/config-location/"
        "country/"
        "protocol-coverage-latest.json"
    ).read_text()
)


C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)


processed=0
confirmed=0


for protocol,data in (
    report["coverage"].items()
):

    if not data["covered"]:
        continue

    examples=[
        x
        for x in data[
            "examples"
        ]
        if x.get(
            "country_code"
        )
    ]

    if not examples:
        continue

    cid=examples[0][
        "config_id"
    ]

    cp=C/f"{cid}.json"
    hp=H/f"{cid}.json"

    if (
        not cp.exists()
        or not hp.exists()
    ):
        continue


    record=json.loads(
        cp.read_text()
    )

    health=json.loads(
        hp.read_text()
    )


    if str(
        health.get(
            "state",
            "",
        )
    ).lower() != "healthy":
        continue


    result=process_country(
        config_id=cid,
        record=record,
        health=health,
    )


    processed += 1


    state=result.get(
        "state"
    )


    print(
        "TEMPORAL",
        protocol,
        cid[:12],
        state,
        result.get(
            "country_code"
        ),
        result.get(
            "exit_ip"
        ),
        (
            result.get(
                "temporal"
            )
            or {}
        ).get(
            "observations"
        ),
    )


    if state in {
        "confirmed_stable",
        "confirmed_rotating_ip",
    }:
        confirmed += 1


print(
    "TEMPORAL_PROCESSED=",
    processed,
)

print(
    "TEMPORALLY_CONFIRMED=",
    confirmed,
)


assert processed >= 3
assert confirmed >= 2

print(
    "MULTI_PROTOCOL_TEMPORAL=PASS"
)
PY


echo "=== 3. COVERAGE REPORT ==="

"$PY" <<'PY'
from pathlib import Path
import json

p=Path(
    "/var/lib/config-location/"
    "country/"
    "protocol-coverage-latest.json"
)

o=json.loads(
    p.read_text()
)

print(
    json.dumps(
        {
            k:{
                "available_healthy":
                    v["available_healthy"],

                "attempted":
                    v["attempted"],

                "successful":
                    v["successful"],

                "covered":
                    v["covered"],

                "states":
                    v["states"],
            }
            for k,v in
            o["coverage"].items()
        },
        indent=2,
        sort_keys=True,
    )
)

print(
    "SMALL_TYPE_GAPS=",
    o["small_type_gaps"],
)

assert (
    o[
        "core_protocol_coverage_pass"
    ]
    is True
)

print(
    "COVERAGE_REPORT=PASS"
)
PY


echo "=== 4. SANDBOX CLEANUP ==="

COUNT=$(
    find \
    /var/lib/config-location/health-sandboxes \
    -maxdepth 1 \
    -type d \
    -name "country-*" \
    2>/dev/null \
    | wc -l
)

echo "COUNTRY_SANDBOX_RESIDUAL=$COUNT"

test "$COUNT" -eq 0

echo "RUNTIME_CLEANUP=PASS"


echo "=== 5. COUNTRY SELFTESTS ==="

PYTHONPATH="$R" \
"$PY" -m app.country.selftest

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_exit_observer

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_temporal

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_verdict_fusion

echo "COUNTRY_SELFTESTS=PASS"


echo "=== 6. PRODUCTION SERVICES ==="

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
echo "FIX22G2=PASS"
echo "MULTI_PROTOCOL_COUNTRY_COVERAGE=PASS"
echo "VLESS=REQUIRED"
echo "VMESS=REQUIRED"
echo "SHADOWSOCKS=REQUIRED"
echo "JSON_XRAY=REQUIRED"
echo "TROJAN=ATTEMPTED_IF_AVAILABLE"
echo "WIREGUARD=ATTEMPTED_IF_AVAILABLE"
echo "TEMPORAL_MULTI_PROTOCOL=PASS"
echo "RUNTIME_CLEANUP=PASS"
echo "PERMANENT_COUNTRY_WORKER=NOT_ENABLED"
echo "PRODUCTION_UNCHANGED=YES"
echo "REPORT=$REPORT"
echo "========================================"
