#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

HOOK="$R/app/country/health_hook.py"
MET=/var/lib/config-location/country/event-bus/producer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1C13-$TS"

mkdir -p "$B"
cp -a "$HOOK" "$B/"

echo "BACKUP=$B"

echo "=== 1. ADD PRODUCER TELEMETRY ==="

"$PY" <<'PY'
from pathlib import Path

p=Path(
    "/opt/config-location/app/country/"
    "health_hook.py"
)

s=p.read_text()

if "producer-metrics.jsonl" in s:
    print("METRICS_ALREADY_PRESENT=YES")
    raise SystemExit(0)

s=s.replace(
    "from typing import Any\n",
    "from typing import Any\n"
    "from pathlib import Path\n"
    "import json\n"
    "import os\n"
    "import time\n",
)

marker=(
    "from .event_bus import enqueue\n"
)

helper=r'''

_METRICS=Path(
    "/var/lib/config-location/country/"
    "event-bus/producer-metrics.jsonl"
)


def _metric(
    *,
    config_id: str,
    generation: str,
    status: str,
    detail: dict[str,Any] | None=None,
) -> None:

    try:
        _METRICS.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        row={
            "ts_ns":time.time_ns(),
            "config_id":config_id,
            "generation":generation,
            "status":status,
        }

        if detail:
            row["detail"]=detail

        line=(
            json.dumps(
                row,
                ensure_ascii=False,
                sort_keys=True,
            )
            +"\n"
        )

        fd=os.open(
            _METRICS,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_APPEND,
            0o600,
        )

        try:
            os.write(
                fd,
                line.encode(),
            )
        finally:
            os.close(fd)

    except Exception:
        pass
'''

s=s.replace(
    marker,
    marker+helper,
    1,
)

old='''        return enqueue(
            config_id=cid,

            generation=
                generation,

            completed_at=str(
                o.get(
                    "finished_at"
                )
                or generation
            ),

            priority=0,

            metadata={
                "producer":
                    "health-result-store",

                "canonical_serializer":
                    "JsonHealthResultStore._result_to_dict",

                "state":
                    "healthy",

                "xray_started":
                    True,

                "download_verified":
                    True,

                "upload_verified":
                    True,
            },
        )
'''

new='''        response=enqueue(
            config_id=cid,

            generation=
                generation,

            completed_at=str(
                o.get(
                    "finished_at"
                )
                or generation
            ),

            priority=0,

            metadata={
                "producer":
                    "health-result-store",

                "canonical_serializer":
                    "JsonHealthResultStore._result_to_dict",

                "state":
                    "healthy",

                "xray_started":
                    True,

                "download_verified":
                    True,

                "upload_verified":
                    True,
            },
        )

        _metric(
            config_id=cid,
            generation=generation,
            status=str(
                response.get(
                    "status",
                    "unknown",
                )
            ),
            detail=response,
        )

        return response
'''

assert old in s

s=s.replace(
    old,
    new,
    1,
)

p.write_text(s)

print("TELEMETRY_PATCH=PASS")
PY

"$PY" -m py_compile "$HOOK"

echo "COMPILE=PASS"

echo "=== 2. RESET METRICS ==="

rm -f "$MET"

echo "METRICS_RESET=PASS"

echo "=== 3. RESTART ACTIVE HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH=active"

echo "=== 4. OBSERVE PRODUCER ==="

FOUND=0

for i in $(seq 1 18); do

    N=0

    if [ -f "$MET" ]; then
        N=$(wc -l <"$MET")
    fi

    echo "T=$((i*5))s PRODUCER_EVENTS=$N"

    if [ "$N" -ge 3 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1

echo "=== 5. PRODUCER STATUS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-bus/producer-metrics.jsonl"
)

rows=[]

for line in p.read_text().splitlines():

    try:
        o=json.loads(line)
    except Exception:
        continue

    rows.append(o)

c=Counter(
    str(
        o.get(
            "status",
            "unknown",
        )
    )
    for o in rows
)

print(
    "PRODUCER_ROWS=",
    len(rows),
)

print(
    "STATUS_COUNTS=",
    dict(c),
)

for o in rows[:10]:
    print(
        "SAMPLE=",
        o,
    )

assert len(rows)>=3

assert not c.get(
    "hook_error",
    0,
)

allowed={
    "enqueued",
    "suppressed_final",
    "duplicate",
}

unexpected={
    k:v
    for k,v in c.items()
    if k not in allowed
}

print(
    "UNEXPECTED=",
    unexpected,
)

assert not unexpected

print(
    "PRODUCER_EXECUTION=PASS"
)
PY

echo "=== 6. QUEUE + FINAL CORRELATION ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

M=Path(
    "/var/lib/config-location/country/"
    "event-bus/producer-metrics.jsonl"
)

Q=Path(
    "/var/lib/config-location/country/"
    "event-bus/pending"
)

C=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

rows=[
    json.loads(x)
    for x in M.read_text().splitlines()
    if x.strip()
]

stats=Counter()

for o in rows:

    cid=o["config_id"]
    status=o["status"]

    if status=="enqueued":
        stats[
            "enqueued"
        ]+=1

    elif status=="suppressed_final":

        cp=C/f"{cid}.json"

        assert cp.exists()

        co=json.loads(
            cp.read_text()
        )

        assert str(
            co.get(
                "state",
                "",
            )
        ).lower() in {
            "confirmed",
            "confirmed_stable",
            "confirmed_rotating_ip",
        }

        stats[
            "suppressed_final_verified"
        ]+=1


print(
    "CORRELATION=",
    dict(stats),
)

print(
    "QUEUE_PENDING=",
    len(
        list(
            Q.glob("*.json")
        )
    ),
)

print(
    "CORRELATION=PASS"
)
PY

echo "=== 7. SERVICES ==="

for svc in \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-fetcher.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo "========================================"
echo "FIX22K1C13=PASS"
echo "HEALTH_EVENT_PRODUCER_EXECUTION=PROVEN"
echo "PRODUCER_TELEMETRY=ACTIVE"
echo "HOOK_ERROR=0"
echo "========================================"
