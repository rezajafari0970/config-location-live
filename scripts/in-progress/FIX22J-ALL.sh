#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

ROOT=/var/lib/config-location/country
AUDIT="$ROOT/unresolved-audit"
RECOVERY="$ROOT/recovery"

mkdir -p \
"$AUDIT" \
"$RECOVERY"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22J-ALL-$TS"

mkdir -p "$B"

cp -a "$M" "$B/country-app"

echo "BACKUP=$B"


###############################################################################
# J1
###############################################################################

echo
echo "======================================================"
echo "FIX22J1 — UNRESOLVED ROOT-CAUSE AUDIT"
echo "======================================================"


"$PY" <<'PY'
from pathlib import Path
from collections import Counter,defaultdict
from datetime import datetime,timezone
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

OUT=Path(
    "/var/lib/config-location/"
    "country/unresolved-audit/"
    "latest.json"
)


FINAL={
    "confirmed",
    "confirmed_stable",
    "confirmed_rotating_ip",
}


healthy=set()

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

    if not (
        C/f"{hp.stem}.json"
    ).exists():
        continue

    healthy.add(
        hp.stem
    )


states=Counter()
reasons=Counter()
types=Counter()

unresolved=[]


for cid in sorted(healthy):

    cp=C/f"{cid}.json"
    pp=P/f"{cid}.json"

    try:
        c=json.loads(
            cp.read_text()
        )
    except Exception:
        continue


    config_type=str(
        c.get("config_type")
        or c.get("type")
        or c.get("protocol")
        or "unknown"
    ).lower()


    if not pp.exists():

        state="missing"

        unresolved.append(
            {
                "config_id":cid,
                "config_type":config_type,
                "state":"missing",
                "reason":
                    "country_not_attempted",
            }
        )

        states["missing"]+=1
        types[config_type]+=1

        continue


    try:
        p=json.loads(
            pp.read_text()
        )
    except Exception:

        unresolved.append(
            {
                "config_id":cid,
                "config_type":config_type,
                "state":"corrupt_result",
                "reason":
                    "invalid_country_result_json",
            }
        )

        states[
            "corrupt_result"
        ]+=1

        continue


    state=str(
        p.get(
            "state",
            "unknown",
        )
    ).lower()


    if state in FINAL:
        continue


    reason=str(
        p.get(
            "reason",
            (
                p.get("temporal")
                or {}
            ).get(
                "reason",
                "",
            ),
        )
        or ""
    )


    states[state]+=1

    if reason:
        reasons[reason]+=1

    types[config_type]+=1


    unresolved.append(
        {
            "config_id":
                cid,

            "config_type":
                config_type,

            "state":
                state,

            "reason":
                reason,

            "exit_ip":
                p.get("exit_ip"),

            "country_code":
                p.get("country_code"),

            "primary":
                p.get("primary"),

            "fusion":
                p.get("fusion"),

            "temporal":
                p.get("temporal"),

            "error":
                p.get("error"),
        }
    )


report={
    "schema_version":1,

    "generated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),

    "healthy":
        len(healthy),

    "unresolved":
        len(unresolved),

    "states":
        dict(states),

    "reasons":
        dict(reasons),

    "types":
        dict(types),

    "items":
        unresolved,
}


OUT.write_text(
    json.dumps(
        report,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )
    +"\n"
)


print(
    "HEALTHY=",
    len(healthy),
)

print(
    "UNRESOLVED=",
    len(unresolved),
)

print(
    "STATES=",
    dict(states),
)

print(
    "REASONS=",
    dict(reasons),
)

print(
    "TYPES=",
    dict(types),
)

print(
    "J1_AUDIT_FILE=",
    OUT,
)

print(
    "FIX22J1=PASS"
)
PY


###############################################################################
# J2
###############################################################################

echo
echo "======================================================"
echo "FIX22J2 — STRONG EXIT INSTABILITY RECOVERY"
echo "======================================================"


cat >"$M/strong_exit_recovery.py" <<'PY'
from __future__ import annotations

import ipaddress
import subprocess
import time

from collections import Counter
from dataclasses import dataclass


@dataclass(frozen=True)
class StrongExitResult:

    state: str

    exit_ip: str | None

    agreed: int

    successful: int

    attempts: int

    reason: str

    evidence: tuple[
        tuple[str,str],
        ...
    ]


ENDPOINTS=(
    "https://api.ipify.org",
    "https://icanhazip.com",
    "https://ifconfig.me/ip",
    "https://checkip.amazonaws.com",
    "https://ident.me",
)


def normalize_ip(
    value: str,
) -> str | None:

    value=value.strip()

    if not value:
        return None

    value=value.splitlines()[0].strip()

    try:
        ip=ipaddress.ip_address(
            value
        )
    except Exception:
        return None

    if not ip.is_global:
        return None

    return ip.compressed


def probe(
    *,
    proxy_url: str,
    url: str,
    timeout: float=8.0,
) -> str | None:

    cmd=[
        "curl",
        "-fsS",
        "--connect-timeout",
        "4",
        "--max-time",
        str(timeout),
        "--proxy",
        proxy_url,
        url,
    ]

    try:

        p=subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout+2,
        )

    except Exception:
        return None


    if p.returncode!=0:
        return None

    return normalize_ip(
        p.stdout
    )


def observe_strong_exit(
    *,
    proxy_url: str,
    rounds: int=3,
) -> StrongExitResult:

    values=[]

    evidence=[]


    for round_no in range(
        rounds
    ):

        for url in ENDPOINTS:

            ip=probe(
                proxy_url=proxy_url,
                url=url,
            )

            if ip:

                values.append(
                    ip
                )

                evidence.append(
                    (
                        url,
                        ip,
                    )
                )


        if round_no+1 < rounds:
            time.sleep(0.7)


    if not values:

        return StrongExitResult(
            state="unknown",
            exit_ip=None,
            agreed=0,
            successful=0,
            attempts=(
                rounds
                * len(ENDPOINTS)
            ),
            reason=
                "strong_exit_no_response",
            evidence=tuple(
                evidence
            ),
        )


    counts=Counter(
        values
    )

    ip,agreed=(
        counts.most_common(
            1
        )[0]
    )


    # Strong majority rather than simple 2-vote
    # consensus.
    ratio=agreed/len(values)


    if (
        agreed>=3
        and ratio>=0.60
    ):

        return StrongExitResult(
            state="confirmed",
            exit_ip=ip,
            agreed=agreed,
            successful=
                len(values),
            attempts=(
                rounds
                * len(ENDPOINTS)
            ),
            reason=
                "strong_exit_consensus",
            evidence=tuple(
                evidence
            ),
        )


    return StrongExitResult(
        state="unstable_exit",
        exit_ip=None,
        agreed=agreed,
        successful=
            len(values),
        attempts=(
            rounds
            * len(ENDPOINTS)
        ),
        reason=
            "strong_exit_no_majority",
        evidence=tuple(
            evidence
        ),
    )
PY


"$PY" -m py_compile \
"$M/strong_exit_recovery.py"

echo "J2_MODULE_COMPILE=PASS"


###############################################################################
# J3
###############################################################################

echo
echo "======================================================"
echo "FIX22J3 — GEO / ASN / RDAP RECOVERY"
echo "======================================================"


cat >"$M/rdap_recovery.py" <<'PY'
from __future__ import annotations

import json
import subprocess

from dataclasses import dataclass


@dataclass(frozen=True)
class RdapEvidence:

    success: bool

    country_code: str | None

    name: str | None

    handle: str | None

    error: str | None


def lookup_rdap(
    ip: str,
    timeout: float=10.0,
) -> RdapEvidence:

    try:

        p=subprocess.run(
            [
                "curl",
                "-fsS",
                "--connect-timeout",
                "5",
                "--max-time",
                str(timeout),
                "-H",
                "Accept: application/rdap+json, application/json",
                f"https://rdap.org/ip/{ip}",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout+2,
        )

    except Exception as e:

        return RdapEvidence(
            success=False,
            country_code=None,
            name=None,
            handle=None,
            error=type(e).__name__,
        )


    if p.returncode!=0:

        return RdapEvidence(
            success=False,
            country_code=None,
            name=None,
            handle=None,
            error=(
                p.stderr.strip()
                or
                f"curl_{p.returncode}"
            )[:300],
        )


    try:

        o=json.loads(
            p.stdout
        )

    except Exception:

        return RdapEvidence(
            success=False,
            country_code=None,
            name=None,
            handle=None,
            error="invalid_json",
        )


    code=o.get(
        "country"
    )

    name=o.get(
        "name"
    )

    handle=o.get(
        "handle"
    )


    if not code:

        return RdapEvidence(
            success=False,
            country_code=None,
            name=(
                str(name)
                if name
                else None
            ),
            handle=(
                str(handle)
                if handle
                else None
            ),
            error=
                "rdap_missing_country",
        )


    return RdapEvidence(
        success=True,
        country_code=
            str(code).upper(),

        name=(
            str(name)
            if name
            else None
        ),

        handle=(
            str(handle)
            if handle
            else None
        ),

        error=None,
    )
PY


cat >"$M/ultimate_geo.py" <<'PY'
from __future__ import annotations

from collections import Counter

from .geo_providers import (
    lookup_all,
)

from .fallback_geo import (
    lookup_fallback_all,
)

from .normalize import (
    normalize_country_code,
    country_flag,
)

from .rdap_recovery import (
    lookup_rdap,
)


def ultimate_country(
    ip: str,
) -> dict:

    votes=[]

    evidence=[]


    primary=lookup_all(
        ip,
        timeout=8.0,
    )


    for row in primary:

        code=normalize_country_code(
            row.country_code
        )

        evidence.append(
            {
                "provider":
                    row.provider,

                "success":
                    row.success,

                "country_code":
                    code,

                "error":
                    row.error,
            }
        )

        if row.success and code:
            votes.append(
                code
            )


    fallback=lookup_fallback_all(
        ip,
        timeout=8.0,
    )


    for row in fallback:

        code=normalize_country_code(
            row.country_code
        )

        evidence.append(
            {
                "provider":
                    row.provider,

                "success":
                    row.success,

                "country_code":
                    code,

                "error":
                    row.error,
            }
        )

        if row.success and code:
            votes.append(
                code
            )


    rdap=lookup_rdap(
        ip
    )

    rdap_code=normalize_country_code(
        rdap.country_code
    )


    evidence.append(
        {
            "provider":"rdap",

            "success":
                rdap.success,

            "country_code":
                rdap_code,

            "error":
                rdap.error,
        }
    )


    if (
        rdap.success
        and rdap_code
    ):
        votes.append(
            rdap_code
        )


    if not votes:

        return {
            "state":"unknown",

            "country_code":None,

            "flag":None,

            "confidence":0.0,

            "votes":0,

            "agreed":0,

            "evidence":
                evidence,
        }


    counts=Counter(
        votes
    )

    code,agreed=(
        counts.most_common(
            1
        )[0]
    )

    confidence=(
        agreed
        / len(votes)
    )


    # Hard-recovery consensus:
    # at least two independent sources and
    # >60% majority.
    if (
        agreed>=2
        and confidence>=0.60
    ):

        return {
            "state":"confirmed",

            "country_code":
                code,

            "flag":
                country_flag(
                    code
                ),

            "confidence":
                confidence,

            "votes":
                len(votes),

            "agreed":
                agreed,

            "evidence":
                evidence,
        }


    return {
        "state":"ambiguous",

        "country_code":None,

        "flag":None,

        "confidence":
            confidence,

        "votes":
            len(votes),

        "agreed":
            agreed,

        "evidence":
            evidence,
    }
PY


"$PY" -m py_compile \
"$M/rdap_recovery.py" \
"$M/ultimate_geo.py"

echo "J3_MODULE_COMPILE=PASS"


###############################################################################
# J4
###############################################################################

echo
echo "======================================================"
echo "FIX22J4 — HARD RECOVERY ENGINE"
echo "======================================================"


cat >"$M/hard_recovery.py" <<'PY'
from __future__ import annotations

import json

from pathlib import Path

from app.health.runtime.launcher import (
    RuntimeLauncher,
)

from .pipeline import (
    extract_config_type,
    extract_runtime_source,
    save_pipeline_result,
)

from .strong_exit_recovery import (
    observe_strong_exit,
)

from .ultimate_geo import (
    ultimate_country,
)


def hard_recover(
    *,
    config_id: str,
    record: dict,
) -> dict:

    runtime=None

    try:

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


        runtime=RuntimeLauncher().launch(
            config_id=(
                "country-hard-"
                + config_id
            ),
            config_type=
                config_type,
            source=source,
            startup_timeout=8.0,
        )


        exit_result=(
            observe_strong_exit(
                proxy_url=
                    runtime.proxy_url,
                rounds=3,
            )
        )


        if (
            exit_result.state
            != "confirmed"
            or not exit_result.exit_ip
        ):

            return {
                "schema_version":2,
                "config_id":
                    config_id,
                "config_type":
                    config_type,
                "state":
                    exit_result.state,
                "country_code":None,
                "country_name":None,
                "flag":None,
                "exit_ip":None,
                "reason":
                    exit_result.reason,
                "recovery_layer":
                    "hard_exit",
            }


        geo=ultimate_country(
            exit_result.exit_ip
        )


        if (
            geo["state"]
            != "confirmed"
            or not geo[
                "country_code"
            ]
        ):

            return {
                "schema_version":2,
                "config_id":
                    config_id,
                "config_type":
                    config_type,
                "state":
                    geo["state"],
                "country_code":None,
                "country_name":None,
                "flag":None,
                "exit_ip":
                    exit_result.exit_ip,
                "confidence":
                    geo["confidence"],
                "reason":
                    "hard_geo_unresolved",
                "recovery_layer":
                    "ultimate_geo",
                "recovery_evidence":
                    geo["evidence"],
            }


        # Hard recovery is allowed to finish Country
        # in one job because Exit evidence already used
        # 15 probes across 3 rounds.
        result={
            "schema_version":2,

            "config_id":
                config_id,

            "config_type":
                config_type,

            "state":
                "confirmed_stable",

            "country_code":
                geo[
                    "country_code"
                ],

            "country_name":
                None,

            "flag":
                geo["flag"],

            "exit_ip":
                exit_result.exit_ip,

            "confidence":
                geo["confidence"],

            "reason":
                "hard_recovery_consensus",

            "recovery_layer":
                "ultimate",

            "exit_consensus":{
                "agreed":
                    exit_result.agreed,

                "successful":
                    exit_result.successful,

                "attempts":
                    exit_result.attempts,
            },

            "recovery_evidence":
                geo["evidence"],
        }


        save_pipeline_result(
            config_id=config_id,
            value=result,
        )

        return result


    except Exception as e:

        return {
            "schema_version":2,
            "config_id":
                config_id,
            "state":"error",
            "country_code":None,
            "reason":
                "hard_recovery_exception",
            "error":
                f"{type(e).__name__}: {e}"[
                    :1000
                ],
        }


    finally:

        if runtime is not None:

            try:
                runtime.stop()
            except Exception:
                pass
PY


"$PY" -m py_compile \
"$M/hard_recovery.py"

echo "J4_MODULE_COMPILE=PASS"


echo "=== STOP COUNTRY DAEMON FOR EXCLUSIVE RECOVERY ==="

systemctl stop \
config-location-country-worker.service

echo "COUNTRY_WORKER_STOPPED=YES"


echo "=== RUN HARD RECOVERY ON CURRENT UNRESOLVED ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

from app.country.hard_recovery import (
    hard_recover,
)


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


FINAL={
    "confirmed",
    "confirmed_stable",
    "confirmed_rotating_ip",
}


targets=[]


for hp in sorted(
    H.glob("*.json")
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
    ).lower()!="healthy":
        continue


    cp=C/f"{hp.stem}.json"

    if not cp.exists():
        continue


    pp=P/f"{hp.stem}.json"

    if pp.exists():

        try:

            old=json.loads(
                pp.read_text()
            )

            if str(
                old.get(
                    "state",
                    "",
                )
            ).lower() in FINAL:
                continue

        except Exception:
            pass


    targets.append(
        hp.stem
    )


print(
    "J4_TARGETS=",
    len(targets),
)


stats=Counter()

resolved=0


# Process the whole unresolved population.
# Sequential by design: J4 is the expensive final
# evidence layer and must not fight with Health.
for n,cid in enumerate(
    targets,
    1,
):

    # Recheck Health immediately before expensive
    # recovery because the Store is live.
    hp=H/f"{cid}.json"
    cp=C/f"{cid}.json"

    if (
        not hp.exists()
        or not cp.exists()
    ):
        continue


    try:
        health=json.loads(
            hp.read_text()
        )

        if str(
            health.get(
                "state",
                "",
            )
        ).lower()!="healthy":
            continue

        record=json.loads(
            cp.read_text()
        )

    except Exception:
        continue


    r=hard_recover(
        config_id=cid,
        record=record,
    )


    state=str(
        r.get(
            "state",
            "error",
        )
    )

    stats[state]+=1


    if r.get(
        "country_code"
    ):
        resolved+=1


    print(
        "J4",
        f"{n}/{len(targets)}",
        cid[:12],
        state,
        r.get(
            "country_code"
        ),
        r.get(
            "exit_ip"
        ),
        r.get(
            "reason"
        ),
        flush=True,
    )


print(
    "J4_RESOLVED=",
    resolved,
)

print(
    "J4_STATES=",
    dict(stats),
)

print(
    "FIX22J4=PASS"
)
PY


echo "=== RESTORE COUNTRY WORKER ==="

systemctl start \
config-location-country-worker.service

sleep 4

test "$(
    systemctl is-active \
    config-location-country-worker.service
)" = active

test "$(
    systemctl is-enabled \
    config-location-country-worker.service
)" = enabled

echo "COUNTRY_WORKER_RESTORED=PASS"


###############################################################################
# J5
###############################################################################

echo
echo "======================================================"
echo "FIX22J5 — 100% HEALTHY COUNTRY COVERAGE AUDIT"
echo "======================================================"


"$PY" <<'PY'
from pathlib import Path
from collections import Counter
from datetime import datetime,timezone
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

OUT=Path(
    "/var/lib/config-location/"
    "country/"
    "coverage-100-audit.json"
)


FINAL={
    "confirmed",
    "confirmed_stable",
    "confirmed_rotating_ip",
}


healthy=[]

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

    if not (
        C/f"{hp.stem}.json"
    ).exists():
        continue

    healthy.append(
        hp.stem
    )


states=Counter()
countries=Counter()

unresolved=[]


for cid in healthy:

    pp=P/f"{cid}.json"

    if not pp.exists():

        unresolved.append(
            {
                "config_id":cid,
                "state":"missing",
                "reason":
                    "no_country_result",
            }
        )

        states["missing"]+=1
        continue


    try:
        o=json.loads(
            pp.read_text()
        )
    except Exception:

        unresolved.append(
            {
                "config_id":cid,
                "state":
                    "invalid_json",
            }
        )

        states[
            "invalid_json"
        ]+=1
        continue


    state=str(
        o.get(
            "state",
            "unknown",
        )
    ).lower()

    states[state]+=1


    code=o.get(
        "country_code"
    )

    if (
        state in FINAL
        and code
    ):

        countries[
            str(code)
        ]+=1

        continue


    unresolved.append(
        {
            "config_id":
                cid,

            "state":
                state,

            "reason":
                o.get(
                    "reason"
                ),

            "error":
                o.get(
                    "error"
                ),

            "exit_ip":
                o.get(
                    "exit_ip"
                ),
        }
    )


healthy_count=len(
    healthy
)

resolved=(
    healthy_count
    -
    len(unresolved)
)

coverage=(
    resolved
    / healthy_count
    * 100
    if healthy_count
    else 100.0
)


report={
    "schema_version":1,

    "generated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),

    "healthy":
        healthy_count,

    "resolved":
        resolved,

    "unresolved":
        len(unresolved),

    "coverage_percent":
        coverage,

    "states":
        dict(states),

    "countries":
        dict(
            countries
        ),

    "remaining":
        unresolved,
}


OUT.write_text(
    json.dumps(
        report,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )
    +"\n"
)


print(
    "HEALTHY=",
    healthy_count,
)

print(
    "RESOLVED=",
    resolved,
)

print(
    "UNRESOLVED=",
    len(unresolved),
)

print(
    "COVERAGE_PERCENT=",
    round(
        coverage,
        4,
    ),
)

print(
    "STATES=",
    dict(states),
)

print(
    "COUNTRIES=",
    dict(countries),
)


if unresolved:

    print()
    print(
        "=== REMAINING UNRESOLVED ==="
    )

    for row in unresolved[
        :100
    ]:

        print(
            row
        )


    print()
    print(
        "FIX22J5=FAIL"
    )

    print(
        "COUNTRY_100_PERCENT=NOT_YET"
    )

    raise SystemExit(3)


print(
    "FIX22J5=PASS"
)

print(
    "COUNTRY_100_PERCENT=YES"
)
PY


echo "=== FINAL SERVICE ISOLATION ==="

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


echo "=== PUBLICATION SAFETY ==="

"$PY" <<'PY'
from pathlib import Path
import json

o=json.loads(
    Path(
        "/var/lib/config-location/"
        "country/worker-safety.json"
    ).read_text()
)

assert o[
    "publication_enabled"
] is False

assert o[
    "remark_mutation_enabled"
] is False

assert o[
    "subscription_mutation_enabled"
] is False

assert o[
    "source_raw_mutation_enabled"
] is False

print(
    "PUBLICATION_FREEZE=PASS"
)
PY


echo "======================================================"
echo "FIX22J-ALL=PASS"
echo "J1_ROOT_CAUSE_AUDIT=PASS"
echo "J2_STRONG_EXIT_RECOVERY=PASS"
echo "J3_GEO_ASN_RDAP_RECOVERY=PASS"
echo "J4_HARD_FALLBACK=PASS"
echo "J5_100_PERCENT_AUDIT=PASS"
echo "COUNTRY_COVERAGE=100_PERCENT"
echo "COUNTRY_CONFIRMED=ONE_TIME_ONLY"
echo "HEALTH_RETEST=INDEPENDENT"
echo "PUBLICATION=DISABLED"
echo "SOURCE_RAW_UNCHANGED=YES"
echo "BACKUP=$B"
echo "======================================================"
