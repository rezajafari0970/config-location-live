#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
F="$R/app/country/exit_observer.py"
PY="$R/venv/bin/python"

echo "=== 1. COMPLETE EXIT OBSERVER ==="

nl -ba "$F" \
| sed -n '1,320p'

echo
echo "=== 2. FUNCTION MAP ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/country/"
    "exit_observer.py"
)

s=p.read_text()
t=ast.parse(s)

for n in t.body:

    if isinstance(
        n,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):

        print(
            f"{n.name}:"
            f"{n.lineno}-"
            f"{n.end_lineno}"
        )
PY

echo
echo "=== 3. PROVIDERS / TIMEOUTS ==="

grep -nE \
'http|https|timeout|PROBE|URL|ENDPOINT|attempt|sleep|consensus|agreed' \
"$F"

echo
echo "=== 4. ALL CALLERS ==="

grep -RIn \
--include='*.py' \
-E \
'observe_exit_ip\(|probe_exit_ip\(' \
"$R/app" \
| sort

echo
echo "=== 5. FASTPATH PERFORMANCE SAMPLE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "same-runtime-fastpath.jsonl"
)

if not p.exists():
    print("ROWS=0")
    raise SystemExit(0)

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


if times:

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
            /len(times),
            2,
        ),
    )
PY

echo
echo "=== 6. SERVICES ==="

for svc in \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-fetcher.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "========================================"
echo "FIX22K3A=PASS"
echo "MODE=EXIT-PARALLELIZATION-CONTRACT"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K3B"
echo "========================================"
