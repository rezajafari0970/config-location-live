#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

D=/var/lib/config-location/country
P="$D/pipeline"

mkdir -p \
"$P/latest" \
"$P/history"

cat >"$M/pipeline.py" <<'PY'
from __future__ import annotations

import json
import os
import tempfile

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any

from app.health.runtime.launcher import (
    RuntimeLauncher,
)

from .eligibility import (
    decide_country_eligibility,
)

from .exit_observer import (
    observe_exit_ip,
)

from .geo_intelligence import (
    resolve_geo,
)

from .recovery import (
    recover_country,
    should_run_recovery,
)

from .temporal import (
    append_observation,
    decide_temporal,
)

from .verdict_fusion import (
    fuse_country_verdict,
)


PIPELINE_ROOT=Path(
    "/var/lib/config-location/"
    "country/pipeline"
)

LATEST=PIPELINE_ROOT/"latest"
HISTORY=PIPELINE_ROOT/"history"


def utc_now() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def extract_runtime_source(
    record: dict[str, Any],
) -> Any:

    source=record.get("source")

    if isinstance(source,dict):

        if "raw" in source:
            return source["raw"]

        if "value" in source:
            return source["value"]

    elif source is not None:
        return source

    if "raw" in record:
        return record["raw"]

    raise ValueError(
        "runtime_source_missing"
    )


def extract_config_type(
    record: dict[str, Any],
) -> str:

    value=(
        record.get("config_type")
        or record.get("type")
        or record.get("protocol")
        or ""
    )

    value=str(value).strip().lower()

    if not value:
        raise ValueError(
            "config_type_missing"
        )

    return value


def _atomic_json(
    path: Path,
    value: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd,tmp=tempfile.mkstemp(
        dir=str(path.parent),
        prefix="."+path.name+".",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                value,
                f,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            f.write("\n")
            f.flush()
            os.fsync(f.fileno())

        os.replace(
            tmp,
            path,
        )

    except Exception:

        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

        raise


def save_pipeline_result(
    *,
    config_id: str,
    value: dict[str, Any],
) -> None:

    stamp=datetime.now(
        timezone.utc
    ).strftime(
        "%Y%m%dT%H%M%S.%fZ"
    )

    history=(
        HISTORY
        / config_id
        / f"{stamp}.json"
    )

    latest=(
        LATEST
        / f"{config_id}.json"
    )

    _atomic_json(
        history,
        value,
    )

    _atomic_json(
        latest,
        value,
    )


def process_country(
    *,
    config_id: str,
    record: dict[str, Any],
    health: dict[str, Any],
) -> dict[str, Any]:

    started=utc_now()

    eligibility=(
        decide_country_eligibility(
            health
        )
    )

    if not eligibility.eligible:

        result={
            "schema_version":1,
            "config_id":config_id,
            "state":"ineligible",
            "reason":
                eligibility.reason,
            "started_at":started,
            "finished_at":
                utc_now(),
        }

        save_pipeline_result(
            config_id=config_id,
            value=result,
        )

        return result


    config_type=(
        extract_config_type(
            record
        )
    )

    source=(
        extract_runtime_source(
            record
        )
    )

    launcher=RuntimeLauncher()

    runtime=None

    try:

        runtime=launcher.launch(
            config_id=(
                "country-"
                + config_id
            ),
            config_type=config_type,
            source=source,
            startup_timeout=8.0,
        )


        exit_obs=observe_exit_ip(
            proxy_url=(
                runtime.proxy_url
            ),
            timeout=10.0,
            minimum_agreement=2,
        )


        if (
            exit_obs.state
            != "confirmed"
            or
            not exit_obs.exit_ip
        ):

            result={
                "schema_version":1,
                "config_id":
                    config_id,

                "config_type":
                    config_type,

                "state":
                    exit_obs.state,

                "reason":
                    exit_obs.reason,

                "exit_ip":
                    None,

                "exit_agreed":
                    exit_obs.agreed,

                "exit_successful":
                    exit_obs.successful,

                "started_at":
                    started,

                "finished_at":
                    utc_now(),
            }

            save_pipeline_result(
                config_id=config_id,
                value=result,
            )

            return result


        exit_ip=exit_obs.exit_ip


        primary=resolve_geo(
            config_id=config_id,
            ip=exit_ip,
        )


        recovery=None

        if should_run_recovery(
            primary["state"]
        ):

            recovery=recover_country(
                ip=exit_ip,
                previous_state=(
                    primary["state"]
                ),
            )


        fused=fuse_country_verdict(
            primary=primary,
            recovery=recovery,
        )


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


        temporal=decide_temporal(
            rows
        )


        # Temporal layer may tighten the state.
        if temporal.state=="rotating":

            final_state="rotating"
            final_code=None
            final_name=None
            final_flag=None

        elif (
            fused.country_code
            and temporal.state
            in (
                "confirmed_stable",
                "confirmed_rotating_ip",
            )
        ):

            final_state=(
                temporal.state
            )

            final_code=(
                fused.country_code
            )

            final_name=(
                fused.country_name
            )

            final_flag=(
                fused.flag
            )

        elif fused.country_code:

            final_state=(
                "pending_confirmation"
            )

            final_code=(
                fused.country_code
            )

            final_name=(
                fused.country_name
            )

            final_flag=(
                fused.flag
            )

        else:

            final_state=(
                fused.state
            )

            final_code=None
            final_name=None
            final_flag=None


        result={
            "schema_version":1,

            "config_id":
                config_id,

            "config_type":
                config_type,

            "state":
                final_state,

            "country_code":
                final_code,

            "country_name":
                final_name,

            "flag":
                final_flag,

            "exit_ip":
                exit_ip,

            "confidence":
                fused.confidence,

            "asn":
                primary.get("asn"),

            "network_name":
                primary.get(
                    "network_name"
                ),

            "network_type":
                primary.get(
                    "network_type"
                ),

            "exit_consensus":{
                "agreed":
                    exit_obs.agreed,

                "successful":
                    exit_obs.successful,

                "total":
                    exit_obs.total,
            },

            "primary":{
                "state":
                    primary["state"],

                "country_code":
                    primary.get(
                        "country_code"
                    ),

                "confidence":
                    primary.get(
                        "country_confidence"
                    ),

                "cache_hit":
                    primary.get(
                        "cache_hit"
                    ),
            },

            "recovery":
                recovery,

            "fusion":
                fused.to_dict(),

            "temporal":{
                "state":
                    temporal.state,

                "observations":
                    temporal.observations,

                "unique_countries":
                    temporal.unique_countries,

                "unique_exit_ips":
                    temporal.unique_exit_ips,

                "stable_country":
                    temporal.stable_country,

                "stable_exit_ip":
                    temporal.stable_exit_ip,

                "reason":
                    temporal.reason,
            },

            "runtime":{
                "builder":
                    runtime.metadata.get(
                        "builder"
                    ),

                "protocol":
                    runtime.metadata.get(
                        "protocol"
                    ),
            },

            "started_at":
                started,

            "finished_at":
                utc_now(),
        }


        save_pipeline_result(
            config_id=config_id,
            value=result,
        )

        return result


    except Exception as e:

        result={
            "schema_version":1,

            "config_id":
                config_id,

            "state":"error",

            "reason":
                type(e).__name__,

            "error":
                str(e)[:1000],

            "started_at":
                started,

            "finished_at":
                utc_now(),
        }

        save_pipeline_result(
            config_id=config_id,
            value=result,
        )

        return result


    finally:

        if runtime is not None:
            runtime.stop()
PY


echo "=== 1. COMPILE ==="

"$PY" -m py_compile \
"$M/pipeline.py"

echo "PIPELINE_COMPILE=PASS"


echo "=== 2. SELECT HEALTHY REAL CONFIGS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

types=Counter()
count=0

for hp in H.glob("*.json"):

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

    try:
        c=json.loads(
            cp.read_text()
        )
    except Exception:
        continue

    t=str(
        c.get("config_type")
        or c.get("type")
        or c.get("protocol")
        or "unknown"
    ).lower()

    types[t]+=1
    count+=1

print(
    "HEALTHY_REAL_CANDIDATES=",
    count,
)

print(
    "HEALTHY_TYPES=",
    dict(types),
)

assert count >= 5

print(
    "CANDIDATE_SELECTION=PASS"
)
PY


echo "=== 3. REAL BATCH PASS 1 ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.pipeline import (
    process_country,
)

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)


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
    ).lower()!="healthy":
        continue

    cp=C/f"{hp.stem}.json"

    if not cp.exists():
        continue

    try:
        record=json.loads(
            cp.read_text()
        )
    except Exception:
        continue

    t=str(
        record.get("config_type")
        or record.get("type")
        or record.get("protocol")
        or ""
    ).lower()

    rank={
        "vless":0,
        "vmess":1,
        "ss":2,
        "trojan":3,
        "json":4,
    }.get(t,9)

    candidates.append(
        (
            rank,
            hp.stem,
            record,
            health,
        )
    )


candidates.sort(
    key=lambda x:(
        x[0],
        x[1],
    )
)


success=[]

attempted=0

for _,cid,record,health in candidates:

    if len(success) >= 5:
        break

    if attempted >= 12:
        break

    attempted+=1

    r=process_country(
        config_id=cid,
        record=record,
        health=health,
    )

    print(
        "RESULT",
        cid[:12],
        r.get("config_type"),
        r.get("state"),
        r.get("country_code"),
        r.get("exit_ip"),
        r.get("asn"),
    )

    if (
        r.get("country_code")
        and
        r.get("exit_ip")
        and
        r.get("state")
        in (
            "pending_confirmation",
            "confirmed_stable",
            "confirmed_rotating_ip",
        )
    ):
        success.append(
            cid
        )


print(
    "ATTEMPTED=",
    attempted,
)

print(
    "SUCCESSFUL_REAL_PIPELINES=",
    len(success),
)

print(
    "SUCCESS_IDS=",
    ",".join(success),
)

assert len(success) >= 3

Path(
    "/tmp/FIX22G1-success.txt"
).write_text(
    "\n".join(success)
    +"\n"
)

print(
    "REAL_BATCH_PASS1=PASS"
)
PY


echo "=== 4. SECOND TEMPORAL OBSERVATION ==="

sleep 3

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.pipeline import (
    process_country,
)

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

ids=[
    x.strip()
    for x in Path(
        "/tmp/FIX22G1-success.txt"
    ).read_text().splitlines()
    if x.strip()
]


confirmed=0
processed=0

for cid in ids:

    cp=C/f"{cid}.json"
    hp=H/f"{cid}.json"

    if (
        not cp.exists()
        or
        not hp.exists()
    ):
        continue

    record=json.loads(
        cp.read_text()
    )

    health=json.loads(
        hp.read_text()
    )

    if str(
        health.get("state","")
    ).lower()!="healthy":
        continue

    r=process_country(
        config_id=cid,
        record=record,
        health=health,
    )

    processed+=1

    print(
        "TEMPORAL_RESULT",
        cid[:12],
        r.get("state"),
        r.get("country_code"),
        r.get("exit_ip"),
        (
            r.get("temporal")
            or {}
        ).get(
            "observations"
        ),
    )

    if r.get("state") in (
        "confirmed_stable",
        "confirmed_rotating_ip",
    ):
        confirmed+=1


print(
    "SECOND_PASS_PROCESSED=",
    processed,
)

print(
    "TEMPORALLY_CONFIRMED=",
    confirmed,
)

assert processed >= 3
assert confirmed >= 2

print(
    "TEMPORAL_REAL_BATCH=PASS"
)
PY


echo "=== 5. RESULT STRUCTURE AUDIT ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

states=Counter()
countries=Counter()
types=Counter()

valid=0

for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    valid+=1

    states[
        str(
            o.get("state")
        )
    ]+=1

    if o.get("country_code"):
        countries[
            str(
                o["country_code"]
            )
        ]+=1

    if o.get("config_type"):
        types[
            str(
                o["config_type"]
            )
        ]+=1


print(
    "PIPELINE_RESULTS=",
    valid,
)

print(
    "STATES=",
    dict(states),
)

print(
    "COUNTRIES=",
    dict(countries),
)

print(
    "TYPES=",
    dict(types),
)

assert valid >= 3

print(
    "RESULT_STORAGE=PASS"
)
PY


echo "=== 6. COUNTRY SANDBOX CLEANUP ==="

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


echo "=== 7. CORE COUNTRY SELFTESTS ==="

PYTHONPATH="$R" \
"$PY" -m app.country.selftest

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_exit_observer

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_temporal

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_verdict_fusion

echo "COUNTRY_SELFTESTS=PASS"


echo "=== 8. PRODUCTION SERVICES ==="

for svc in \
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


echo "========================================"
echo "FIX22G1=PASS"
echo "FULL_REAL_COUNTRY_PIPELINE=PASS"
echo "HEALTH_GATE=PASS"
echo "REAL_XRAY_EXIT=PASS"
echo "EXIT_CONSENSUS=PASS"
echo "PRIMARY_GEO=PASS"
echo "RECOVERY_FUSION=PASS"
echo "TEMPORAL_CONFIRMATION=PASS"
echo "ATOMIC_RESULT_STORAGE=PASS"
echo "RUNTIME_CLEANUP=PASS"
echo "PERMANENT_WORKER=NOT_ENABLED"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
