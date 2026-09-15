#!/usr/bin/env bash
set -Eeu -o pipefail

PHASE="phase5-final-country-runtime-state-permission-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"

COUNTRY_ROOT="/var/lib/config-location/country"
IDENTITY_ROOT="$COUNTRY_ROOT/country-identity"
RESULT_ROOT="$COUNTRY_ROOT/results"
PIPELINE_ROOT="$COUNTRY_ROOT/pipeline/latest"

CONTRACT_SCRIPT="/usr/local/sbin/config-location-country-read-contract"
SERVICE="/etc/systemd/system/config-location-country-read-contract.service"
TIMER="/etc/systemd/system/config-location-country-read-contract.timer"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

BACKUP="/root/3245/${PHASE}-backup-${TS}"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p \
  "$BACKUP" \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR"

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

    systemctl disable --now \
      config-location-country-read-contract.timer \
      >/dev/null 2>&1 || true

    if [ -f "$BACKUP/acl.before" ]; then
        setfacl --restore="$BACKUP/acl.before" \
          >/dev/null 2>&1 || true
    fi

    if [ -f "$BACKUP/contract-script.before" ]; then
        cp -a \
          "$BACKUP/contract-script.before" \
          "$CONTRACT_SCRIPT"
    else
        rm -f "$CONTRACT_SCRIPT"
    fi

    if [ -f "$BACKUP/service.before" ]; then
        cp -a \
          "$BACKUP/service.before" \
          "$SERVICE"
    else
        rm -f "$SERVICE"
    fi

    if [ -f "$BACKUP/timer.before" ]; then
        cp -a \
          "$BACKUP/timer.before" \
          "$TIMER"
    else
        rm -f "$TIMER"
    fi

    systemctl daemon-reload || true

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
CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Contract:
configloc receives read-only access to canonical Country Projection state.

Scoped roots:
$IDENTITY_ROOT
$RESULT_ROOT
$PIPELINE_ROOT

Recursive chown:
NO

Global chmod:
NO

Country data mutation:
NONE

Config mutation:
NONE

Rollback:
$ROLLED_BACK

Summary:
$SUMMARY

Backup:
$BACKUP

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
          -m "Phase5 final Country runtime permission contract $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main \
      >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT


echo "================================================"
echo " PHASE 5 FINAL FIX"
echo " COUNTRY RUNTIME STATE PERMISSION CONTRACT"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/12] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

id configloc >/dev/null 2>&1 || {
    fail "configloc user missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "project venv missing"
    exit 1
}

for DIR in \
  "$COUNTRY_ROOT" \
  "$IDENTITY_ROOT" \
  "$PIPELINE_ROOT"
do
    test -d "$DIR" || {
        fail "missing directory: $DIR"
        exit 1
    }
done

# results may legitimately not exist yet.
mkdir -p "$RESULT_ROOT"

if ! command -v setfacl >/dev/null 2>&1; then

    echo "Installing acl package..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    apt-get install -y -qq acl
fi

command -v setfacl >/dev/null
command -v getfacl >/dev/null

echo "PRECHECK_OK"


################################################
# 2 BACKUP CURRENT ACL / UNITS
################################################

echo
echo "========== [2/12] BACKUP =========="

getfacl -R -p \
  "$IDENTITY_ROOT" \
  "$RESULT_ROOT" \
  "$PIPELINE_ROOT" \
  > "$BACKUP/acl.before"

[ ! -f "$CONTRACT_SCRIPT" ] || \
cp -a "$CONTRACT_SCRIPT" \
  "$BACKUP/contract-script.before"

[ ! -f "$SERVICE" ] || \
cp -a "$SERVICE" \
  "$BACKUP/service.before"

[ ! -f "$TIMER" ] || \
cp -a "$TIMER" \
  "$BACKUP/timer.before"

echo "ACL_BACKUP=$BACKUP/acl.before"
echo "BACKUP_OK"


################################################
# 3 /sub/all BASELINE
################################################

echo
echo "========== [3/12] PRODUCTION BASELINE =========="

SUB_BEFORE="/tmp/phase5-permission-sub-before"

HTTP_BEFORE="$(
curl \
  -sS \
  --max-time 20 \
  -o "$SUB_BEFORE" \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  || true
)"

[ "$HTTP_BEFORE" = "200" ] || {
    fail "/sub/all baseline unhealthy"
    exit 1
}

SIZE_BEFORE="$(stat -c '%s' "$SUB_BEFORE")"
SHA_BEFORE="$(sha256sum "$SUB_BEFORE" | awk '{print $1}')"

echo "SUB_ALL_HTTP_BEFORE=$HTTP_BEFORE"
echo "SUB_ALL_SIZE_BEFORE=$SIZE_BEFORE"
echo "SUB_ALL_SHA_BEFORE=$SHA_BEFORE"


################################################
# 4 INSTALL MINIMAL CONTRACT RECONCILER
################################################

echo
echo "========== [4/12] INSTALL RECONCILER =========="

cat > "$CONTRACT_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -Eeu -o pipefail

USER_NAME="configloc"

ROOTS=(
  "/var/lib/config-location/country/country-identity"
  "/var/lib/config-location/country/results"
  "/var/lib/config-location/country/pipeline/latest"
)

for ROOT in "${ROOTS[@]}"; do

    [ -d "$ROOT" ] || continue

    # Existing directories:
    # traversal only + read directory entries.
    find "$ROOT" \
      -type d \
      -exec setfacl \
        -m "u:${USER_NAME}:rx" {} +

    # Existing regular files:
    # read only, never write.
    find "$ROOT" \
      -type f \
      -exec setfacl \
        -m "u:${USER_NAME}:r--" {} +

    # Future children inherit read/traverse permission.
    setfacl \
      -m "u:${USER_NAME}:rx" \
      -m "d:u:${USER_NAME}:rx" \
      "$ROOT"

done
SH

chmod 0755 "$CONTRACT_SCRIPT"

"$CONTRACT_SCRIPT"

echo "INITIAL_PERMISSION_RECONCILIATION_OK"


################################################
# 5 VERIFY EACCES IS GONE
################################################

echo
echo "========== [5/12] CONFIGLOC READ TRACE =========="

TRACE="/tmp/phase5-permission-configloc.strace"

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
    len(
        p.get("records",{})
    ),
)
PY

EACCES_COUNT="$(
grep -c \
  '/var/lib/config-location/country/.*EACCES' \
  "$TRACE" \
  || true
)"

echo "COUNTRY_STATE_EACCES_COUNT=$EACCES_COUNT"

if [ "$EACCES_COUNT" -ne 0 ]; then

    grep \
      '/var/lib/config-location/country/.*EACCES' \
      "$TRACE" \
      | head -n 80 || true

    rollback
    fail "configloc still receives EACCES"
    exit 1
fi

echo "CONFIGLOC_COUNTRY_STATE_READ_OK"


################################################
# 6 ROOT VS CONFIGLOC PARITY
################################################

echo
echo "========== [6/12] ROOT / CONFIGLOC PARITY =========="

ROOT_JSON="/tmp/phase5-permission-root.json"
USER_JSON="/tmp/phase5-permission-configloc.json"

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$ROOT_JSON" <<'PY'
import json
import sys
from collections import Counter

from app.publish.filter import build_publish_snapshot
from app.country.projection import build_projection

snap=build_publish_snapshot()
proj=build_projection()

ids={
    str(r["id"])
    for r in snap.configs
    if isinstance(r,dict) and r.get("id")
}

counts=Counter()
unknown=0
conflict=0

for cid in ids:

    row=proj.get("records",{}).get(cid)

    if not isinstance(row,dict):
        unknown += 1
        continue

    if row.get("state")=="conflict":
        conflict += 1
        continue

    if row.get("state")!="resolved":
        unknown += 1
        continue

    code=row.get("country_code")

    if (
        isinstance(code,str)
        and len(code.strip())==2
        and code.strip().isalpha()
    ):
        counts[code.strip().upper()] += 1
    else:
        unknown += 1

data={
    "publishable":snap.publishable,
    "unknown":unknown,
    "conflict":conflict,
    "countries":dict(sorted(counts.items())),
}

json.dump(
    data,
    open(sys.argv[1],"w",encoding="utf-8"),
    ensure_ascii=False,
    indent=2,
)

print("ROOT=",data)
PY


sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$USER_JSON" <<'PY'
import json
import sys
from collections import Counter

from app.publish.filter import build_publish_snapshot
from app.country.projection import build_projection

snap=build_publish_snapshot()
proj=build_projection()

ids={
    str(r["id"])
    for r in snap.configs
    if isinstance(r,dict) and r.get("id")
}

counts=Counter()
unknown=0
conflict=0

for cid in ids:

    row=proj.get("records",{}).get(cid)

    if not isinstance(row,dict):
        unknown += 1
        continue

    if row.get("state")=="conflict":
        conflict += 1
        continue

    if row.get("state")!="resolved":
        unknown += 1
        continue

    code=row.get("country_code")

    if (
        isinstance(code,str)
        and len(code.strip())==2
        and code.strip().isalpha()
    ):
        counts[code.strip().upper()] += 1
    else:
        unknown += 1

data={
    "publishable":snap.publishable,
    "unknown":unknown,
    "conflict":conflict,
    "countries":dict(sorted(counts.items())),
}

json.dump(
    data,
    open(sys.argv[1],"w",encoding="utf-8"),
    ensure_ascii=False,
    indent=2,
)

print("CONFIGLOC=",data)
PY


"$PROJECT/venv/bin/python" \
- "$ROOT_JSON" "$USER_JSON" <<'PY'
import json
import sys

root=json.load(
    open(sys.argv[1],encoding="utf-8")
)

user=json.load(
    open(sys.argv[2],encoding="utf-8")
)

print(
    "ROOT_PUBLISHABLE=",
    root["publishable"]
)

print(
    "CONFIGLOC_PUBLISHABLE=",
    user["publishable"]
)

print(
    "ROOT_UNKNOWN=",
    root["unknown"]
)

print(
    "CONFIGLOC_UNKNOWN=",
    user["unknown"]
)

print(
    "ROOT_COUNTRIES=",
    root["countries"]
)

print(
    "CONFIGLOC_COUNTRIES=",
    user["countries"]
)

if root != user:
    raise SystemExit(
        "ROOT_CONFIGLOC_STATE_MISMATCH"
    )

print(
    "ROOT_CONFIGLOC_PARITY=PASS"
)
PY


################################################
# 7 INSTALL PERMANENT SYSTEMD CONTRACT
################################################

echo
echo "========== [7/12] PERMANENT SYSTEMD CONTRACT =========="

cat > "$SERVICE" <<EOF_SERVICE
[Unit]
Description=Config Location Country Projection Read Permission Contract

[Service]
Type=oneshot
User=root
ExecStart=$CONTRACT_SCRIPT
TimeoutStartSec=45
Nice=10
NoNewPrivileges=true
PrivateTmp=true

EOF_SERVICE


cat > "$TIMER" <<'EOF_TIMER'
[Unit]
Description=Config Location Country Projection Permission Reconciliation Timer

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true
Unit=config-location-country-read-contract.service

[Install]
WantedBy=timers.target
EOF_TIMER


systemctl daemon-reload

systemctl enable --now \
  config-location-country-read-contract.timer

systemctl start \
  config-location-country-read-contract.service

TIMER_ACTIVE="$(
systemctl is-active \
  config-location-country-read-contract.timer \
  || true
)"

echo "PERMISSION_TIMER_ACTIVE=$TIMER_ACTIVE"

[ "$TIMER_ACTIVE" = "active" ] || {
    rollback
    fail "permission contract timer inactive"
    exit 1
}

echo "PERMANENT_PERMISSION_CONTRACT=ENABLED"


################################################
# 8 RESTART PANEL
################################################

echo
echo "========== [8/12] PANEL RESTART =========="

systemctl restart \
  config-location-panel.service

sleep 4

PANEL_ACTIVE="$(
systemctl is-active \
  config-location-panel.service \
  || true
)"

echo "PANEL_ACTIVE=$PANEL_ACTIVE"

if [ "$PANEL_ACTIVE" != "active" ]; then
    rollback
    fail "panel failed after permission contract"
    exit 1
fi


################################################
# 9 ALL-COUNTRY LIVE PARITY
################################################

echo
echo "========== [9/12] LIVE ALL-COUNTRY PARITY =========="

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

publish_ids={
    str(r["id"])
    for r in snap.configs
    if isinstance(r,dict) and r.get("id")
}

counts=Counter()

for cid in publish_ids:

    row=proj.get(
        "records",
        {}
    ).get(cid)

    if (
        not isinstance(row,dict)
        or row.get("state")!="resolved"
    ):
        continue

    code=row.get("country_code")

    if (
        isinstance(code,str)
        and len(code.strip())==2
        and code.strip().isalpha()
    ):
        counts[
            code.strip().upper()
        ] += 1


failed=[]

for code,expected in sorted(
    counts.items()
):

    req=urllib.request.Request(
        BASE
        + "/sub/country/"
        + code,
        headers={
            "User-Agent":
                "phase5-permission-contract"
        },
    )

    with urllib.request.urlopen(
        req,
        timeout=20,
    ) as response:

        status=int(
            response.status
        )

        live=int(
            response.headers.get(
                "X-Config-Country-Count",
                "-1",
            )
        )

        source=response.headers.get(
            "X-Country-Source"
        )

        contract=response.headers.get(
            "X-Country-Contract"
        )


    print(
        f"{code}: "
        f"expected={expected} "
        f"live={live} "
        f"http={status}"
    )


    if (
        status != 200
        or live != expected
        or source
        != "canonical-projection-v2"
        or contract
        != "healthy"
    ):

        failed.append(
            {
                "country":
                    code,

                "expected":
                    expected,

                "live":
                    live,

                "status":
                    status,
            }
        )


print()
print(
    "DISCOVERED_COUNTRIES=",
    len(counts),
)

print(
    "FAILED_COUNTRIES=",
    len(failed),
)


if failed:

    print(
        "FAILURES=",
        failed,
    )

    raise SystemExit(2)


print(
    "ALL_COUNTRY_LIVE_PARITY=PASS"
)
PY


################################################
# 10 /sub/all + FAIL-CLOSED REGRESSION
################################################

echo
echo "========== [10/12] ENDPOINT REGRESSION =========="

SUB_AFTER="/tmp/phase5-permission-sub-after"

HTTP_AFTER="$(
curl \
  -sS \
  --max-time 20 \
  -o "$SUB_AFTER" \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  || true
)"

SIZE_AFTER="$(stat -c '%s' "$SUB_AFTER")"
SHA_AFTER="$(sha256sum "$SUB_AFTER" | awk '{print $1}')"

INVALID_HTTP="$(
curl \
  -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/INVALID \
  || true
)"


echo "SUB_ALL_HTTP_AFTER=$HTTP_AFTER"
echo "SUB_ALL_SIZE_AFTER=$SIZE_AFTER"
echo "SUB_ALL_SHA_AFTER=$SHA_AFTER"
echo "INVALID_COUNTRY_HTTP=$INVALID_HTTP"


[ "$HTTP_AFTER" = "200" ] || {
    rollback
    fail "/sub/all regression"
    exit 1
}

[ "$INVALID_HTTP" = "404" ] || {
    rollback
    fail "invalid country fail-closed regression"
    exit 1
}


MIN_SIZE="$(( SIZE_BEFORE * 70 / 100 ))"

[ "$SIZE_AFTER" -ge "$MIN_SIZE" ] || {
    rollback
    fail "/sub/all catastrophic shrink"
    exit 1
}

echo "ENDPOINT_REGRESSION=PASS"


################################################
# 11 SERVICES / CONTRACT GUARDS
################################################

echo
echo "========== [11/12] SERVICE REGRESSION =========="

for UNIT in \
  config-location-panel.service \
  config-location-country-worker.service \
  config-location-country-event-consumer.service \
  config-location-country-publish-contract.timer \
  config-location-country-read-contract.timer
do

    ACTIVE="$(
        systemctl is-active \
          "$UNIT" \
          2>/dev/null || true
    )"

    echo "$UNIT ACTIVE=$ACTIVE"

    [ "$ACTIVE" = "active" ] || {
        rollback
        fail "$UNIT inactive"
        exit 1
    }

done

echo "SERVICE_REGRESSION=PASS"


################################################
# 12 SUMMARY
################################################

echo
echo "========== [12/12] FINAL =========="

"$PROJECT/venv/bin/python" \
- "$ROOT_JSON" "$SUMMARY" <<PY
import json
import sys

state=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

summary={
    "phase":
        "$PHASE",

    "result":
        "SUCCESS",

    "contract":
        "COUNTRY_RUNTIME_STATE_READ_PERMISSION",

    "runtime_user":
        "configloc",

    "permission_model":
        "POSIX_ACL_READ_ONLY",

    "scope":[
        "$IDENTITY_ROOT",
        "$RESULT_ROOT",
        "$PIPELINE_ROOT",
    ],

    "recursive_chown":
        False,

    "global_chmod":
        False,

    "root_configloc_parity":
        True,

    "all_country_live_parity":
        True,

    "country_group_count":
        len(
            state["countries"]
        ),

    "country_codes":
        sorted(
            state["countries"]
        ),

    "unknown":
        state["unknown"],

    "conflict":
        state["conflict"],

    "publishable":
        state["publishable"],

    "permission_timer":
        "config-location-country-read-contract.timer",

    "permission_timer_active":
        True,

    "sub_all_http_before":
        "$HTTP_BEFORE",

    "sub_all_http_after":
        "$HTTP_AFTER",

    "sub_all_size_before":
        $SIZE_BEFORE,

    "sub_all_size_after":
        $SIZE_AFTER,

    "invalid_country_http":
        int("$INVALID_HTTP"),

    "country_data_write":
        False,

    "config_write":
        False,

    "automatic_rollback":
        True,

    "rolled_back":
        False,

    "ready_for_final_closure":
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
echo "COUNTRY_RUNTIME_PERMISSION_CONTRACT=ENABLED"
echo "PERMISSION_MODEL=READ_ONLY_ACL"

echo "ROOT_CONFIGLOC_PARITY=PASS"
echo "ALL_COUNTRY_LIVE_PARITY=PASS"

echo "PERMANENT_PERMISSION_TIMER=ACTIVE"

echo "SUB_ALL_REGRESSION=PASS"
echo "INVALID_COUNTRY_FAIL_CLOSED=PASS"

echo "RECURSIVE_CHOWN=NO"
echo "GLOBAL_CHMOD=NO"

echo "COUNTRY_DATA_WRITE=NO"
echo "CONFIG_WRITE=NO"

echo "AUTOMATIC_ROLLBACK=READY"
echo "ROLLED_BACK=NO"

echo
echo "READY_FOR_PHASE5_FINAL_CLOSURE=YES"

echo
echo "PHASE5_FINAL_PERMISSION_CONTRACT_SUCCESS"

RESULT="SUCCESS"
