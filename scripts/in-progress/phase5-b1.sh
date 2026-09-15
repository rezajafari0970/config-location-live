#!/usr/bin/env bash
set -Eeu -o pipefail

PROJECT="/opt/config-location"
WORKER="$PROJECT/app/country/worker.py"
PIPELINE="$PROJECT/app/country/pipeline.py"
STATE="/var/lib/config-location/country/pipeline/latest"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/3245/phase5-b1-backup-$TS"

mkdir -p "$BACKUP"

echo "========== PRECHECK =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/worker.py \
  app/country/pipeline.py

echo "BASELINE_COMPILE_OK"

cp -a "$WORKER" "$BACKUP/worker.py.before"
cp -a "$PIPELINE" "$BACKUP/pipeline.py.before"

echo "BACKUP=$BACKUP"

echo
echo "========== PATCH =========="

"$PROJECT/venv/bin/python" \
- "$WORKER" "$PIPELINE" <<'PY'
import ast
import sys
from pathlib import Path

for filename in sys.argv[1:]:
    path = Path(filename)
    source = path.read_text(encoding="utf-8")
    tree = ast.parse(source)

    patched = 0

    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue

        if "_CONFIGLOC_PIPELINE_GID" in ast.unparse(fn):
            continue

        for index, stmt in enumerate(list(fn.body)):
            if not isinstance(stmt, ast.Assign):
                continue

            value = stmt.value

            if not (
                isinstance(value, ast.Call)
                and isinstance(value.func, ast.Attribute)
                and isinstance(value.func.value, ast.Name)
                and value.func.value.id == "tempfile"
                and value.func.attr == "mkstemp"
            ):
                continue

            target = stmt.targets[0]

            if not isinstance(target, (ast.Tuple, ast.List)):
                continue

            if not target.elts or not isinstance(target.elts[0], ast.Name):
                continue

            fd_name = target.elts[0].id

            extra = ast.parse(
                f'''
_CONFIGLOC_PIPELINE_GID = __import__("grp").getgrnam("configloc").gr_gid
os.fchown({fd_name}, -1, _CONFIGLOC_PIPELINE_GID)
os.fchmod({fd_name}, 0o640)
'''
            ).body

            for offset, node in enumerate(extra, start=1):
                fn.body.insert(index + offset, node)

            patched += 1
            break

    if patched != 1:
        raise SystemExit(f"EXPECTED_ONE_WRITER:{path}:patched={patched}")

    ast.fix_missing_locations(tree)

    result = ast.unparse(tree) + "\n"

    check = ast.parse(result)

    if not (
        check.body
        and isinstance(check.body[0], ast.ImportFrom)
        and check.body[0].module == "__future__"
    ):
        raise SystemExit(f"FUTURE_IMPORT_POSITION_INVALID:{path}")

    path.write_text(result, encoding="utf-8")

    print(f"PATCHED={path}")

print("CORRECTED_ATOMIC_PATCH=YES")
PY

echo
echo "========== COMPILE PATCH =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/worker.py \
  app/country/pipeline.py

echo "PATCH_COMPILE_OK"

echo
echo "========== EXISTING FILES =========="

CONFIGLOC_GROUP="$(id -gn configloc)"

find "$STATE" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  -exec chgrp "$CONFIGLOC_GROUP" {} +

find "$STATE" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  -exec chmod 0640 {} +

echo "EXISTING_FILES_MODE_0640=YES"


echo
echo "========== RESTART SERVICES =========="

systemctl restart \
  config-location-country-worker.service

systemctl restart \
  config-location-country-event-consumer.service

systemctl restart \
  config-location-panel.service

sleep 5

for UNIT in \
  config-location-country-worker.service \
  config-location-country-event-consumer.service \
  config-location-panel.service
do
    ACTIVE="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
    echo "$UNIT=$ACTIVE"

    if [ "$ACTIVE" != "active" ]; then
        echo "ERROR: $UNIT inactive"
        exit 1
    fi
done

echo "SERVICES_OK"


echo
echo "========== OBSERVE NEW FILES =========="

MARKER="$(date +%s)"

sleep 50

NEW=0
BAD=0

while IFS= read -r FILE; do

    [ -n "$FILE" ] || continue

    MTIME="$(stat -c '%Y' "$FILE")"

    [ "$MTIME" -ge "$MARKER" ] || continue

    NEW=$((NEW+1))

    MODE="$(stat -c '%a' "$FILE")"
    OWNER="$(stat -c '%U' "$FILE")"
    GROUP="$(stat -c '%G' "$FILE")"

    READ="NO"

    if sudo -u configloc test -r "$FILE"; then
        READ="YES"
    fi

    echo "$(basename "$FILE") OWNER=$OWNER GROUP=$GROUP MODE=$MODE CONFIGLOC_READ=$READ"

    if [ "$MODE" != "640" ] || [ "$READ" != "YES" ]; then
        BAD=$((BAD+1))
    fi

done < <(
    find "$STATE" \
      -maxdepth 1 \
      -type f \
      -name '*.json' \
      -print
)

echo "NEW_FILES=$NEW"
echo "BAD_NEW_FILES=$BAD"

if [ "$BAD" -ne 0 ]; then
    echo "ERROR: new writer permission contract failed"
    exit 1
fi

echo "NEW_FILE_CONTRACT=PASS"

echo
echo "========== PIPELINE EACCES TEST =========="

TRACE="/tmp/phase5-b1-configloc.strace"

sudo -u configloc \
strace -f \
  -e trace=openat,newfstatat,access \
  -o "$TRACE" \
  env \
    HOME=/nonexistent \
    PYTHONPATH="$PROJECT" \
  "$PROJECT/venv/bin/python" - <<'PY'
from app.country.projection import build_projection

projection = build_projection()

print(
    "PROJECTION_RECORDS=",
    len(projection.get("records", {})),
)
PY

EACCES="$(
grep -c \
'/var/lib/config-location/country/pipeline/latest/.*EACCES' \
"$TRACE" \
|| true
)"

echo "PIPELINE_EACCES=$EACCES"

if [ "$EACCES" -ne 0 ]; then
    echo "ERROR: pipeline EACCES remains"

    grep \
      '/var/lib/config-location/country/pipeline/latest/.*EACCES' \
      "$TRACE" \
      | head -n 30 || true

    exit 1
fi

echo "PIPELINE_READ_CONTRACT=PASS"


echo
echo "========== ROOT / CONFIGLOC PARITY =========="

ROOT_JSON="/tmp/phase5-b1-root.json"
USER_JSON="/tmp/phase5-b1-user.json"

cat > /tmp/phase5-b1-parity.py <<'PY'
import json
import sys

from collections import Counter
from app.publish.filter import build_publish_snapshot
from app.country.projection import build_projection


snapshot = build_publish_snapshot()
projection = build_projection()

ids = {
    str(record["id"])
    for record in snapshot.configs
    if isinstance(record, dict) and record.get("id")
}

counts = Counter()
unknown = 0
conflict = 0

for cid in ids:

    row = projection.get(
        "records",
        {},
    ).get(cid)

    if not isinstance(row, dict):
        unknown += 1
        continue

    if row.get("state") == "conflict":
        conflict += 1
        continue

    if row.get("state") != "resolved":
        unknown += 1
        continue

    code = row.get("country_code")

    if (
        isinstance(code, str)
        and len(code.strip()) == 2
        and code.strip().isalpha()
    ):
        counts[code.strip().upper()] += 1
    else:
        unknown += 1


data = {
    "publishable": snapshot.publishable,
    "unknown": unknown,
    "conflict": conflict,
    "countries": dict(sorted(counts.items())),
}

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:
    json.dump(
        data,
        fh,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )
PY


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
/tmp/phase5-b1-parity.py \
"$ROOT_JSON"


sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
/tmp/phase5-b1-parity.py \
"$USER_JSON"


"$PROJECT/venv/bin/python" \
- "$ROOT_JSON" "$USER_JSON" <<'PY'
import json
import sys

root = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

user = json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)

print(
    "ROOT_PUBLISHABLE=",
    root["publishable"],
)

print(
    "CONFIGLOC_PUBLISHABLE=",
    user["publishable"],
)

print(
    "ROOT_UNKNOWN=",
    root["unknown"],
)

print(
    "CONFIGLOC_UNKNOWN=",
    user["unknown"],
)

print(
    "ROOT_COUNTRIES=",
    root["countries"],
)

print(
    "CONFIGLOC_COUNTRIES=",
    user["countries"],
)

if root != user:
    raise SystemExit(
        "ROOT_CONFIGLOC_PARITY_FAILED"
    )

print(
    "ROOT_CONFIGLOC_PARITY=PASS"
)
PY


echo
echo "========== ALL COUNTRY LIVE PARITY =========="

sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import urllib.request

from collections import Counter
from app.publish.filter import build_publish_snapshot
from app.country.projection import build_projection


BASE = "http://127.0.0.1:4040"

snapshot = build_publish_snapshot()
projection = build_projection()

ids = {
    str(record["id"])
    for record in snapshot.configs
    if isinstance(record, dict) and record.get("id")
}

counts = Counter()

for cid in ids:

    row = projection.get(
        "records",
        {},
    ).get(cid)

    if (
        not isinstance(row, dict)
        or row.get("state") != "resolved"
    ):
        continue

    code = row.get("country_code")

    if (
        isinstance(code, str)
        and len(code.strip()) == 2
        and code.strip().isalpha()
    ):
        counts[
            code.strip().upper()
        ] += 1


failed = []

for code, expected in sorted(
    counts.items()
):

    request = urllib.request.Request(
        BASE + "/sub/country/" + code,
        headers={
            "User-Agent":
                "phase5-final-b1-validation",
        },
    )

    with urllib.request.urlopen(
        request,
        timeout=20,
    ) as response:

        status = int(
            response.status
        )

        actual = int(
            response.headers.get(
                "X-Config-Country-Count",
                "-1",
            )
        )

        source = response.headers.get(
            "X-Country-Source"
        )

        contract = response.headers.get(
            "X-Country-Contract"
        )


    print(
        f"{code}: "
        f"expected={expected} "
        f"live={actual} "
        f"http={status}"
    )


    if (
        status != 200
        or actual != expected
        or source != "canonical-projection-v2"
        or contract != "healthy"
    ):
        failed.append(
            {
                "code": code,
                "expected": expected,
                "actual": actual,
                "status": status,
            }
        )


print()
print(
    "COUNTRIES_TESTED=",
    len(counts),
)

print(
    "COUNTRIES_FAILED=",
    len(failed),
)

if failed:
    print(
        "FAILED_COUNTRIES=",
        failed,
    )
    raise SystemExit(2)


print(
    "ALL_COUNTRY_LIVE_PARITY=PASS"
)
PY

echo
echo "========== ENDPOINT REGRESSION =========="

ALL_BODY="/tmp/phase5-b1-all.body"

ALL_HTTP="$(
curl \
  -sS \
  --max-time 20 \
  -o "$ALL_BODY" \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  || true
)"

INVALID_HTTP="$(
curl \
  -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/INVALID \
  || true
)"

UNKNOWN_HTTP="$(
curl \
  -sS \
  --max-time 20 \
  -o /tmp/phase5-b1-unknown.body \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/UNKNOWN \
  || true
)"

echo "SUB_ALL_HTTP=$ALL_HTTP"
echo "UNKNOWN_HTTP=$UNKNOWN_HTTP"
echo "INVALID_HTTP=$INVALID_HTTP"

[ "$ALL_HTTP" = "200" ] || {
    echo "ERROR: /sub/all regression"
    exit 1
}

[ "$UNKNOWN_HTTP" = "200" ] || {
    echo "ERROR: UNKNOWN regression"
    exit 1
}

[ "$INVALID_HTTP" = "404" ] || {
    echo "ERROR: invalid-country regression"
    exit 1
}

echo "ENDPOINT_REGRESSION=PASS"


echo
echo "========== FINAL SERVICE CHECK =========="

for UNIT in \
  config-location-country-worker.service \
  config-location-country-event-consumer.service \
  config-location-panel.service \
  config-location-country-publish-contract.timer
do

    ACTIVE="$(
        systemctl is-active \
        "$UNIT" \
        2>/dev/null || true
    )"

    echo "$UNIT=$ACTIVE"

    [ "$ACTIVE" = "active" ] || {
        echo "ERROR: $UNIT inactive"
        exit 1
    }

done

echo "SERVICE_REGRESSION=PASS"


echo
echo "========== SUMMARY =========="

SUMMARY="/tmp/phase5-b1-summary.json"

"$PROJECT/venv/bin/python" \
- "$ROOT_JSON" "$SUMMARY" <<'PY'
import json
import sys

state = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

summary = {
    "phase":
        "phase5-final-atomic-pipeline-writer-permission-contract-b1",

    "result":
        "SUCCESS",

    "atomic_writer_contract":
        "root:<configloc-group>:0640",

    "pipeline_eacces":
        0,

    "root_configloc_parity":
        True,

    "all_country_live_parity":
        True,

    "country_count":
        len(
            state["countries"]
        ),

    "country_codes":
        sorted(
            state["countries"]
        ),

    "publishable":
        state["publishable"],

    "unknown":
        state["unknown"],

    "conflict":
        state.get(
            "conflict",
            0,
        ),

    "sub_all_http":
        200,

    "unknown_http":
        200,

    "invalid_country_http":
        404,

    "ready_for_phase5_final_closure":
        True,
}

with open(
    sys.argv[2],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        summary,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )
)
PY


echo
echo "ATOMIC_WRITER_CONTRACT=PASS"
echo "NEW_FILE_MODE=0640"

echo "PIPELINE_EACCES=0"
echo "ROOT_CONFIGLOC_PARITY=PASS"

echo "ALL_DISCOVERED_COUNTRIES=SUPPORTED"
echo "ALL_COUNTRY_LIVE_PARITY=PASS"

echo "SUB_ALL_REGRESSION=PASS"
echo "UNKNOWN_ROUTE=PASS"
echo "INVALID_COUNTRY_FAIL_CLOSED=PASS"

echo "SERVICE_REGRESSION=PASS"

echo
echo "READY_FOR_PHASE5_FINAL_CLOSURE=YES"

echo
echo "PHASE5_FINAL_ATOMIC_WRITER_B1_SUCCESS"
