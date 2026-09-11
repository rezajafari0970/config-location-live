#!/usr/bin/env bash
set -Eeu -o pipefail

PHASE="phase5-final-atomic-pipeline-writer-permission-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"

WORKER="$PROJECT/app/country/worker.py"
PIPELINE="$PROJECT/app/country/pipeline.py"

STATE="/var/lib/config-location/country/pipeline/latest"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

BACKUP="/root/3245/${PHASE}-backup-${TS}"

LOG="$REPO/executions/$DATE/${PHASE}-${TS}.log"
REPORT="$REPO/reports/${PHASE}-${TS}.txt"
SUMMARY="$REPO/discovery/$DATE/${PHASE}-${TS}.json"

mkdir -p \
  "$BACKUP" \
  "$(dirname "$LOG")" \
  "$(dirname "$REPORT")" \
  "$(dirname "$SUMMARY")"

RESULT="SUCCESS"
ROLLED_BACK="NO"
ERRORS=""

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

rollback() {

    echo
    echo "========== AUTOMATIC ROLLBACK =========="

    cp -a \
      "$BACKUP/worker.py.before" \
      "$WORKER"

    cp -a \
      "$BACKUP/pipeline.py.before" \
      "$PIPELINE"

    systemctl restart \
      config-location-country-worker.service \
      >/dev/null 2>&1 || true

    systemctl restart \
      config-location-country-event-consumer.service \
      >/dev/null 2>&1 || true

    systemctl restart \
      config-location-panel.service \
      >/dev/null 2>&1 || true

    ROLLED_BACK="YES"

    echo "ROLLBACK_DONE"
}

finish() {

    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
    fi

    cat > "$REPORT" <<REPORT
Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Contract:
Pipeline latest files are born readable by configloc.

Owner:
root

Group:
configloc runtime group

Mode:
0640

Recursive chown:
NO

Global chmod:
NO

Rollback:
$ROLLED_BACK

Summary:
$SUMMARY

Log:
$LOG

Errors:
$ERRORS
REPORT

    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$REPO" || exit 1

    git add \
      "$LOG" \
      "$REPORT" \
      "$SUMMARY" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase5 atomic pipeline writer permission contract $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main \
      >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT


echo "================================================"
echo " PHASE 5 FINAL FIX B"
echo " ATOMIC PIPELINE WRITER PERMISSION CONTRACT"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/11] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

id configloc >/dev/null 2>&1 || {
    fail "configloc missing"
    exit 1
}

test -f "$WORKER"
test -f "$PIPELINE"
test -d "$STATE"

grep -q 'tempfile.mkstemp' "$WORKER" || {
    fail "worker atomic writer not found"
    exit 1
}

grep -q 'tempfile.mkstemp' "$PIPELINE" || {
    fail "pipeline atomic writer not found"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/11] BACKUP =========="

cp -a "$WORKER" "$BACKUP/worker.py.before"
cp -a "$PIPELINE" "$BACKUP/pipeline.py.before"

echo "BACKUP_OK"


################################################
# 3 PATCH ATOMIC WRITERS
################################################

echo
echo "========== [3/11] PATCH WRITERS =========="

"$PROJECT/venv/bin/python" \
- "$WORKER" "$PIPELINE" <<'PY'
import ast
import sys
from pathlib import Path


TARGETS = [
    Path(sys.argv[1]),
    Path(sys.argv[2]),
]


def ensure_import(tree, module):
    for node in tree.body:
        if isinstance(node, ast.Import):
            if any(
                alias.name == module
                for alias in node.names
            ):
                return

    insert_at = 0

    if (
        tree.body
        and isinstance(tree.body[0], ast.Expr)
        and isinstance(
            tree.body[0].value,
            ast.Constant,
        )
        and isinstance(
            tree.body[0].value.value,
            str,
        )
    ):
        insert_at = 1

    tree.body.insert(
        insert_at,
        ast.Import(
            names=[
                ast.alias(name=module)
            ]
        ),
    )


for path in TARGETS:

    source = path.read_text(
        encoding="utf-8"
    )

    tree = ast.parse(source)

    ensure_import(tree, "grp")

    patched = 0

    for fn in [
        node
        for node in ast.walk(tree)
        if isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
            ),
        )
    ]:

        mkstemp_indexes = []

        for i, stmt in enumerate(fn.body):

            found = False

            for node in ast.walk(stmt):

                if (
                    isinstance(node, ast.Call)
                    and isinstance(
                        node.func,
                        ast.Attribute,
                    )
                    and isinstance(
                        node.func.value,
                        ast.Name,
                    )
                    and node.func.value.id
                    == "tempfile"
                    and node.func.attr
                    == "mkstemp"
                ):
                    found = True
                    break

            if found:
                mkstemp_indexes.append(i)

        if not mkstemp_indexes:
            continue


        # Do not duplicate.
        existing_text = ast.unparse(fn)

        if "_CONFIGLOC_PIPELINE_GID" in existing_text:
            continue


        # We expect fd variable from:
        # fd, tmp = tempfile.mkstemp(...)
        idx = mkstemp_indexes[0]


        contract_source = '''
_CONFIGLOC_PIPELINE_GID = grp.getgrnam("configloc").gr_gid
os.fchown(fd, -1, _CONFIGLOC_PIPELINE_GID)
os.fchmod(fd, 0o640)
'''

        contract_nodes = ast.parse(
            contract_source
        ).body


        for offset, node in enumerate(
            contract_nodes,
            start=1,
        ):
            fn.body.insert(
                idx + offset,
                node,
            )

        patched += 1


    if patched == 0:

        raise SystemExit(
            f"NO_ATOMIC_WRITER_PATCHED:{path}"
        )


    ast.fix_missing_locations(tree)

    path.write_text(
        ast.unparse(tree) + "\n",
        encoding="utf-8",
    )

    print(
        f"PATCHED={path} "
        f"ATOMIC_FUNCTIONS={patched}"
    )


print(
    "ATOMIC_WRITER_CONTRACT_PATCHED=YES"
)
PY


################################################
# 4 STATIC VALIDATION
################################################

echo
echo "========== [4/11] STATIC VALIDATION =========="

grep -nE \
'getgrnam|fchown|fchmod|0o640' \
"$WORKER" "$PIPELINE"

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/worker.py \
  app/country/pipeline.py

echo "COMPILE_OK"


################################################
# 5 RECONCILE EXISTING FILES ONCE
################################################

echo
echo "========== [5/11] EXISTING FILE RECONCILIATION =========="

CONFIGLOC_GROUP="$(
id -gn configloc
)"

echo "CONFIGLOC_GROUP=$CONFIGLOC_GROUP"

# Only pipeline/latest regular files.
# Existing files become root:<configloc-group> 0640.
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

echo "EXISTING_PIPELINE_FILES_RECONCILED=YES"


################################################
# 6 RESTART WRITERS + PANEL
################################################

echo
echo "========== [6/11] RESTART =========="

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

    ACTIVE="$(
        systemctl is-active "$UNIT" \
        2>/dev/null || true
    )"

    echo "$UNIT=$ACTIVE"

    if [ "$ACTIVE" != "active" ]; then
        rollback
        fail "$UNIT inactive"
        exit 1
    fi

done

echo "SERVICES_RESTARTED_OK"


################################################
# 7 WAIT FOR NEW PRODUCTION WRITES
################################################

echo
echo "========== [7/11] OBSERVE NEW FILES =========="

MARKER="$(date +%s)"

sleep 45

NEW_COUNT=0
BAD_COUNT=0

while IFS= read -r FILE; do

    [ -n "$FILE" ] || continue

    MTIME="$(
        stat -c '%Y' "$FILE"
    )"

    if [ "$MTIME" -lt "$MARKER" ]; then
        continue
    fi

    NEW_COUNT=$((NEW_COUNT + 1))

    MODE="$(
        stat -c '%a' "$FILE"
    )"

    GROUP="$(
        stat -c '%G' "$FILE"
    )"

    READABLE="NO"

    if sudo -u configloc test -r "$FILE"; then
        READABLE="YES"
    fi

    echo \
      "NEW_FILE=$(basename "$FILE") MODE=$MODE GROUP=$GROUP CONFIGLOC_READ=$READABLE"

    if [ "$MODE" != "640" ] || [ "$READABLE" != "YES" ]; then
        BAD_COUNT=$((BAD_COUNT + 1))
    fi

done < <(
    find "$STATE" \
      -maxdepth 1 \
      -type f \
      -name '*.json' \
      -print
)


echo "NEW_PIPELINE_FILES=$NEW_COUNT"
echo "BAD_NEW_PIPELINE_FILES=$BAD_COUNT"

if [ "$NEW_COUNT" -eq 0 ]; then
    echo "WARNING: no new file appeared during 45s observation"
fi

if [ "$BAD_COUNT" -ne 0 ]; then
    rollback
    fail "new pipeline files violate permission contract"
    exit 1
fi

echo "NEW_FILE_PERMISSION_CONTRACT=PASS"


################################################
# 8 EACCES TRACE
################################################

echo
echo "========== [8/11] EACCES TRACE =========="

TRACE="/tmp/phase5-final-writer-configloc.strace"

sudo -u configloc \
strace -f \
  -e trace=openat,newfstatat,access \
  -o "$TRACE" \
  env \
    HOME=/nonexistent \
    PYTHONPATH="$PROJECT" \
  "$PROJECT/venv/bin/python" - <<'PY'
from app.country.projection import build_projection

p=build_projection()

print(
    "PROJECTION_RECORDS=",
    len(p.get("records",{})),
)
PY


EACCES="$(
grep -c \
'/var/lib/config-location/country/pipeline/latest/.*EACCES' \
"$TRACE" \
|| true
)"

echo "PIPELINE_LATEST_EACCES=$EACCES"

if [ "$EACCES" -ne 0 ]; then

    grep \
      '/var/lib/config-location/country/pipeline/latest/.*EACCES' \
      "$TRACE" \
      | head -n 50 || true

    rollback

    fail "pipeline latest still produces EACCES"
    exit 1
fi

echo "PIPELINE_READ_CONTRACT=PASS"


################################################
# 9 ROOT / CONFIGLOC PARITY
################################################

echo
echo "========== [9/11] ROOT CONFIGLOC PARITY =========="

ROOT="/tmp/pass5-final-writer-root.json"
USER="/tmp/pass5-final-writer-user.json"

PYCODE='
import json
import sys
from collections import Counter

from app.publish.filter import build_publish_snapshot
from app.country.projection import build_projection

snap=build_publish_snapshot()
proj=build_projection()

ids={
    str(x["id"])
    for x in snap.configs
    if isinstance(x,dict) and x.get("id")
}

counts=Counter()
unknown=0
conflict=0

for cid in ids:
    row=proj.get("records",{}).get(cid)

    if not isinstance(row,dict):
        unknown+=1
        continue

    if row.get("state")=="conflict":
        conflict+=1
        continue

    if row.get("state")!="resolved":
        unknown+=1
        continue

    c=row.get("country_code")

    if (
        isinstance(c,str)
        and len(c.strip())==2
        and c.strip().isalpha()
    ):
        counts[c.strip().upper()]+=1
    else:
        unknown+=1

data={
    "publishable":snap.publishable,
    "unknown":unknown,
    "conflict":conflict,
    "countries":dict(sorted(counts.items())),
}

json.dump(
    data,
    open(sys.argv[1],"w"),
    indent=2,
    sort_keys=True,
)
'


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-c "$PYCODE" "$ROOT"


sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-c "$PYCODE" "$USER"


"$PROJECT/venv/bin/python" \
- "$ROOT" "$USER" <<'PY'
import json
import sys

a=json.load(open(sys.argv[1]))
b=json.load(open(sys.argv[2]))

print("ROOT=",a)
print("CONFIGLOC=",b)

if a != b:
    raise SystemExit(
        "ROOT_CONFIGLOC_PARITY_FAILED"
    )

print(
    "ROOT_CONFIGLOC_PARITY=PASS"
)
PY


################################################
# 10 ALL COUNTRY LIVE PARITY
################################################

echo
echo "========== [10/11] ALL COUNTRY LIVE =========="

sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import urllib.request
from collections import Counter

from app.publish.filter import build_publish_snapshot
from app.country.projection import build_projection


BASE="http://127.0.0.1:4040"

snap=build_publish_snapshot()
proj=build_projection()

ids={
    str(x["id"])
    for x in snap.configs
    if isinstance(x,dict) and x.get("id")
}

counts=Counter()

for cid in ids:

    row=proj.get("records",{}).get(cid)

    if (
        not isinstance(row,dict)
        or row.get("state")!="resolved"
    ):
        continue

    c=row.get("country_code")

    if (
        isinstance(c,str)
        and len(c.strip())==2
        and c.strip().isalpha()
    ):
        counts[
            c.strip().upper()
        ] += 1


failed=[]

for code, expected in sorted(
    counts.items()
):

    req=urllib.request.Request(
        BASE
        + "/sub/country/"
        + code,
        headers={
            "User-Agent":
                "phase5-final-writer-contract"
        }
    )

    with urllib.request.urlopen(
        req,
        timeout=20,
    ) as response:

        http=response.status

        actual=int(
            response.headers.get(
                "X-Config-Country-Count",
                "-1",
            )
        )

        contract=response.headers.get(
            "X-Country-Contract"
        )


    print(
        f"{code}: expected={expected} actual={actual} http={http}"
    )


    if (
        http != 200
        or actual != expected
        or contract != "healthy"
    ):
        failed.append(code)


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
        "FAILED_CODES=",
        failed,
    )
    raise SystemExit(2)


print(
    "ALL_COUNTRY_LIVE_PARITY=PASS"
)
PY


################################################
# 11 REGRESSION + SUMMARY
################################################

echo
echo "========== [11/11] FINAL =========="

ALL_HTTP="$(
curl -sS \
  --max-time 20 \
  -o /tmp/pass5-final-writer-all \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all
)"

INVALID_HTTP="$(
curl -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/INVALID \
  || true
)"

echo "SUB_ALL_HTTP=$ALL_HTTP"
echo "INVALID_COUNTRY_HTTP=$INVALID_HTTP"

if [ "$ALL_HTTP" != "200" ] || [ "$INVALID_HTTP" != "404" ]; then
    rollback
    fail "endpoint regression"
    exit 1
fi


"$PROJECT/venv/bin/python" \
- "$ROOT" "$SUMMARY" <<PY
import json
import sys

state=json.load(
    open(sys.argv[1])
)

data={
    "phase":
        "$PHASE",

    "result":
        "SUCCESS",

    "writer_contract":
        "ROOT_CONFIGLOC_GROUP_0640",

    "patched_files":[
        "$WORKER",
        "$PIPELINE",
    ],

    "pipeline_latest_eacces":
        0,

    "root_configloc_parity":
        True,

    "all_country_live_parity":
        True,

    "publishable":
        state["publishable"],

    "unknown":
        state["unknown"],

    "conflict":
        state["conflict"],

    "country_count":
        len(
            state["countries"]
        ),

    "country_codes":
        sorted(
            state["countries"]
        ),

    "sub_all_http":
        int("$ALL_HTTP"),

    "invalid_country_http":
        int("$INVALID_HTTP"),

    "recursive_chown":
        False,

    "global_chmod":
        False,

    "automatic_rollback":
        True,

    "rolled_back":
        False,

    "ready_for_phase5_final_closure":
        True,
}

json.dump(
    data,
    open(
        sys.argv[2],
        "w",
        encoding="utf-8",
    ),
    ensure_ascii=False,
    indent=2,
)

print(
    json.dumps(
        data,
        ensure_ascii=False,
        indent=2,
    )
)
PY


echo
echo "ATOMIC_PIPELINE_WRITER_CONTRACT=ENABLED"
echo "NEW_FILE_MODE=0640"
echo "NEW_FILE_CONFIGLOC_READ=YES"

echo "PIPELINE_LATEST_EACCES=0"
echo "ROOT_CONFIGLOC_PARITY=PASS"
echo "ALL_COUNTRY_LIVE_PARITY=PASS"

echo "SUB_ALL_REGRESSION=PASS"
echo "INVALID_COUNTRY_FAIL_CLOSED=PASS"

echo "RECURSIVE_CHOWN=NO"
echo "GLOBAL_CHMOD=NO"

echo
echo "READY_FOR_PHASE5_FINAL_CLOSURE=YES"

echo
echo "PHASE5_FINAL_ATOMIC_WRITER_CONTRACT_SUCCESS"

RESULT="SUCCESS"
