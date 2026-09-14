#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

###############################################################################
# CONFIG LOCATION - FULL MASTER FORENSIC SNAPSHOT
#
# Goal:
#   Exact pre-next-chat project baseline.
#
# Includes:
#   - Complete /opt/config-location
#   - Complete /var/lib/config-location
#   - Complete /var/log/config-location
#   - /etc/config-location including real production configuration
#   - Config Location systemd units/drop-ins
#   - Nginx configuration
#   - Xray executable + metadata
#   - Root development/fix/install/snapshot scripts
#   - ACL / xattr / ownership / permissions
#   - system/service/network/package/python inventory
#   - DevLog
#   - backups
#   - SHA256
#   - archive integrity verification
#
# Project services are frozen during the archive phase for consistency.
###############################################################################

TS="$(date -u +%Y%m%d-%H%M%S)"

SNAP_ROOT="/root/config-location-master-snapshots"
NAME="CONFIG-LOCATION-FULL-MASTER-${TS}"

WORK="${SNAP_ROOT}/${NAME}.meta"
ARCHIVE="${SNAP_ROOT}/${NAME}.tar.gz"
SHA="${ARCHIVE}.sha256"
LIST="${SNAP_ROOT}/${NAME}.contents.txt"

mkdir -p "$SNAP_ROOT"
mkdir -p "$WORK"

###############################################################################
# SERVICE DEFINITIONS
###############################################################################

PROJECT_SERVICES=(
    config-location-panel.service
    config-location-fetcher.service
    config-location-health-adaptive.service
    config-location-country-worker.service
    config-location-country-event-consumer.service
    config-location-lifecycle-sync.service
    config-location-lifecycle-watchdog.service
)

SERVICE_STATE_FILE="$WORK/services-before.tsv"

SERVICES_STOPPED=0
FINALIZED=0

###############################################################################
# CLEANUP / RECOVERY
###############################################################################

restart_project_services() {

    echo
    echo "======================================================"
    echo " RESTORING PROJECT SERVICES"
    echo "======================================================"

    if [ "$SERVICES_STOPPED" -ne 1 ]; then
        echo "SERVICES_WERE_NOT_STOPPED=YES"
        return 0
    fi

    while IFS=$'\t' read -r SERVICE WAS_ACTIVE WAS_ENABLED
    do
        [ -n "$SERVICE" ] || continue

        if [ "$WAS_ACTIVE" = "active" ]; then
            echo "START=$SERVICE"

            systemctl start "$SERVICE" || {
                echo "WARNING=FAILED_TO_START:$SERVICE"
            }
        fi
    done <"$SERVICE_STATE_FILE"

    echo "SERVICE_RESTORE_ATTEMPT=COMPLETE"
}

cleanup() {

    RC=$?

    if [ "$FINALIZED" -ne 1 ]; then
        restart_project_services || true
    fi

    if [ "$RC" -ne 0 ]; then
        echo
        echo "======================================================"
        echo " SNAPSHOT FAILED"
        echo " EXIT_CODE=$RC"
        echo " PARTIAL_ARCHIVE=$ARCHIVE"
        echo " METADATA=$WORK"
        echo "======================================================"
    fi

    exit "$RC"
}

trap cleanup EXIT INT TERM HUP


echo "======================================================"
echo " CONFIG LOCATION - FULL MASTER SNAPSHOT"
echo "======================================================"

echo "UTC_TIMESTAMP=$TS"
echo "WORK=$WORK"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"


###############################################################################
# 1. BASIC HOST IDENTITY
###############################################################################

echo
echo "=== 1. HOST IDENTITY ==="

mkdir -p "$WORK/system"

date -u --iso-8601=seconds \
>"$WORK/system/date-utc.txt"

hostnamectl \
>"$WORK/system/hostnamectl.txt" \
2>&1 || true

uname -a \
>"$WORK/system/uname.txt"

cat /etc/os-release \
>"$WORK/system/os-release.txt"

uptime \
>"$WORK/system/uptime-before.txt"

echo "HOST_IDENTITY=PASS"


###############################################################################
# 2. DISK / MEMORY / CPU
###############################################################################

echo
echo "=== 2. RESOURCE INVENTORY ==="

lscpu \
>"$WORK/system/lscpu.txt" \
2>&1 || true

free -h \
>"$WORK/system/free-h.txt"

free -b \
>"$WORK/system/free-bytes.txt"

df -hT \
>"$WORK/system/df-hT.txt"

df -i \
>"$WORK/system/df-inodes.txt"

lsblk -f \
>"$WORK/system/lsblk.txt" \
2>&1 || true

echo "RESOURCE_INVENTORY=PASS"


###############################################################################
# 3. PROJECT SERVICE STATES BEFORE FREEZE
###############################################################################

echo
echo "=== 3. PROJECT SERVICES BEFORE ==="

: >"$SERVICE_STATE_FILE"

for SERVICE in "${PROJECT_SERVICES[@]}"
do
    ACTIVE="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    ENABLED="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"

    printf '%s\t%s\t%s\n' \
        "$SERVICE" \
        "$ACTIVE" \
        "$ENABLED" \
        >>"$SERVICE_STATE_FILE"

    echo "$SERVICE active=$ACTIVE enabled=$ENABLED"
done

systemctl list-units \
--all \
--no-pager \
>"$WORK/system/systemd-units-all.txt" \
2>&1 || true

systemctl list-unit-files \
--no-pager \
>"$WORK/system/systemd-unit-files-all.txt" \
2>&1 || true

systemctl list-timers \
--all \
--no-pager \
>"$WORK/system/systemd-timers-all.txt" \
2>&1 || true

systemctl --failed \
--no-pager \
>"$WORK/system/systemd-failed-before.txt" \
2>&1 || true

echo "SERVICE_STATE_CAPTURE=PASS"


###############################################################################
# 4. PROJECT SYSTEMD FORENSICS
###############################################################################

echo
echo "=== 4. PROJECT SYSTEMD ==="

mkdir -p "$WORK/systemd"

for SERVICE in "${PROJECT_SERVICES[@]}"
do
    systemctl cat "$SERVICE" \
    >"$WORK/systemd/${SERVICE}.cat.txt" \
    2>&1 || true

    systemctl show "$SERVICE" \
    >"$WORK/systemd/${SERVICE}.show.txt" \
    2>&1 || true

    systemctl status "$SERVICE" \
    --no-pager \
    -l \
    >"$WORK/systemd/${SERVICE}.status.txt" \
    2>&1 || true
done

find /etc/systemd/system \
-type f \
\( \
    -name 'config-location*' \
    -o -path '*/config-location*.service.d/*' \
\) \
-print \
| sort \
>"$WORK/systemd/project-unit-paths.txt" \
2>/dev/null || true

echo "SYSTEMD_FORENSICS=PASS"


###############################################################################
# 5. CURRENT PROCESSES / PORTS
###############################################################################

echo
echo "=== 5. PROCESSES / PORTS ==="

ps auxww \
>"$WORK/system/processes-before.txt"

ss -lntup \
>"$WORK/system/listening-before.txt" \
2>&1 || true

ss -s \
>"$WORK/system/socket-summary-before.txt" \
2>&1 || true

echo "PROCESS_PORT_CAPTURE=PASS"


###############################################################################
# 6. NETWORK
###############################################################################

echo
echo "=== 6. NETWORK ==="

mkdir -p "$WORK/network"

ip addr show \
>"$WORK/network/ip-address.txt" \
2>&1 || true

ip route show table all \
>"$WORK/network/ip-route-all.txt" \
2>&1 || true

ip rule show \
>"$WORK/network/ip-rule.txt" \
2>&1 || true

cat /etc/resolv.conf \
>"$WORK/network/resolv.conf.txt" \
2>&1 || true

echo "NETWORK=PASS"


###############################################################################
# 7. NGINX
###############################################################################

echo
echo "=== 7. NGINX ==="

mkdir -p "$WORK/nginx"

nginx -T \
>"$WORK/nginx/nginx-T.txt" \
2>&1 || true

nginx -t \
>"$WORK/nginx/nginx-test.txt" \
2>&1 || true

systemctl status nginx \
--no-pager \
-l \
>"$WORK/nginx/nginx-status.txt" \
2>&1 || true

echo "NGINX=PASS"


###############################################################################
# 8. PYTHON ENVIRONMENT
###############################################################################

echo
echo "=== 8. PYTHON ==="

mkdir -p "$WORK/python"

if [ -x /opt/config-location/venv/bin/python ]; then

    /opt/config-location/venv/bin/python -V \
    >"$WORK/python/python-version.txt" \
    2>&1 || true

    /opt/config-location/venv/bin/python \
    - <<'PY' \
    >"$WORK/python/python-runtime.txt"
import sys
import platform

print("executable =", sys.executable)
print("version =", sys.version)
print("prefix =", sys.prefix)
print("base_prefix =", sys.base_prefix)
print("platform =", platform.platform())
PY

fi

if [ -x /opt/config-location/venv/bin/pip ]; then

    /opt/config-location/venv/bin/pip freeze \
    >"$WORK/python/pip-freeze.txt" \
    2>&1 || true

    /opt/config-location/venv/bin/pip list \
    >"$WORK/python/pip-list.txt" \
    2>&1 || true
fi

echo "PYTHON=PASS"


###############################################################################
# 9. OS PACKAGE INVENTORY
###############################################################################

echo
echo "=== 9. PACKAGE INVENTORY ==="

dpkg-query \
-W \
-f='${binary:Package}\t${Version}\t${Architecture}\n' \
>"$WORK/system/dpkg-packages.tsv" \
2>/dev/null || true

apt-mark showmanual \
>"$WORK/system/apt-manual.txt" \
2>/dev/null || true

echo "PACKAGE_INVENTORY=PASS"


###############################################################################
# 10. XRAY
###############################################################################

echo
echo "=== 10. XRAY ==="

mkdir -p "$WORK/xray"

XRAY_BIN=""

for CANDIDATE in \
/usr/local/bin/xray \
/usr/bin/xray \
/opt/config-location/bin/xray
do
    if [ -x "$CANDIDATE" ]; then
        XRAY_BIN="$CANDIDATE"
        break
    fi
done

if [ -n "$XRAY_BIN" ]; then

    echo "$XRAY_BIN" \
    >"$WORK/xray/binary-path.txt"

    "$XRAY_BIN" version \
    >"$WORK/xray/version.txt" \
    2>&1 || true

    sha256sum "$XRAY_BIN" \
    >"$WORK/xray/binary.sha256"

    stat "$XRAY_BIN" \
    >"$WORK/xray/binary.stat.txt"

    ldd "$XRAY_BIN" \
    >"$WORK/xray/ldd.txt" \
    2>&1 || true
else
    echo "XRAY_BINARY_NOT_FOUND" \
    >"$WORK/xray/binary-path.txt"
fi

echo "XRAY=PASS"


###############################################################################
# 11. PROJECT TREE BEFORE FREEZE
###############################################################################

echo
echo "=== 11. PROJECT TREES ==="

mkdir -p "$WORK/inventory"

for ROOT in \
/opt/config-location \
/var/lib/config-location \
/var/log/config-location \
/etc/config-location
do
    SAFE="$(
        echo "$ROOT" |
        sed 's#^/##;s#/#__#g'
    )"

    if [ -e "$ROOT" ]; then

        find "$ROOT" \
        -xdev \
        -printf '%y\t%s\t%u\t%g\t%m\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n' \
        >"$WORK/inventory/${SAFE}.tree.tsv" \
        2>/dev/null || true

        du -sh "$ROOT" \
        >"$WORK/inventory/${SAFE}.size.txt" \
        2>&1 || true
    fi
done

echo "PROJECT_TREE=PASS"


###############################################################################
# 12. ACL / XATTR / PERMISSIONS
###############################################################################

echo
echo "=== 12. ACL / XATTR ==="

mkdir -p "$WORK/security"

for ROOT in \
/opt/config-location \
/var/lib/config-location \
/var/log/config-location \
/etc/config-location
do
    SAFE="$(
        echo "$ROOT" |
        sed 's#^/##;s#/#__#g'
    )"

    if [ -e "$ROOT" ]; then

        if command -v getfacl >/dev/null 2>&1; then
            getfacl \
            -R \
            -p \
            "$ROOT" \
            >"$WORK/security/${SAFE}.acl.txt" \
            2>/dev/null || true
        fi

        if command -v getfattr >/dev/null 2>&1; then
            getfattr \
            -R \
            -d \
            -m- \
            "$ROOT" \
            >"$WORK/security/${SAFE}.xattr.txt" \
            2>/dev/null || true
        fi
    fi
done

echo "ACL_XATTR=PASS"


###############################################################################
# 13. ROOT PROJECT SCRIPTS INVENTORY
###############################################################################

echo
echo "=== 13. ROOT PROJECT SCRIPTS ==="

mkdir -p "$WORK/root-scripts"

find /root \
-maxdepth 1 \
-type f \
\( \
    -name 'PANEL*.sh' \
    -o -name 'FIX*.sh' \
    -o -name 'MAKE-CONFIG*.sh' \
    -o -name '*CONFIG-LOCATION*.sh' \
    -o -name '*config-location*.sh' \
    -o -name 'install-config-location*.sh' \
\) \
-print \
| sort \
>"$WORK/root-scripts/list.txt"

while IFS= read -r F
do
    [ -f "$F" ] || continue

    cp -a \
    "$F" \
    "$WORK/root-scripts/"
done <"$WORK/root-scripts/list.txt"

echo "ROOT_PROJECT_SCRIPTS=PASS"


###############################################################################
# 14. CRON / SCHEDULED TASKS
###############################################################################

echo
echo "=== 14. CRON ==="

mkdir -p "$WORK/cron"

crontab -l \
>"$WORK/cron/root-crontab.txt" \
2>&1 || true

if id configloc >/dev/null 2>&1; then
    crontab -u configloc -l \
    >"$WORK/cron/configloc-crontab.txt" \
    2>&1 || true
fi

cp -a \
/etc/cron.d \
"$WORK/cron/etc-cron.d" \
2>/dev/null || true

echo "CRON=PASS"


###############################################################################
# 15. JOURNAL EXPORT BEFORE FREEZE
###############################################################################

echo
echo "=== 15. JOURNAL ==="

mkdir -p "$WORK/journal"

for SERVICE in "${PROJECT_SERVICES[@]}"
do
    journalctl \
    -u "$SERVICE" \
    --no-pager \
    >"$WORK/journal/${SERVICE}.full.log" \
    2>&1 || true
done

journalctl \
--since "7 days ago" \
--no-pager \
| grep -Ei \
'config-location|xray|oom|killed process|segfault|nginx|python' \
>"$WORK/journal/system-relevant-7d.log" \
2>/dev/null || true

echo "JOURNAL=PASS"


###############################################################################
# 16. PRE-FREEZE APPLICATION AUDIT
###############################################################################

echo
echo "=== 16. LIVE PROJECT COUNTS ==="

PYTHONPATH="$R" "$PY" <<'PY' \
>"$WORK/inventory/live-project-summary.txt" \
2>&1 || true
from pathlib import Path
import json
from collections import Counter

state=Path("/var/lib/config-location")

roots={
    "configs":
        state/"configs",
    "health_latest":
        state/"health-results"/"latest",
    "health_lifecycle":
        state/"health-lifecycle",
    "country_identity":
        state/"country"/"country-identity",
    "country_pipeline":
        state/"country"/"pipeline"/"latest",
    "country_results":
        state/"country"/"results"/"latest",
}

for name,root in roots.items():
    count=(
        sum(1 for _ in root.glob("*.json"))
        if root.is_dir()
        else 0
    )
    print(name, count)

try:
    from app.country.event_bus import stats
    print("event_bus", stats())
except Exception as exc:
    print(
        "event_bus_error",
        type(exc).__name__,
        str(exc),
    )

try:
    from app.publish.filter import build_publish_snapshot
    snap=build_publish_snapshot()
    print(
        "publish",
        {
            "policy_available":
                snap.policy_available,
            "total_configs":
                snap.total_configs,
            "policy_tracked":
                snap.policy_tracked,
            "publishable":
                snap.publishable,
            "suppressed":
                snap.suppressed,
            "missing_policy_record":
                snap.missing_policy_record,
        }
    )
except Exception as exc:
    print(
        "publish_error",
        type(exc).__name__,
        str(exc),
    )
PY

echo "LIVE_PROJECT_AUDIT=PASS"


###############################################################################
# 17. FREEZE PROJECT SERVICES
###############################################################################

echo
echo "======================================================"
echo "=== 17. FREEZING CONFIG LOCATION SERVICES ==="
echo "======================================================"

for SERVICE in "${PROJECT_SERVICES[@]}"
do
    ACTIVE="$(
        awk -F'\t' \
        -v S="$SERVICE" \
        '$1==S {print $2}' \
        "$SERVICE_STATE_FILE"
    )"

    if [ "$ACTIVE" = "active" ]; then

        echo "STOP=$SERVICE"

        systemctl stop "$SERVICE"
    else
        echo "SKIP_STOP=$SERVICE state=$ACTIVE"
    fi
done

SERVICES_STOPPED=1

sleep 3


###############################################################################
# 18. VERIFY FREEZE
###############################################################################

echo
echo "=== 18. FREEZE STATUS ==="

for SERVICE in "${PROJECT_SERVICES[@]}"
do
    echo "$SERVICE=$(
        systemctl is-active \
        "$SERVICE" \
        2>/dev/null || true
    )"
done

ps auxww \
>"$WORK/system/processes-frozen.txt"

ss -lntup \
>"$WORK/system/listening-frozen.txt" \
2>&1 || true

sync

echo "PROJECT_FREEZE=PASS"


###############################################################################
# 19. FINAL FILE MANIFEST WHILE FROZEN
###############################################################################

echo
echo "=== 19. FROZEN MANIFEST ==="

python3 <<PY
from pathlib import Path
import json
import os
import time

roots=[
    Path("/opt/config-location"),
    Path("/var/lib/config-location"),
    Path("/var/log/config-location"),
    Path("/etc/config-location"),
]

summary={}

for root in roots:

    files=0
    dirs=0
    symlinks=0
    bytes_total=0

    if root.exists():

        for path in root.rglob("*"):

            try:

                if path.is_symlink():
                    symlinks+=1

                elif path.is_file():
                    files+=1
                    bytes_total+=path.stat().st_size

                elif path.is_dir():
                    dirs+=1

            except FileNotFoundError:
                pass

    summary[str(root)]={
        "files":files,
        "directories":dirs,
        "symlinks":symlinks,
        "bytes":bytes_total,
    }


manifest={
    "schema":
        "config-location-full-master-v1",

    "snapshot_name":
        "$NAME",

    "created_utc":
        "$TS",

    "consistency_mode":
        "project-services-frozen",

    "contains_secrets":
        True,

    "contains":{
        "source":True,
        "project_backups":True,
        "runtime_state":True,
        "health":True,
        "country":True,
        "event_bus":True,
        "lifecycle":True,
        "publish":True,
        "panel":True,
        "xray_forensics":True,
        "devlog":True,
        "project_logs":True,
        "systemd":True,
        "nginx":True,
        "project_etc":True,
        "root_project_scripts":True,
        "python_environment":True,
        "host_inventory":True,
        "acl_metadata":True,
        "xattr_metadata":True,
    },

    "roots":
        summary,
}

Path(
    "$WORK/MASTER-MANIFEST.json"
).write_text(
    json.dumps(
        manifest,
        indent=2,
        sort_keys=True,
    )
)

print(
    json.dumps(
        manifest,
        indent=2,
        sort_keys=True,
    )
)
PY

echo "FROZEN_MANIFEST=PASS"


###############################################################################
# 20. HASH PROJECT SOURCE/STATE WHILE FROZEN
###############################################################################

echo
echo "=== 20. PROJECT FILE HASH INDEX ==="

mkdir -p "$WORK/hashes"

for ROOT in \
/opt/config-location \
/var/lib/config-location \
/var/log/config-location \
/etc/config-location
do
    SAFE="$(
        echo "$ROOT" |
        sed 's#^/##;s#/#__#g'
    )"

    if [ -e "$ROOT" ]; then

        find "$ROOT" \
        -type f \
        -print0 \
        | sort -z \
        | xargs -0 -r sha256sum \
        >"$WORK/hashes/${SAFE}.sha256"

        echo "HASHED=$ROOT"
    fi
done

echo "PROJECT_HASH_INDEX=PASS"


###############################################################################
# 21. BUILD EXACT INCLUDE LIST
###############################################################################

echo
echo "=== 21. ARCHIVE INCLUDE LIST ==="

INCLUDE_FILE="$WORK/archive-roots.txt"

: >"$INCLUDE_FILE"

add_if_exists() {
    local PATH_TO_ADD="$1"

    if [ -e "$PATH_TO_ADD" ] || [ -L "$PATH_TO_ADD" ]; then
        printf '%s\n' "${PATH_TO_ADD#/}" \
        >>"$INCLUDE_FILE"
    fi
}


add_if_exists /opt/config-location
add_if_exists /var/lib/config-location
add_if_exists /var/log/config-location
add_if_exists /etc/config-location

add_if_exists /etc/systemd/system
add_if_exists /etc/nginx

if [ -n "$XRAY_BIN" ]; then
    add_if_exists "$XRAY_BIN"
fi

# Snapshot metadata itself.
printf '%s\n' "${WORK#/}" \
>>"$INCLUDE_FILE"


# Root project scripts are included individually.
while IFS= read -r ROOT_SCRIPT
do
    [ -f "$ROOT_SCRIPT" ] || continue

    printf '%s\n' "${ROOT_SCRIPT#/}" \
    >>"$INCLUDE_FILE"
done <"$WORK/root-scripts/list.txt"


sort -u \
"$INCLUDE_FILE" \
-o "$INCLUDE_FILE"

cat "$INCLUDE_FILE"

echo "ARCHIVE_INCLUDE_LIST=PASS"


###############################################################################
# 22. CREATE ARCHIVE
###############################################################################

echo
echo "======================================================"
echo "=== 22. CREATE MASTER ARCHIVE ==="
echo "======================================================"

rm -f "$ARCHIVE" "$SHA" "$LIST"

tar \
--acls \
--xattrs \
--xattrs-include='*' \
--numeric-owner \
--sparse \
--warning=no-file-changed \
-C / \
-czf "$ARCHIVE" \
-T "$INCLUDE_FILE"

test -s "$ARCHIVE"

echo "ARCHIVE_CREATED=PASS"

ls -lh "$ARCHIVE"


###############################################################################
# 23. SHA256
###############################################################################

echo
echo "=== 23. SHA256 ==="

sha256sum "$ARCHIVE" \
>"$SHA"

cat "$SHA"

echo "SHA256_CREATED=PASS"


###############################################################################
# 24. GZIP + TAR INTEGRITY
###############################################################################

echo
echo "=== 24. ARCHIVE INTEGRITY ==="

gzip -t "$ARCHIVE"

echo "GZIP_TEST=PASS"

tar -tzf "$ARCHIVE" \
>"$LIST"

test -s "$LIST"

echo "TAR_LIST_TEST=PASS"

echo "ARCHIVE_ITEMS=$(
    wc -l <"$LIST"
)"


###############################################################################
# 25. CRITICAL PATH VERIFY
###############################################################################

echo
echo "=== 25. CRITICAL ARCHIVE CONTENT ==="

CRITICAL=(
    opt/config-location
    var/lib/config-location
    var/log/config-location
    etc/config-location
    etc/systemd/system
    etc/nginx
)

for ITEM in "${CRITICAL[@]}"
do
    if ! grep -q "^${ITEM}/" "$LIST" &&
       ! grep -q "^${ITEM}$" "$LIST"
    then
        echo "ERROR=CRITICAL_PATH_MISSING:$ITEM"
        exit 1
    fi

    echo "$ITEM=PASS"
done

echo "CRITICAL_CONTENT=PASS"


###############################################################################
# 26. VERIFY SPECIAL PROJECT COMPONENTS
###############################################################################

echo
echo "=== 26. PROJECT COMPONENT VERIFY ==="

PATTERNS=(
    'opt/config-location/app/panel/'
    'opt/config-location/app/publish/'
    'opt/config-location/app/country/'
    'opt/config-location/app/health/'
    'var/lib/config-location/configs/'
    'var/lib/config-location/health-results/'
    'var/lib/config-location/health-lifecycle/'
    'var/lib/config-location/country/'
    'var/log/config-location/chatgpt/'
)

for PATTERN in "${PATTERNS[@]}"
do
    grep -q "^${PATTERN}" "$LIST" || {
        echo "ERROR=COMPONENT_MISSING:$PATTERN"
        exit 1
    }

    echo "$PATTERN=PASS"
done

echo "PROJECT_COMPONENTS=PASS"


###############################################################################
# 27. SHA VERIFY
###############################################################################

echo
echo "=== 27. SHA VERIFY ==="

cd "$SNAP_ROOT"

sha256sum -c \
"$(basename "$SHA")"

echo "SHA_VERIFY=PASS"


###############################################################################
# 28. RESTORE PROJECT SERVICES
###############################################################################

restart_project_services

SERVICES_STOPPED=0

sleep 6


###############################################################################
# 29. POST-RESTORE HEALTH
###############################################################################

echo
echo "=== 29. SERVICES AFTER RESTORE ==="

POST_FAIL=0

for SERVICE in "${PROJECT_SERVICES[@]}"
do
    EXPECTED="$(
        awk -F'\t' \
        -v S="$SERVICE" \
        '$1==S {print $2}' \
        "$SERVICE_STATE_FILE"
    )"

    NOW="$(
        systemctl is-active \
        "$SERVICE" \
        2>/dev/null || true
    )"

    echo "$SERVICE before=$EXPECTED after=$NOW"

    if [ "$EXPECTED" = "active" ] &&
       [ "$NOW" != "active" ]
    then
        POST_FAIL=1
    fi
done

if [ "$POST_FAIL" -ne 0 ]; then
    echo "ERROR=SERVICE_RESTORE_MISMATCH"
    exit 1
fi

systemctl --failed \
--no-pager \
>"$WORK/system/systemd-failed-after.txt" \
2>&1 || true

ps auxww \
>"$WORK/system/processes-after.txt"

ss -lntup \
>"$WORK/system/listening-after.txt" \
2>&1 || true

uptime \
>"$WORK/system/uptime-after.txt"

echo "SERVICE_RESTORE=PASS"


###############################################################################
# 30. PANEL / CORE CHECK
###############################################################################

echo
echo "=== 30. PROJECT HEALTH CHECK ==="

for SERVICE in "${PROJECT_SERVICES[@]}"
do
    BEFORE="$(
        awk -F'\t' \
        -v S="$SERVICE" \
        '$1==S {print $2}' \
        "$SERVICE_STATE_FILE"
    )"

    if [ "$BEFORE" = "active" ]; then
        test "$(
            systemctl is-active "$SERVICE"
        )" = active
    fi
done

echo "PROJECT_SERVICES=PASS"


###############################################################################
# 31. FINAL SUMMARY FILE OUTSIDE ARCHIVE
###############################################################################

echo
echo "=== 31. FINAL SUMMARY ==="

SUMMARY="${SNAP_ROOT}/${NAME}.summary.txt"

{
    echo "CONFIG_LOCATION_FULL_MASTER_SNAPSHOT=PASS"
    echo "TIMESTAMP_UTC=$TS"
    echo "ARCHIVE=$ARCHIVE"
    echo "SHA256=$SHA"
    echo "CONTENTS=$LIST"
    echo "METADATA=$WORK"
    echo "ARCHIVE_SIZE_BYTES=$(stat -c '%s' "$ARCHIVE")"
    echo "ARCHIVE_ITEMS=$(wc -l <"$LIST")"
    echo "CONTAINS_SECRETS=YES"
    echo "CONSISTENCY_MODE=PROJECT_SERVICES_FROZEN"
    echo "ACL_XATTR_PRESERVED=YES"
    echo "PROJECT_SERVICES_RESTORED=YES"
} >"$SUMMARY"

cat "$SUMMARY"


###############################################################################
# 32. FINAL
###############################################################################

FINALIZED=1

trap - EXIT INT TERM HUP

echo
echo "======================================================"
echo "FULL_MASTER_SNAPSHOT=PASS"
echo "ARCHIVE_VERIFY=PASS"
echo "SHA256_VERIFY=PASS"
echo "PROJECT_SERVICES_RESTORED=PASS"
echo
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"
echo "CONTENTS=$LIST"
echo "SUMMARY=$SUMMARY"
echo "METADATA=$WORK"
echo
echo "WARNING=SNAPSHOT_CONTAINS_REAL_SECRETS"
echo "READY_FOR_NEW_CHAT=YES"
echo "======================================================"
