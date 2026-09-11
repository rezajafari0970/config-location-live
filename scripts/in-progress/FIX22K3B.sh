#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

OBS="$R/app/country/exit_observer.py"
FAST="$R/app/country/same_runtime_fastpath.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K3B-$TS"

mkdir -p "$B"

cp -a "$OBS" "$B/"
cp -a "$FAST" "$B/"

echo "BACKUP=$B"


echo "=== 1. REPLACE OBSERVER WITH PARALLEL ORCHESTRATION ==="

export OBS

"$PY" <<'PY'
from pathlib import Path
import ast
import os

p=Path(os.environ["OBS"])
s=p.read_text()

if (
    "FIX22K3_PARALLEL_EXIT_OBSERVER"
    in s
):
    print(
        "PARALLEL_OBSERVER_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


# Add concurrent imports.
s=s.replace(
    "import time\n",
    "import time\n"
    "\n"
    "from concurrent.futures import (\n"
    "    ThreadPoolExecutor,\n"
    "    as_completed,\n"
    ")\n",
    1,
)


tree=ast.parse(s)

target=None

for n in tree.body:

    if (
        isinstance(n,ast.FunctionDef)
        and n.name=="observe_exit_ip"
    ):
        target=n
        break

assert target is not None


start=target.lineno-1
end=target.end_lineno


new_func=r'''def observe_exit_ip(
    *,
    proxy_url: str | None,
    endpoints: Iterable[
        tuple[str, str]
    ] = DEFAULT_ENDPOINTS,
    timeout: float = 8.0,
    minimum_agreement: int = 2,
) -> ExitObservation:
    """
    FIX22K3_PARALLEL_EXIT_OBSERVER

    Run independent exit-IP providers concurrently.

    Semantics preserved:
      - only globally-routable IPs are accepted
      - minimum_agreement remains authoritative
      - disagreement never becomes confirmed

    Optimization:
      - return immediately once enough providers
        agree on the same exit IP.
    """

    endpoint_list=tuple(endpoints)

    if not endpoint_list:

        return ExitObservation(
            state="error",
            exit_ip=None,
            agreed=0,
            successful=0,
            total=0,
            probes=(),
            reason="no_exit_endpoints",
        )


    workers=min(
        len(endpoint_list),
        4,
    )


    executor=ThreadPoolExecutor(
        max_workers=workers,
        thread_name_prefix=
            "country-exit",
    )


    futures={
        executor.submit(
            probe_exit_ip,
            provider=provider,
            url=url,
            proxy_url=proxy_url,
            timeout=timeout,
        ):(
            provider,
            url,
        )
        for provider,url
        in endpoint_list
    }


    completed=[]
    counts=Counter()


    try:

        for future in as_completed(
            futures
        ):

            try:
                probe=future.result()

            except Exception as exc:

                provider,url=(
                    futures[future]
                )

                probe=ExitProbe(
                    provider=provider,
                    url=url,
                    success=False,
                    ip=None,
                    duration_ms=0,
                    error=(
                        f"{type(exc).__name__}: "
                        f"{exc}"
                    )[:500],
                )


            completed.append(probe)


            if (
                probe.success
                and probe.ip
            ):

                counts[
                    probe.ip
                ]+=1


                agreed=counts[
                    probe.ip
                ]


                if (
                    agreed
                    >= minimum_agreement
                ):

                    # Do not wait for slower providers.
                    # Futures that have not started are
                    # cancelled; running curl processes
                    # finish under their own timeout.
                    for f in futures:

                        if not f.done():
                            f.cancel()


                    return ExitObservation(
                        state="confirmed",
                        exit_ip=probe.ip,
                        agreed=agreed,
                        successful=sum(
                            1
                            for p in completed
                            if (
                                p.success
                                and p.ip
                            )
                        ),
                        total=len(
                            endpoint_list
                        ),
                        probes=tuple(
                            completed
                        ),
                        reason=(
                            "exit_ip_consensus_"
                            "parallel_early_exit"
                        ),
                    )


        successful=[
            p
            for p in completed
            if (
                p.success
                and p.ip
            )
        ]


        if not successful:

            return ExitObservation(
                state="error",
                exit_ip=None,
                agreed=0,
                successful=0,
                total=len(
                    endpoint_list
                ),
                probes=tuple(
                    completed
                ),
                reason=(
                    "no_exit_probe_succeeded"
                ),
            )


        counts=Counter(
            p.ip
            for p in successful
        )

        exit_ip,agreed=(
            counts.most_common(1)[0]
        )


        if (
            agreed
            >= minimum_agreement
        ):

            return ExitObservation(
                state="confirmed",
                exit_ip=exit_ip,
                agreed=agreed,
                successful=len(
                    successful
                ),
                total=len(
                    endpoint_list
                ),
                probes=tuple(
                    completed
                ),
                reason=(
                    "exit_ip_consensus_parallel"
                ),
            )


        return ExitObservation(
            state="unstable_exit",
            exit_ip=None,
            agreed=agreed,
            successful=len(
                successful
            ),
            total=len(
                endpoint_list
            ),
            probes=tuple(
                completed
            ),
            reason=(
                "exit_ip_disagreement"
            ),
        )


    finally:

        executor.shutdown(
            wait=False,
            cancel_futures=True,
        )
'''


lines=s.splitlines(
    keepends=True
)

replacement=[
    line+"\n"
    for line in new_func.splitlines()
]

lines[
    start:end
]=replacement

new="".join(lines)

ast.parse(new)

p.write_text(new)

print(
    "PARALLEL_OBSERVER_PATCH=PASS"
)
PY


echo "=== 2. SHORT FASTPATH BUDGET ==="

export FAST

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["FAST"])
s=p.read_text()

old='''        obs=observe_exit_ip(
            proxy_url=proxy_url,
        )
'''

new='''        obs=observe_exit_ip(
            proxy_url=proxy_url,
            timeout=3.0,
            minimum_agreement=2,
        )
'''

if old not in s:

    if "timeout=3.0" in s:
        print(
            "FAST_BUDGET_ALREADY_PRESENT=YES"
        )
        raise SystemExit(0)

    raise SystemExit(
        "ERROR: fastpath observer call "
        "not found"
    )

s=s.replace(
    old,
    new,
    1,
)

p.write_text(s)

print(
    "FASTPATH_TIMEOUT_3S=PASS"
)
PY


echo "=== 3. COMPILE ==="

"$PY" -m py_compile \
"$OBS" \
"$FAST" \
"$R/app/health/core/engine.py"

echo "COMPILE=PASS"


echo "=== 4. SELFTEST EXISTING OBSERVER ==="

PYTHONPATH="$R" \
"$PY" \
-m app.country.selftest_exit_observer

echo "EXISTING_SELFTEST=PASS"


echo "=== 5. PARALLELISM SYNTHETIC TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import time

import app.country.exit_observer as m

original=m.probe_exit_ip


def fake(
    *,
    provider,
    url,
    proxy_url,
    timeout,
):

    delay={
        "a":0.30,
        "b":0.35,
        "c":2.00,
    }[provider]

    time.sleep(delay)

    return m.ExitProbe(
        provider=provider,
        url=url,
        success=True,
        ip=(
            "8.8.8.8"
            if provider in {
                "a",
                "b",
            }
            else "1.1.1.1"
        ),
        duration_ms=int(
            delay*1000
        ),
    )


m.probe_exit_ip=fake

started=time.monotonic()

try:

    r=m.observe_exit_ip(
        proxy_url=None,
        endpoints=(
            ("a","a"),
            ("b","b"),
            ("c","c"),
        ),
        timeout=3.0,
        minimum_agreement=2,
    )

finally:
    m.probe_exit_ip=original


elapsed=(
    time.monotonic()
    - started
)


print(
    "SYNTH_STATE=",
    r.state,
)

print(
    "SYNTH_IP=",
    r.exit_ip,
)

print(
    "SYNTH_AGREED=",
    r.agreed,
)

print(
    "SYNTH_ELAPSED=",
    round(
        elapsed,
        3,
    ),
)


assert r.state=="confirmed"
assert r.exit_ip=="8.8.8.8"
assert r.agreed>=2

# Must early-return before slow 2s provider.
assert elapsed < 1.0

print(
    "PARALLEL_EARLY_EXIT=PASS"
)
PY


echo "=== 6. RESET PERFORMANCE METRICS ==="

rm -f \
/var/lib/config-location/country/same-runtime-fastpath.jsonl \
2>/dev/null || true

echo "METRICS_RESET=PASS"


echo "=== 7. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH=active"


echo "=== 8. COLLECT REAL SAMPLE ==="

MET=/var/lib/config-location/country/same-runtime-fastpath.jsonl

FOUND=0

for i in $(seq 1 36)
do

    N=0

    if [ -f "$MET" ]; then
        N=$(wc -l <"$MET")
    fi

    echo "T=$((i*5))s ROWS=$N"

    if [ "$N" -ge 30 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1


echo "=== 9. REAL PERFORMANCE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "same-runtime-fastpath.jsonl"
)

rows=[]

for line in p.read_text().splitlines():

    try:
        rows.append(
            json.loads(line)
        )
    except Exception:
        pass


print(
    "ROWS=",
    len(rows),
)

assert len(rows)>=30


c=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)

print(
    "STATUS=",
    dict(c),
)


times=sorted(
    int(
        r.get(
            "elapsed_ms",
            0,
        )
        or 0
    )
    for r in rows
)


def pct(x):

    i=min(
        len(times)-1,
        int(
            (len(times)-1)*x
        ),
    )

    return times[i]


print(
    "MIN_MS=",
    times[0],
)

print(
    "P50_MS=",
    pct(.50),
)

print(
    "P90_MS=",
    pct(.90),
)

print(
    "P95_MS=",
    pct(.95),
)

print(
    "MAX_MS=",
    times[-1],
)

print(
    "AVG_MS=",
    round(
        sum(times)
        / len(times),
        2,
    ),
)


success=c.get(
    "success",
    0,
)

rate=(
    success
    / len(rows)
)

print(
    "SUCCESS_RATE=",
    round(
        rate,
        4,
    ),
)


assert success>=1

# Hard safety ceiling:
# same-runtime fast path should not hold Health
# for the old 8s-per-provider behavior.
assert pct(.95) <= 5000


print(
    "REAL_PARALLEL_FASTPATH=PASS"
)
PY


echo "=== 10. K2 HANDOFF STILL PRESENT ==="

"$PY" <<'PY'
from pathlib import Path
import json
import time

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

cut=time.time()-180

n=0

for p in H.glob("*.json"):

    if p.stat().st_mtime < cut:
        continue

    try:
        h=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    fast=(
        (
            h.get("metadata")
            or {}
        ).get(
            "same_runtime_country"
        )
    )

    if isinstance(
        fast,
        dict,
    ):
        n+=1


print(
    "RECENT_K2_HANDOFF=",
    n,
)

assert n>=1

print(
    "K2_HANDOFF=PASS"
)
PY


echo "=== 11. SERVICES ==="

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


echo "======================================================"
echo "FIX22K3B=PASS"
echo "PARALLEL_EXIT_PROBES=YES"
echo "EARLY_CONSENSUS=YES"
echo "MINIMUM_AGREEMENT=2"
echo "FASTPATH_TIMEOUT_PER_PROVIDER=3S"
echo "SECOND_XRAY=NO"
echo "K2_HANDOFF=PRESERVED"
echo "NEXT=FIX22K3C"
echo "======================================================"
