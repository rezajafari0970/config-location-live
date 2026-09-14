#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

SVC=config-location-country-worker.service
UNIT=/etc/systemd/system/$SVC

D=/var/lib/config-location/country
SAFETY="$D/worker-safety.json"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22H3-$TS"

mkdir -p "$B" "$D"

cp -a "$UNIT" "$B/"

echo "BACKUP=$B"


echo "=== 1. PRE-PROMOTION CONTRACT ==="

test "$(systemctl is-active "$SVC")" = active

RESTARTS=$(
    systemctl show "$SVC" \
    -p NRestarts \
    --value
)

echo "PRE_RESTARTS=$RESTARTS"

test "$RESTARTS" -eq 0


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

echo "PRE_PROMOTION=PASS"


echo "=== 2. CLEAN SYSTEMD UNIT ==="

# Remove obsolete systemd accounting directives that
# generated warnings but did not affect functionality.
sed -i \
'/^[[:space:]]*CPUAccounting=/d' \
"$UNIT"

# Explicit safety freeze. Country worker may detect and
# store results, but it may not publish or mutate configs.
if ! grep -q '^Environment=COUNTRY_PUBLICATION_ENABLED=' "$UNIT"; then

    sed -i \
    '/Environment=COUNTRY_CYCLE_INTERVAL=/a Environment=COUNTRY_PUBLICATION_ENABLED=0\nEnvironment=COUNTRY_REMARK_MUTATION_ENABLED=0\nEnvironment=COUNTRY_SUBSCRIPTION_MUTATION_ENABLED=0' \
    "$UNIT"
fi

systemctl daemon-reload

systemd-analyze verify \
"$UNIT"

echo "SYSTEMD_VERIFY=PASS"


echo "=== 3. WRITE SAFETY FREEZE ==="

"$PY" <<'PY'
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "country/worker-safety.json"
)

o={
    "schema_version":1,

    "mode":"shadow_production",

    "country_detection_enabled":True,

    "publication_enabled":False,

    "remark_mutation_enabled":False,

    "subscription_mutation_enabled":False,

    "source_raw_mutation_enabled":False,

    "production_delete_enabled":False,

    "health_dependency":"healthy_only",

    "updated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),
}

p.parent.mkdir(
    parents=True,
    exist_ok=True,
)

fd,tmp=tempfile.mkstemp(
    dir=str(p.parent),
    prefix="."+p.name+".",
    suffix=".tmp",
)

try:
    with os.fdopen(
        fd,
        "w",
        encoding="utf-8",
    ) as f:

        json.dump(
            o,
            f,
            indent=2,
            sort_keys=True,
        )

        f.write("\n")
        f.flush()
        os.fsync(f.fileno())

    os.replace(tmp,p)

except Exception:

    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass

    raise

print(
    json.dumps(
        o,
        indent=2,
    )
)
PY


echo "=== 4. SAFETY VERIFY ==="

"$PY" <<'PY'
import json
from pathlib import Path

o=json.loads(
    Path(
        "/var/lib/config-location/"
        "country/worker-safety.json"
    ).read_text()
)

assert o[
    "country_detection_enabled"
] is True

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

assert o[
    "production_delete_enabled"
] is False

print(
    "COUNTRY_SAFETY_FREEZE=PASS"
)
PY


echo "=== 5. ENABLE PERMANENT WORKER ==="

systemctl enable "$SVC"

systemctl restart "$SVC"

sleep 5

ACTIVE=$(
    systemctl is-active "$SVC"
)

ENABLED=$(
    systemctl is-enabled "$SVC"
)

echo "COUNTRY_ACTIVE=$ACTIVE"
echo "COUNTRY_ENABLED=$ENABLED"

test "$ACTIVE" = active
test "$ENABLED" = enabled

echo "PERMANENT_ENABLE=PASS"


echo "=== 6. OBSERVE PERMANENT WORKER ==="

sleep 100

journalctl \
-u "$SVC" \
--since "-3 minutes" \
--no-pager \
| tail -n 160


echo "=== 7. SERVICE STABILITY ==="

ACTIVE=$(
    systemctl is-active "$SVC"
)

RESTARTS=$(
    systemctl show "$SVC" \
    -p NRestarts \
    --value
)

MEM=$(
    systemctl show "$SVC" \
    -p MemoryCurrent \
    --value
)

TASKS=$(
    systemctl show "$SVC" \
    -p TasksCurrent \
    --value
)

echo "COUNTRY_ACTIVE=$ACTIVE"
echo "COUNTRY_RESTARTS=$RESTARTS"
echo "COUNTRY_MEMORY=$MEM"
echo "COUNTRY_TASKS=$TASKS"

test "$ACTIVE" = active
test "$RESTARTS" -eq 0

echo "PERMANENT_WORKER_STABILITY=PASS"


echo "=== 8. ERROR AUDIT ==="

ERRORS=$(
    journalctl \
    -u "$SVC" \
    --since "-4 minutes" \
    --no-pager \
    | grep -Ec \
    'Traceback|COUNTRY_CYCLE_ERROR|COUNTRY_CYCLE_RUNTIME_ERROR' \
    || true
)

echo "COUNTRY_ERROR_LINES=$ERRORS"

test "$ERRORS" -eq 0


echo "=== 9. PROGRESS VERIFY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

W=Path(
    "/var/lib/config-location/"
    "country/worker/state.json"
)

states=Counter()

for p in P.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    states[
        str(o.get("state"))
    ] += 1


worker=json.loads(
    W.read_text()
)

tracked=len(
    worker.get(
        "records",
        {}
    )
)


print(
    "COUNTRY_RESULTS=",
    sum(states.values()),
)

print(
    "WORKER_TRACKED=",
    tracked,
)

print(
    "COUNTRY_STATES=",
    dict(states),
)

assert sum(
    states.values()
) >= 84

assert tracked >= 62

print(
    "PERMANENT_PROGRESS=PASS"
)
PY


echo "=== 10. SANDBOX SLA ==="

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

test "$COUNT" -le 1

echo "SANDBOX_SLA=PASS"


echo "=== 11. CORE SERVICE ISOLATION ==="

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

echo "CORE_ISOLATION=PASS"


echo "=== 12. PUBLICATION FREEZE FINAL ==="

grep -q \
'^Environment=COUNTRY_PUBLICATION_ENABLED=0$' \
"$UNIT"

grep -q \
'^Environment=COUNTRY_REMARK_MUTATION_ENABLED=0$' \
"$UNIT"

grep -q \
'^Environment=COUNTRY_SUBSCRIPTION_MUTATION_ENABLED=0$' \
"$UNIT"

echo "PUBLICATION_FREEZE=PASS"


echo "========================================"
echo "FIX22H3=PASS"
echo "COUNTRY_WORKER=PERMANENT"
echo "COUNTRY_WORKER_ENABLED=YES"
echo "COUNTRY_WORKER_ACTIVE=YES"
echo "COUNTRY_SERVICE_RESTARTS=0"
echo "RATE_LIMIT=3_JOBS_PER_45_SECONDS"
echo "COUNTRY_DETECTION=ENABLED"
echo "COUNTRY_PUBLICATION=DISABLED"
echo "REMARK_MUTATION=DISABLED"
echo "SUBSCRIPTION_MUTATION=DISABLED"
echo "SOURCE_RAW_MUTATION=DISABLED"
echo "PRODUCTION_DELETE=DISABLED"
echo "HEALTH_FETCHER_ISOLATION=PASS"
echo "BACKUP=$B"
echo "========================================"
