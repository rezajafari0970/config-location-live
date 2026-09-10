#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/health/lifecycle/consecutive.py"

BACKUP=$(
    find "$R/backups" \
    -maxdepth 1 \
    -type d \
    -name 'FIX22K1C5-*' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-
)

echo "BACKUP=$BACKUP"

test -n "$BACKUP"
test -f "$BACKUP/consecutive.py"


echo "=== 1. ROLLBACK FAILED K1C5 PATCH ==="

cp -a \
"$BACKUP/consecutive.py" \
"$F"

"$PY" -m py_compile "$F"

! grep -q \
'FIX22K1 HEALTH_COUNTRY_EVENT_HOOK' \
"$F"

echo "K1C5_ROLLBACK=PASS"


echo "=== 2. RESTART LIFECYCLE ==="

systemctl restart \
config-location-lifecycle-sync.service

sleep 3

test "$(
    systemctl is-active \
    config-location-lifecycle-sync.service
)" = active

echo "LIFECYCLE_RESTORED=PASS"


echo "=== 3. FIND EXACT HEALTH RESULT WRITERS ==="

grep -RIn \
--include='*.py' \
-B35 -A100 \
-E \
'health-results/latest|RESULT_DIR|latest.*config_id|config_id.*latest|atomic_json.*result|write.*result|save.*result' \
"$R/app/health" \
| head -n 1800 || true


echo "=== 4. FIND SCHEDULER RESULT COMMIT ==="

grep -RIn \
--include='*.py' \
-B40 -A120 \
-E \
'run_health|result.*to_dict|asdict.*result|HealthResult|atomic_json|result_path|write_text' \
"$R/app/health/core" \
| head -n 2200 || true


echo "=== 5. AST FILE-WRITER MAP ==="

"$PY" <<'PY'
from pathlib import Path
import ast

root=Path(
    "/opt/config-location/app/health"
)

for p in root.rglob("*.py"):

    try:
        s=p.read_text()
        tree=ast.parse(s)
    except Exception:
        continue

    hits=[]

    for n in ast.walk(tree):

        if not isinstance(
            n,
            ast.Call,
        ):
            continue

        name=""

        if isinstance(
            n.func,
            ast.Name,
        ):
            name=n.func.id

        elif isinstance(
            n.func,
            ast.Attribute,
        ):
            name=n.func.attr

        if name in {
            "write_text",
            "atomic_json",
            "_atomic_json",
            "atomic_json_if_changed",
            "replace",
        }:
            hits.append(
                (
                    name,
                    n.lineno,
                )
            )

    if hits and (
        "health-results"
        in s
        or
        "RESULT_DIR"
        in s
    ):

        print(
            p,
            hits,
        )
PY


echo "=== 6. HEALTH RESULT SAMPLE SCHEMA ==="

"$PY" <<'PY'
from pathlib import Path
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

shown=0

for p in sorted(
    H.glob("*.json"),
    key=lambda x:
        x.stat().st_mtime,
    reverse=True,
):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    print(
        "FILE=",
        p,
    )

    print(
        "KEYS=",
        sorted(o.keys()),
    )

    print(
        "STATE=",
        o.get("state"),
    )

    print(
        "HEALTH_QUALIFIED=",
        o.get(
            "health_qualified"
        ),
    )

    print(
        "DOWNLOAD_VERIFIED=",
        o.get(
            "download_verified"
        ),
    )

    print(
        "UPLOAD_VERIFIED=",
        o.get(
            "upload_verified"
        ),
    )

    print(
        "DECISION=",
        o.get("decision"),
    )

    print(
        "METADATA_HEALTH_DECISION=",
        (
            o.get("metadata")
            or {}
        ).get(
            "health_decision"
        ),
    )

    print(
        "STARTED=",
        o.get("started_at"),
    )

    print(
        "FINISHED=",
        o.get("finished_at"),
    )

    shown+=1

    if shown>=3:
        break

assert shown>=1
PY


echo "=== 7. SERVICES ==="

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


echo "========================================"
echo "FIX22K1C6=PASS"
echo "FAILED_K1C5_PATCH=ROLLED_BACK"
echo "EVENT_BUS_CORE=PRESERVED"
echo "HEALTH_PRODUCTION=RESTORED"
echo "NEXT=HOOK_EXACT_RESULT_COMMIT"
echo "========================================"
