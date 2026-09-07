#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"
ETCROOT="/etc/config-location"
STATEROOT="/var/lib/config-location"
LOGROOT="/var/log/config-location"
OUTROOT="/root/spn/root"

TS="$(date -u +%Y%m%d-%H%M%S)"
NAME="config-location-FULL-DR-${TS}"
WORK="${OUTROOT}/${NAME}"
ARCHIVE="${OUTROOT}/${NAME}.tar.gz"
SHA="${ARCHIVE}.sha256"

mkdir -p "$OUTROOT"
mkdir -p "$WORK"

SERVICES=(
  config-location-panel.service
  config-location-fetcher.service
  config-location-health-adaptive.service
  config-location-lifecycle-sync.service
  config-location-lifecycle-watchdog.service
)

declare -A WAS_ACTIVE

SERVICES_RESTORED=0
SNAPSHOT_DONE=0

echo "============================================================"
echo " CONFIG LOCATION — FULL DISASTER RECOVERY SNAPSHOT"
echo "============================================================"
echo "UTC=$TS"
echo "OUTPUT=$OUTROOT"
echo

restore_services() {

    if [ "$SERVICES_RESTORED" -eq 1 ]; then
        return 0
    fi

    echo
    echo "===== RESTORE SERVICE STATE ====="

    systemctl daemon-reload || true

    for S in "${SERVICES[@]}"
    do
        if [ "${WAS_ACTIVE[$S]:-0}" = "1" ]; then
            echo "START $S"

            systemctl start "$S" || true
        fi
    done

    for I in $(seq 1 60)
    do
        ALL_OK=1

        for S in "${SERVICES[@]}"
        do
            if [ "${WAS_ACTIVE[$S]:-0}" = "1" ]; then

                STATE="$(
                  systemctl is-active "$S" \
                  2>/dev/null || true
                )"

                if [ "$STATE" != "active" ]; then
                    ALL_OK=0
                fi
            fi
        done

        if [ "$ALL_OK" -eq 1 ]; then
            break
        fi

        sleep 1
    done

    for S in "${SERVICES[@]}"
    do
        if [ "${WAS_ACTIVE[$S]:-0}" = "1" ]; then
            STATE="$(
              systemctl is-active "$S" \
              2>/dev/null || true
            )"

            echo "$S=$STATE"
        fi
    done

    SERVICES_RESTORED=1
}

cleanup_on_exit() {

    RC=$?

    restore_services || true

    if [ "$RC" -ne 0 ]; then
        echo
        echo "============================================================"
        echo " SNAPSHOT FAILED"
        echo "============================================================"
        echo "EXIT_CODE=$RC"

        if [ -d "$WORK" ]; then
            echo "INCOMPLETE_WORK=$WORK"
        fi
    fi

    exit "$RC"
}

trap cleanup_on_exit EXIT INT TERM

echo "===== 1. PRECHECK ====="

test -d "$PROJECT"
test -x "$PROJECT/venv/bin/python"

command -v tar >/dev/null
command -v rsync >/dev/null
command -v sha256sum >/dev/null
command -v systemctl >/dev/null

df -h "$PROJECT"
df -h "$OUTROOT"

echo "[PASS] precheck"

echo
echo "===== 2. RECORD ORIGINAL SERVICE STATE ====="

for S in "${SERVICES[@]}"
do
    STATE="$(
      systemctl is-active "$S" \
      2>/dev/null || true
    )"

    echo "$S=$STATE"

    if [ "$STATE" = "active" ]; then
        WAS_ACTIVE["$S"]=1
    else
        WAS_ACTIVE["$S"]=0
    fi
done

echo "[PASS] original service state recorded"

echo
echo "===== 3. METADATA BEFORE STOP ====="

mkdir -p "$WORK/meta"

{
    echo "UTC=$(date -u +%FT%TZ)"
    echo "HOSTNAME=$(hostname)"
    echo "FQDN=$(hostname -f 2>/dev/null || true)"
    echo
    uname -a
    echo
    cat /etc/os-release || true
    echo
    uptime || true
    echo
    df -h || true
    echo
    free -h || true
} > "$WORK/meta/system.txt"

ss -lntup \
  > "$WORK/meta/listening-before.txt" \
  2>&1 || true

echo "[PASS] pre-stop metadata"

echo
echo "===== 4. STOP CONFIG LOCATION SERVICES ====="

# Stop writers first.
for S in \
  config-location-fetcher.service \
  config-location-health-adaptive.service \
  config-location-lifecycle-sync.service \
  config-location-lifecycle-watchdog.service \
  config-location-panel.service
do
    if [ "${WAS_ACTIVE[$S]:-0}" = "1" ]; then
        echo "STOP $S"
        systemctl stop "$S"
    fi
done

sleep 2

for S in "${SERVICES[@]}"
do
    STATE="$(
      systemctl is-active "$S" \
      2>/dev/null || true
    )"

    echo "$S=$STATE"

    if [ "${WAS_ACTIVE[$S]:-0}" = "1" ]; then
        test "$STATE" != "active"
    fi
done

echo "[PASS] project services quiesced"

echo
echo "===== 5. FULL /opt/config-location ====="

mkdir -p "$WORK/rootfs/opt/config-location"

rsync -aHAX \
  --numeric-ids \
  "$PROJECT/" \
  "$WORK/rootfs/opt/config-location/"

echo "[PASS] full project copied"
echo "VENV_INCLUDED=YES"

echo
echo "===== 6. FULL /etc/config-location ====="

if [ -d "$ETCROOT" ]; then
    mkdir -p "$WORK/rootfs/etc/config-location"

    rsync -aHAX \
      --numeric-ids \
      "$ETCROOT/" \
      "$WORK/rootfs/etc/config-location/"
fi

echo "[PASS] full etc config"

echo
echo "===== 7. FULL /var/lib/config-location ====="

if [ -d "$STATEROOT" ]; then
    mkdir -p "$WORK/rootfs/var/lib/config-location"

    rsync -aHAX \
      --numeric-ids \
      "$STATEROOT/" \
      "$WORK/rootfs/var/lib/config-location/"
fi

echo "[PASS] full runtime state"

echo
echo "===== 8. FULL PROJECT LOGS ====="

if [ -d "$LOGROOT" ]; then
    mkdir -p "$WORK/rootfs/var/log/config-location"

    rsync -aHAX \
      --numeric-ids \
      "$LOGROOT/" \
      "$WORK/rootfs/var/log/config-location/"
fi

echo "[PASS] project logs"

echo
echo "===== 9. SYSTEMD UNIT FILES + DROP-INS ====="

mkdir -p "$WORK/rootfs/etc/systemd/system"
mkdir -p "$WORK/systemd"

find /etc/systemd/system \
  -maxdepth 2 \
  \( \
    -name 'config-location-*' \
    -o -path '*/config-location-*.service.d/*' \
    -o -path '*/config-location-*.timer.d/*' \
  \) \
  -print \
  > "$WORK/systemd/files.txt" \
  2>/dev/null || true

while IFS= read -r F
do
    [ -e "$F" ] || continue

    REL="${F#/}"

    if [ -d "$F" ]; then
        mkdir -p "$WORK/rootfs/$REL"
    else
        mkdir -p "$WORK/rootfs/$(dirname "$REL")"
        cp -a "$F" "$WORK/rootfs/$REL"
    fi

done < "$WORK/systemd/files.txt"

for S in "${SERVICES[@]}"
do
    systemctl cat "$S" \
      > "$WORK/systemd/${S}.effective.txt" \
      2>&1 || true

    systemctl show "$S" \
      > "$WORK/systemd/${S}.show.txt" \
      2>&1 || true
done

systemctl list-unit-files \
  | grep -E '^config-location-' \
  > "$WORK/systemd/unit-files.txt" \
  || true

systemctl list-timers \
  --all \
  | grep -E 'config-location|NEXT|LEFT' \
  > "$WORK/systemd/timers.txt" \
  || true

echo "[PASS] systemd captured"

echo
echo "===== 10. ENABLED/MASKED STATE ====="

{
    for S in "${SERVICES[@]}"
    do
        echo "===== $S ====="

        systemctl is-enabled "$S" \
          2>&1 || true
    done
} > "$WORK/systemd/enabled-state.txt"

echo "[PASS] enable state"

echo
echo "===== 11. SERVICE USERS / GROUPS ====="

mkdir -p "$WORK/accounts"

USERS_FILE="$WORK/accounts/users.txt"
GROUPS_FILE="$WORK/accounts/groups.txt"

: > "$USERS_FILE"
: > "$GROUPS_FILE"

for S in "${SERVICES[@]}"
do
    USER="$(
      systemctl show "$S" \
        -p User \
        --value \
        2>/dev/null || true
    )"

    GROUP="$(
      systemctl show "$S" \
        -p Group \
        --value \
        2>/dev/null || true
    )"

    [ -n "$USER" ] || USER=root
    [ -n "$GROUP" ] || GROUP=root

    echo "$S USER=$USER GROUP=$GROUP"

    getent passwd "$USER" \
      >> "$USERS_FILE" \
      2>/dev/null || true

    getent group "$GROUP" \
      >> "$GROUPS_FILE" \
      2>/dev/null || true

    id "$USER" \
      >> "$WORK/accounts/id.txt" \
      2>/dev/null || true
done

sort -u "$USERS_FILE" -o "$USERS_FILE"
sort -u "$GROUPS_FILE" -o "$GROUPS_FILE"

echo "[PASS] accounts captured"

echo
echo "===== 12. PYTHON ENVIRONMENT ====="

"$PROJECT/venv/bin/python" \
  --version \
  > "$WORK/meta/python-version.txt" \
  2>&1

"$PROJECT/venv/bin/pip" \
  freeze \
  > "$WORK/meta/pip-freeze.txt" \
  2>&1 || true

"$PROJECT/venv/bin/pip" \
  list \
  > "$WORK/meta/pip-list.txt" \
  2>&1 || true

echo "[PASS] Python environment captured"

echo
echo "===== 13. OS PACKAGES ====="

dpkg-query \
  -W \
  -f='${binary:Package}\t${Version}\n' \
  > "$WORK/meta/dpkg-packages.txt" \
  2>/dev/null || true

apt-mark showmanual \
  > "$WORK/meta/apt-manual.txt" \
  2>/dev/null || true

echo "[PASS] OS package inventory"

echo
echo "===== 14. XRAY / REQUIRED BINARIES ====="

mkdir -p "$WORK/binaries"
mkdir -p "$WORK/rootfs"

capture_binary() {

    CMD="$1"

    PATH_FOUND="$(
      command -v "$CMD" \
      2>/dev/null || true
    )"

    echo "$CMD=$PATH_FOUND" \
      >> "$WORK/binaries/paths.txt"

    [ -n "$PATH_FOUND" ] || return 0

    REAL="$(
      readlink -f "$PATH_FOUND" \
      2>/dev/null \
      || echo "$PATH_FOUND"
    )"

    echo "$REAL=$REAL" \
      >> "$WORK/binaries/paths.txt"

    if [ -f "$REAL" ]; then

        REL="${REAL#/}"

        mkdir -p \
          "$WORK/rootfs/$(dirname "$REL")"

        cp -a \
          "$REAL" \
          "$WORK/rootfs/$REL"
    fi

    "$CMD" --version \
      >> "$WORK/binaries/versions.txt" \
      2>&1 || \
    "$CMD" version \
      >> "$WORK/binaries/versions.txt" \
      2>&1 || true
}

capture_binary xray
capture_binary python3
capture_binary curl
capture_binary rsync

echo "[PASS] binaries captured"

echo
echo "===== 15. CUSTOM EXECUTABLES ====="

mkdir -p "$WORK/rootfs/usr/local/bin"

find /usr/local/bin \
  -maxdepth 1 \
  -type f \
  \( \
    -name '*config-location*' \
    -o -name '*location*' \
    -o -name 'devrun' \
  \) \
  -print0 \
| while IFS= read -r -d '' F
do
    cp -a \
      "$F" \
      "$WORK/rootfs/usr/local/bin/"
done

if [ -d "$PROJECT/bin" ]; then
    mkdir -p "$WORK/project-bin-copy"

    rsync -aHAX \
      "$PROJECT/bin/" \
      "$WORK/project-bin-copy/"
fi

echo "[PASS] helper executables"

echo
echo "===== 16. CRON ====="

mkdir -p "$WORK/cron"

crontab -l \
  > "$WORK/cron/root-crontab.txt" \
  2>&1 || true

grep -RniE \
  'config-location|/opt/config-location' \
  /etc/cron.d \
  /etc/cron.daily \
  /etc/cron.hourly \
  /etc/cron.weekly \
  /etc/crontab \
  > "$WORK/cron/config-location-references.txt" \
  2>/dev/null || true

echo "[PASS] cron captured"

echo
echo "===== 17. NGINX / REVERSE PROXY REFERENCES ====="

mkdir -p "$WORK/nginx"

if command -v nginx >/dev/null 2>&1; then

    nginx -T \
      > "$WORK/nginx/nginx-T.txt" \
      2>&1 || true

    grep -RniE \
      '4040|config-location' \
      /etc/nginx \
      > "$WORK/nginx/config-location-references.txt" \
      2>/dev/null || true

    while IFS= read -r F
    do
        [ -f "$F" ] || continue

        REL="${F#/}"

        mkdir -p \
          "$WORK/rootfs/$(dirname "$REL")"

        cp -a \
          "$F" \
          "$WORK/rootfs/$REL"

    done < <(
      grep -RlE \
        '4040|config-location' \
        /etc/nginx \
        2>/dev/null \
        || true
    )
fi

echo "[PASS] nginx references"

echo
echo "===== 18. PERMISSIONS / OWNERSHIP ====="

{
    echo "===== PROJECT ====="

    find "$PROJECT" \
      -xdev \
      -printf '%m|%u|%g|%U|%G|%p\n'

    echo
    echo "===== ETC ====="

    if [ -d "$ETCROOT" ]; then
        find "$ETCROOT" \
          -xdev \
          -printf '%m|%u|%g|%U|%G|%p\n'
    fi

    echo
    echo "===== STATE ====="

    if [ -d "$STATEROOT" ]; then
        find "$STATEROOT" \
          -xdev \
          -printf '%m|%u|%g|%U|%G|%p\n'
    fi

} > "$WORK/meta/permissions-full.txt"

echo "[PASS] permissions captured"

echo
echo "===== 19. FILE COUNTS + SIZE ====="

{
    echo "PROJECT_FILES=$(
      find "$PROJECT" -xdev -type f | wc -l
    )"

    echo "PROJECT_SIZE=$(
      du -sh "$PROJECT" | awk '{print $1}'
    )"

    if [ -d "$ETCROOT" ]; then
        echo "ETC_FILES=$(
          find "$ETCROOT" -xdev -type f | wc -l
        )"

        echo "ETC_SIZE=$(
          du -sh "$ETCROOT" | awk '{print $1}'
        )"
    fi

    if [ -d "$STATEROOT" ]; then
        echo "STATE_FILES=$(
          find "$STATEROOT" -xdev -type f | wc -l
        )"

        echo "STATE_SIZE=$(
          du -sh "$STATEROOT" | awk '{print $1}'
        )"
    fi

} > "$WORK/meta/source-counts.txt"

cat "$WORK/meta/source-counts.txt"

echo "[PASS] source statistics"

echo
echo "===== 20. MANIFEST ====="

cat > "$WORK/MANIFEST.txt" <<MANIFEST
CONFIG LOCATION — FULL DISASTER RECOVERY SNAPSHOT

Created UTC:
$(date -u +%FT%TZ)

Primary project:
/opt/config-location

INCLUDED:
- Entire /opt/config-location
- Python venv
- Entire /etc/config-location
- Entire /var/lib/config-location
- Project logs
- systemd units and drop-ins
- enabled/disabled systemd state
- service users and groups
- Python dependency inventory
- OS package inventory
- Xray binary
- relevant custom binaries
- cron references
- Nginx references/configs
- file ownership and permissions
- runtime/service metadata

CONSISTENCY:
Config Location services were temporarily stopped before
copying project/state/configuration data.

OUTPUT:
/root/spn/root

This archive may contain sensitive production configuration.
Protect it accordingly.
MANIFEST

find "$WORK" \
  -type f \
  -printf '%P\n' \
  | sort \
  > "$WORK/FILELIST.txt"

find "$WORK" \
  -type l \
  -printf '%P -> %l\n' \
  | sort \
  > "$WORK/SYMLINKS.txt"

echo "[PASS] manifest"

echo
echo "===== 21. CREATE ARCHIVE ====="

tar \
  --numeric-owner \
  --acls \
  --xattrs \
  -C "$OUTROOT" \
  -czf "$ARCHIVE" \
  "$NAME"

echo "[PASS] archive created"

echo
echo "===== 22. SHA256 ====="

sha256sum "$ARCHIVE" \
  > "$SHA"

(
  cd "$OUTROOT"

  sha256sum -c \
    "$(basename "$SHA")"
)

echo "[PASS] SHA256 verified"

echo
echo "===== 23. TAR INTEGRITY ====="

tar -tzf "$ARCHIVE" \
  >/dev/null

echo "[PASS] tar archive readable"

echo
echo "===== 24. CRITICAL CONTENT VERIFY ====="

for ITEM in \
  "${NAME}/rootfs/opt/config-location/app" \
  "${NAME}/rootfs/opt/config-location/venv" \
  "${NAME}/rootfs/etc/config-location" \
  "${NAME}/rootfs/var/lib/config-location" \
  "${NAME}/systemd" \
  "${NAME}/accounts" \
  "${NAME}/meta"
do
    if ! tar -tzf "$ARCHIVE" \
      | grep -Fq "$ITEM"
    then
        echo "[FAIL] archive missing: $ITEM"
        exit 1
    fi

    echo "[PASS] $ITEM"
done

echo
echo "===== 25. RESTORE SERVICES ====="

restore_services

echo
echo "===== 26. PANEL READINESS ====="

if [ "${WAS_ACTIVE[config-location-panel.service]:-0}" = "1" ]; then

    READY=0

    for I in $(seq 1 60)
    do
        STATE="$(
          systemctl is-active \
            config-location-panel.service \
            2>/dev/null || true
        )"

        LISTEN=no

        if ss -lnt \
          | awk '{print $4}' \
          | grep -qE ':4040$'
        then
            LISTEN=yes
        fi

        CODE="$(
          curl \
            -sS \
            -o /dev/null \
            -w '%{http_code}' \
            --max-time 2 \
            http://127.0.0.1:4040/ \
            2>/dev/null || true
        )"

        echo \
          "READY[$I] active=$STATE listen=$LISTEN http=$CODE"

        if [ "$STATE" = active ] \
           && [ "$LISTEN" = yes ]
        then
            case "$CODE" in
                200|302|303|307|308)
                    READY=1
                    break
                    ;;
            esac
        fi

        sleep 1
    done

    test "$READY" = "1"
fi

echo "[PASS] panel readiness"

echo
echo "===== 27. FINAL SERVICE VERIFY ====="

for S in "${SERVICES[@]}"
do
    CURRENT="$(
      systemctl is-active "$S" \
      2>/dev/null || true
    )"

    echo "$S=$CURRENT"

    if [ "${WAS_ACTIVE[$S]:-0}" = "1" ]; then
        test "$CURRENT" = "active"
    fi
done

echo "[PASS] original active state restored"

echo
echo "===== 28. REMOVE WORK DIRECTORY ====="

rm -rf -- "$WORK"

test ! -e "$WORK"

echo "[PASS] temporary work directory removed"

echo
echo "===== 29. FINAL SIZE ====="

SIZE="$(
  du -h "$ARCHIVE" \
  | awk '{print $1}'
)"

echo "SIZE=$SIZE"

echo
echo "===== 30. FINAL OUTPUT ====="

ls -lh \
  "$ARCHIVE" \
  "$SHA"

SNAPSHOT_DONE=1
trap - EXIT INT TERM

echo
echo "============================================================"
echo " FULL DISASTER RECOVERY SNAPSHOT COMPLETE"
echo "============================================================"
echo "FOLDER=$OUTROOT"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"
echo "SIZE=$SIZE"
echo "PROJECT=FULL"
echo "VENV_INCLUDED=YES"
echo "ETC_CONFIG=FULL"
echo "VAR_LIB_STATE=FULL"
echo "SYSTEMD=INCLUDED"
echo "SERVICE_USERS=INCLUDED"
echo "BINARIES=INCLUDED"
echo "OS_PACKAGE_LIST=INCLUDED"
echo "PERMISSIONS=INCLUDED"
echo "NGINX_REFERENCES=INCLUDED"
echo "CRON_REFERENCES=INCLUDED"
echo "SHA256_VERIFIED=YES"
echo "ARCHIVE_INTEGRITY=PASS"
echo "SERVICES_RESTORED=YES"
echo "TEMP_DIRECTORY_REMOVED=YES"
echo "============================================================"
