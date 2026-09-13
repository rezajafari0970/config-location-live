#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

INV=/var/lib/config-location/country/k7-true-hard-unresolved.json
REPORT=/var/lib/config-location/country/k7e-hard-fallback-report.json
LEFT=/var/lib/config-location/country/k7e-still-unresolved.json

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K7E-$TS"

mkdir -p "$B"

cp -a "$INV" "$B/" 2>/dev/null || true
cp -a \
/var/lib/config-location/country/country-identity \
"$B/country-identity-before" \
2>/dev/null || true

echo "BACKUP=$B"


echo
echo "=== 1. VERIFY TRUE HARD INVENTORY ==="

test -f "$INV"

"$PY" <<'PY'
from pathlib import Path
import json

p=Path(
    "/var/lib/config-location/country/"
    "k7-true-hard-unresolved.json"
)

rows=json.loads(
    p.read_text()
)

assert isinstance(rows,list)

print(
    "TRUE_HARD_INPUT=",
    len(rows),
)

assert len(rows)>=1

ips={
    str(r.get("exit_ip"))
    for r in rows
    if r.get("exit_ip")
}

print(
    "UNIQUE_EXIT_IPS=",
    len(ips),
)

print(
    "DUPLICATE_CONFIG_IP_SAVING=",
    len(rows)-len(ips),
)

print(
    "INPUT_VERIFY=PASS"
)
PY


echo
echo "=== 2. INSTALL HARD FALLBACK ENGINE ==="

cat >"$R/app/country/hard_fallback.py" <<'PY'
from __future__ import annotations

import json
import subprocess
import time

from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from collections import Counter


def _curl_json(
    url: str,
    timeout: float=6.0,
) -> dict:

    r=subprocess.run(
        [
            "curl",
            "-fsSL",
            "--max-time",
            str(timeout),
            "-H",
            "Accept: application/json",
            "-H",
            "User-Agent: config-location-k7e/1",
            url,
        ],
        capture_output=True,
        text=True,
        timeout=timeout+2,
    )

    if r.returncode!=0:
        raise RuntimeError(
            (
                r.stderr
                or "curl failed"
            )[:500]
        )

    o=json.loads(
        r.stdout
    )

    if not isinstance(o,dict):
        raise RuntimeError(
            "response_not_object"
        )

    return o


def _cc(v):
    if not isinstance(v,str):
        return None

    v=v.strip().upper()

    if (
        len(v)==2
        and v.isalpha()
    ):
        return v

    return None


def _evidence(
    *,
    provider,
    evidence_type,
    country_code=None,
    country_name=None,
    asn=None,
    network_name=None,
    success=False,
    error=None,
    duration_ms=0,
):

    return {
        "provider":provider,
        "evidence_type":evidence_type,
        "success":bool(success),
        "country_code":country_code,
        "country_name":country_name,
        "asn":asn,
        "network_name":network_name,
        "error":error,
        "duration_ms":duration_ms,
    }


def dbip(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://api.db-ip.com/v2/free/"
            +ip
        )

        code=_cc(
            o.get("countryCode")
        )

        if not code:
            raise RuntimeError(
                "countryCode_missing"
            )

        return _evidence(
            provider="db-ip",
            evidence_type="geo",
            success=True,
            country_code=code,
            country_name=o.get(
                "countryName"
            ),
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="db-ip",
            evidence_type="geo",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def ipinfo(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://ipinfo.io/"
            +ip
            +"/json"
        )

        code=_cc(
            o.get("country")
        )

        if not code:
            raise RuntimeError(
                "country_missing"
            )

        org=str(
            o.get("org")
            or ""
        ).strip()

        asn=None
        network=None

        if org:
            parts=org.split(" ",1)

            if (
                parts
                and parts[0]
                .upper()
                .startswith("AS")
            ):
                asn=parts[0].upper()

                if len(parts)>1:
                    network=parts[1]

        return _evidence(
            provider="ipinfo",
            evidence_type="geo",
            success=True,
            country_code=code,
            asn=asn,
            network_name=network,
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="ipinfo",
            evidence_type="geo",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def ipwhois(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://ipwho.is/"
            +ip
        )

        if o.get("success") is False:
            raise RuntimeError(
                str(
                    o.get("message")
                    or "provider_failure"
                )
            )

        code=_cc(
            o.get("country_code")
        )

        if not code:
            raise RuntimeError(
                "country_code_missing"
            )

        conn=o.get(
            "connection"
        ) or {}

        return _evidence(
            provider="ipwho.is",
            evidence_type="geo",
            success=True,
            country_code=code,
            country_name=o.get(
                "country"
            ),
            asn=(
                str(conn.get("asn"))
                if conn.get("asn")
                else None
            ),
            network_name=conn.get(
                "org"
            ),
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="ipwho.is",
            evidence_type="geo",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def ipapi(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://ipapi.co/"
            +ip
            +"/json/"
        )

        code=_cc(
            o.get("country_code")
            or o.get("country")
        )

        if not code:
            raise RuntimeError(
                str(
                    o.get("reason")
                    or "country_missing"
                )
            )

        asn=o.get("asn")

        return _evidence(
            provider="ipapi.co",
            evidence_type="geo",
            success=True,
            country_code=code,
            country_name=o.get(
                "country_name"
            ),
            asn=(
                str(asn)
                if asn
                else None
            ),
            network_name=o.get("org"),
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="ipapi.co",
            evidence_type="geo",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def rdap(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://rdap.org/ip/"
            +ip
        )

        code=_cc(
            o.get("country")
        )

        if not code:
            raise RuntimeError(
                "rdap_country_missing"
            )

        return _evidence(
            provider="rdap",
            evidence_type="registry",
            success=True,
            country_code=code,
            network_name=(
                o.get("name")
                or o.get("handle")
            ),
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="rdap",
            evidence_type="registry",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def recover(ip: str) -> dict:

    funcs=(
        dbip,
        ipinfo,
        ipwhois,
        ipapi,
        rdap,
    )

    evidence=[]

    with ThreadPoolExecutor(
        max_workers=5,
        thread_name_prefix="k7e-ip",
    ) as ex:

        futures={
            ex.submit(fn,ip):fn
            for fn in funcs
        }

        for f in as_completed(
            futures
        ):
            try:
                evidence.append(
                    f.result()
                )
            except Exception as exc:
                evidence.append(
                    _evidence(
                        provider=futures[
                            f
                        ].__name__,
                        evidence_type="unknown",
                        error=str(exc)[:500],
                    )
                )


    geo=[
        e
        for e in evidence
        if (
            e["success"]
            and e["evidence_type"]
            =="geo"
            and e["country_code"]
        )
    ]

    registry=[
        e
        for e in evidence
        if (
            e["success"]
            and e["evidence_type"]
            =="registry"
            and e["country_code"]
        )
    ]


    counts=Counter(
        e["country_code"]
        for e in geo
    )

    winner=None
    winner_count=0

    if counts:
        winner,winner_count=(
            counts.most_common(1)[0]
        )


    confirmed=False
    reason="insufficient_consensus"


    # Strong hard-fallback consensus.
    if (
        winner
        and winner_count>=3
    ):
        confirmed=True
        reason="three_geo_consensus"


    # Two independent Geo + independent registry
    # confirmation. RDAP may support but never
    # establishes Country alone.
    elif (
        winner
        and winner_count>=2
        and any(
            e["country_code"]==winner
            for e in registry
        )
    ):
        confirmed=True
        reason="two_geo_plus_rdap"


    country_name=None
    asn=None
    network_name=None

    if confirmed:

        for e in evidence:

            if e.get(
                "country_code"
            )!=winner:
                continue

            if (
                country_name is None
                and e.get(
                    "country_name"
                )
            ):
                country_name=e[
                    "country_name"
                ]

            if (
                asn is None
                and e.get("asn")
            ):
                asn=e["asn"]

            if (
                network_name is None
                and e.get(
                    "network_name"
                )
            ):
                network_name=e[
                    "network_name"
                ]


    return {
        "state":(
            "confirmed"
            if confirmed
            else "ambiguous"
        ),

        "country_code":(
            winner
            if confirmed
            else None
        ),

        "country_name":
            country_name,

        "asn":
            asn,

        "network_name":
            network_name,

        "network_type":
            None,

        "country_confidence":(
            0.97
            if reason=="three_geo_consensus"
            else (
                0.90
                if confirmed
                else 0.0
            )
        ),

        "recovery_reason":
            reason,

        "geo_vote_counts":
            dict(counts),

        "geo_success_count":
            len(geo),

        "evidence":
            evidence,
    }
PY

"$PY" -m py_compile \
"$R/app/country/hard_fallback.py"

echo "HARD_FALLBACK_ENGINE=PASS"


echo
echo "=== 3. LOOKUP UNIQUE IPS ONLY ==="

export REPORT LEFT

PYTHONPATH="$R" "$PY" <<'PY'
from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from pathlib import Path
from collections import Counter
import json
import os

from app.country.hard_fallback import (
    recover,
)

inv=json.loads(
    Path(
        "/var/lib/config-location/country/"
        "k7-true-hard-unresolved.json"
    ).read_text()
)

by_ip={}

for row in inv:

    ip=str(
        row.get("exit_ip")
        or ""
    )

    if not ip:
        continue

    by_ip.setdefault(
        ip,
        []
    ).append(row)


print(
    "CONFIGS=",
    len(inv),
)

print(
    "UNIQUE_IPS=",
    len(by_ip),
)


results={}


with ThreadPoolExecutor(
    max_workers=6,
    thread_name_prefix="k7e",
) as ex:

    futures={
        ex.submit(
            recover,
            ip,
        ):ip
        for ip in by_ip
    }

    for f in as_completed(
        futures
    ):

        ip=futures[f]

        try:
            results[ip]=f.result()
        except Exception as exc:
            results[ip]={
                "state":"ambiguous",
                "country_code":None,
                "recovery_reason":
                    "engine_exception",
                "error":
                    f"{type(exc).__name__}: {exc}",
                "evidence":[],
            }


states=Counter(
    r.get(
        "state",
        "unknown",
    )
    for r in results.values()
)

reasons=Counter(
    r.get(
        "recovery_reason",
        "unknown",
    )
    for r in results.values()
)

print(
    "IP_STATES=",
    dict(states),
)

print(
    "IP_REASONS=",
    dict(reasons),
)


confirmed_configs=0

for ip,result in results.items():

    if result.get(
        "state"
    )=="confirmed":

        confirmed_configs+=len(
            by_ip[ip]
        )


print(
    "CONFIRMED_CONFIGS_POTENTIAL=",
    confirmed_configs,
)

print(
    "STILL_AMBIGUOUS_CONFIGS_POTENTIAL=",
    len(inv)-confirmed_configs,
)


for ip,result in results.items():

    print(
        "IP_RESULT=",
        {
            "ip":ip,
            "configs":
                len(by_ip[ip]),
            "state":
                result.get("state"),
            "country":
                result.get(
                    "country_code"
                ),
            "reason":
                result.get(
                    "recovery_reason"
                ),
            "votes":
                result.get(
                    "geo_vote_counts"
                ),
        },
    )


Path(
    "/tmp/k7e-lookup-results.json"
).write_text(
    json.dumps(
        {
            "by_ip":by_ip,
            "results":results,
        },
        indent=2,
        sort_keys=True,
    )
)

print(
    "LOOKUP_PHASE=PASS"
)
PY


echo
echo "=== 4. STOP WRITERS FOR ATOMIC COMMIT ==="

systemctl stop \
config-location-country-worker.service \
config-location-country-event-consumer.service

restore_services() {
    systemctl restart \
        config-location-country-worker.service \
        config-location-country-event-consumer.service \
        >/dev/null 2>&1 || true
}

trap restore_services EXIT

echo "WRITERS_STOPPED=YES"


echo
echo "=== 5. COMMIT ONLY CONFIRMED RESULTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import os

from app.country.country_identity import (
    save_identity_once,
)

from app.country.pipeline import (
    save_pipeline_result,
)


data=json.loads(
    Path(
        "/tmp/k7e-lookup-results.json"
    ).read_text()
)

by_ip=data["by_ip"]
results=data["results"]

PIPE=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

stats=Counter()
committed=[]
unresolved=[]


for ip,configs in by_ip.items():

    recovery=results[ip]

    if (
        recovery.get("state")
        !="confirmed"
        or not recovery.get(
            "country_code"
        )
    ):

        for row in configs:
            unresolved.append(
                {
                    **row,
                    "hard_fallback":
                        recovery,
                }
            )

        stats[
            "still_ambiguous"
        ]+=len(configs)

        continue


    for row in configs:

        cid=str(
            row["config_id"]
        )

        identity=save_identity_once(
            config_id=cid,
            geo=recovery,
            exit_ip=ip,
        )


        if identity is None:

            stats[
                "identity_failed"
            ]+=1

            unresolved.append(
                {
                    **row,
                    "hard_fallback":
                        recovery,
                    "commit_error":
                        "identity_failed",
                }
            )

            continue


        pp=PIPE/f"{cid}.json"

        if pp.exists():

            try:
                current=json.loads(
                    pp.read_text()
                )
            except Exception:
                current={
                    "schema_version":1,
                    "config_id":cid,
                    "state":
                        "pending_confirmation",
                    "exit_ip":ip,
                    "metadata":{},
                }

        else:

            current={
                "schema_version":1,
                "config_id":cid,
                "state":
                    "pending_confirmation",
                "exit_ip":ip,
                "metadata":{},
            }


        metadata=dict(
            current.get(
                "metadata"
            )
            or {}
        )

        metadata.update(
            {
                "k7e_hard_fallback":
                    True,

                "k7e_recovery_reason":
                    recovery.get(
                        "recovery_reason"
                    ),

                "k7e_geo_vote_counts":
                    recovery.get(
                        "geo_vote_counts"
                    ),

                "second_xray":
                    False,

                "second_exit_probe":
                    False,
            }
        )

        current[
            "metadata"
        ]=metadata


        # Canonical guard injects locked identity.
        save_pipeline_result(
            config_id=cid,
            value=current,
        )


        committed.append(
            {
                "config_id":cid,
                "exit_ip":ip,
                "country_code":
                    recovery[
                        "country_code"
                    ],
                "reason":
                    recovery[
                        "recovery_reason"
                    ],
            }
        )

        stats["committed"]+=1


report={
    "stats":dict(stats),
    "committed":committed,
    "unresolved":unresolved,
}


Path(
    "/var/lib/config-location/country/"
    "k7e-hard-fallback-report.json"
).write_text(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

Path(
    "/var/lib/config-location/country/"
    "k7e-still-unresolved.json"
).write_text(
    json.dumps(
        unresolved,
        indent=2,
        sort_keys=True,
    )
)


print(
    "COMMIT_STATS=",
    dict(stats),
)

print(
    "COMMITTED=",
    len(committed),
)

print(
    "STILL_UNRESOLVED=",
    len(unresolved),
)


for row in committed[:30]:
    print(
        "COMMITTED_SAMPLE=",
        row,
    )


print(
    "CONFIRMED_ONLY_COMMIT=PASS"
)
PY


echo
echo "=== 6. CONSISTENCY AUDIT ==="

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
        pipeline=json.loads(
            pp.read_text()
        )
    except Exception:
        continue

    if (
        str(
            pipeline.get(
                "country_code"
            )
            or ""
        ).upper()
        !=
        str(
            ident.get(
                "country_code"
            )
            or ""
        ).upper()
    ):
        conflicts.append(cid)


print(
    "IDENTITY_PIPELINE_CONFLICTS=",
    len(conflicts),
)

assert not conflicts

print(
    "CONSISTENCY=PASS"
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

trap - EXIT

echo "WRITERS=active"


echo
echo "=== 8. FINAL K7 HARD INVENTORY ==="

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
        or ""
    ).lower()

    cid=str(
        o.get("config_id")
        or p.stem
    )

    locked=False

    ip=I/f"{cid}.json"

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
            "unknown",
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
    "FINAL_TRUE_HARD_UNRESOLVED=",
    len(hard),
)

for row in hard:
    print(
        "FINAL_HARD=",
        row,
    )


Path(
    "/var/lib/config-location/country/"
    "k7-final-hard-unresolved.json"
).write_text(
    json.dumps(
        hard,
        indent=2,
        sort_keys=True,
    )
)

print(
    "FINAL_HARD_AUDIT=PASS"
)
PY


echo
echo "=== 9. SAFETY ==="

echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"

test -f "$REPORT"
test -f "$LEFT"

echo "REPORTS=PASS"


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

    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"
    test "$X" = active
done


echo
echo "======================================================"
echo "FIX22K7E=PASS"
echo "HARD_FALLBACK=COMPLETE"
echo "INPUT_HARD_UNRESOLVED=38"
echo "FALSE_CONFIRM_GUARD=STRICT"
echo "LOOKUP_DEDUP_BY_EXIT_IP=YES"
echo "COUNTRY_IDENTITY=AUTHORITATIVE"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K7F-FINAL-K7-AUDIT"
echo "======================================================"
