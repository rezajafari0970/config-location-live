#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEST="/root/631"
PROJECT="/opt/config-location"
STAMP="$(date +%Y%m%d-%H%M%S)"

WORK="$(mktemp -d)"
ROOT="$WORK/config-location-runtime-evidence"

ARCHIVE="$DEST/CONFIG-LOCATION-RUNTIME-EVIDENCE-$STAMP.tar.zst"
SHA="$ARCHIVE.sha256"
MANIFEST="$DEST/CONFIG-LOCATION-RUNTIME-EVIDENCE-$STAMP.manifest.txt"
HASHES="$DEST/CONFIG-LOCATION-RUNTIME-EVIDENCE-$STAMP.files.sha256"
INFO="$DEST/CONFIG-LOCATION-RUNTIME-EVIDENCE-$STAMP.info.txt"

MAX_JOURNAL_LINES=200
MAX_TEXT_BYTES=32768

cleanup() {
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

sanitize_stream() {
    python3 -c '
import re,sys

text=sys.stdin.read()

patterns=[
    (
        re.compile(r"(?i)(authorization\\s*[:=]\\s*)(.*)"),
        r"\\1<REDACTED>"
    ),
    (
        re.compile(r"(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]+"),
        r"\\1<REDACTED>"
    ),
    (
        re.compile(
            r"(?im)^(\\s*(?:password|passwd|secret|token|api[_-]?key|"
            r"private[_-]?key|client[_-]?secret|cookie|session|"
            r"credential|control[_-]?token)\\s*[:=]\\s*)(.*)$"
        ),
        r"\\1<REDACTED>"
    ),
    (
        re.compile(
            r"-----BEGIN [^-]*PRIVATE KEY-----.*?"
            r"-----END [^-]*PRIVATE KEY-----",
            re.S
        ),
        "<PRIVATE_KEY_REDACTED>"
    ),
]

for rx,repl in patterns:
    text=rx.sub(repl,text)

sys.stdout.write(text)
'
}

mkdir -p "$DEST" "$ROOT"

section "[1/8] PRECHECK"

test -d "$PROJECT" || die "PROJECT_NOT_FOUND=$PROJECT"

for CMD in \
    systemctl \
    journalctl \
    python3 \
    tar \
    sha256sum \
    find \
    stat \
    ss \
    ps \
    zstd
do
    command -v "$CMD" >/dev/null 2>&1 \
        || die "MISSING_COMMAND=$CMD"
done

echo "PROJECT=$PROJECT"
echo "DEST=$DEST"
echo "MODE=READ_ONLY"
echo "PRECHECK=PASS"


section "[2/8] SYSTEMD"

mkdir -p "$ROOT/systemd/contracts"

systemctl list-unit-files \
    'config-location-*' \
    --no-pager \
    > "$ROOT/systemd/unit-files.txt" \
    2>&1 || true

systemctl list-units \
    'config-location-*' \
    --all \
    --no-pager \
    > "$ROOT/systemd/units-runtime.txt" \
    2>&1 || true

UNITS="$(
    systemctl list-unit-files \
      'config-location-*' \
      --no-legend \
      --no-pager \
      2>/dev/null \
      | awk '{print $1}' \
      | sort -u
)"

printf '%s\n' "$UNITS" \
    > "$ROOT/systemd/unit-names.txt"

while IFS= read -r UNIT; do
    [ -n "$UNIT" ] || continue

    SAFE="${UNIT//\//_}"

    {
        echo "UNIT=$UNIT"

        printf 'ACTIVE='
        systemctl is-active "$UNIT" 2>/dev/null || true

        printf 'ENABLED='
        systemctl is-enabled "$UNIT" 2>/dev/null || true

        echo
        echo "===== SHOW ====="

        systemctl show "$UNIT" \
          --property=Id \
          --property=Description \
          --property=ActiveState \
          --property=SubState \
          --property=UnitFileState \
          --property=Type \
          --property=User \
          --property=Group \
          --property=WorkingDirectory \
          --property=ExecStart \
          --property=Restart \
          --property=NRestarts \
          --property=MainPID \
          --property=EnvironmentFiles \
          --property=RuntimeDirectory \
          --property=StateDirectory \
          --property=LogsDirectory \
          --property=ReadWritePaths \
          --property=ReadOnlyPaths \
          --property=ProtectSystem \
          --property=ProtectHome \
          --property=PrivateTmp \
          --property=NoNewPrivileges \
          --no-pager \
          2>/dev/null || true

        echo
        echo "===== CAT ====="

        systemctl cat "$UNIT" \
          --no-pager \
          2>/dev/null || true

    } \
      | head -c 65536 \
      | sanitize_stream \
      > "$ROOT/systemd/contracts/$SAFE.txt"

done <<< "$UNITS"

echo "SYSTEMD=PASS"


section "[3/8] JOURNALS"

mkdir -p "$ROOT/journal"

IMPORTANT_UNITS=(
    config-location-panel.service
    config-location-fetcher.service
    config-location-health-adaptive.service
    config-location-retest.service
    config-location-country-worker.service
    config-location-country-event-consumer.service
    config-location-lifecycle-sync.service
    config-location-lifecycle-watchdog.service
    config-location-integrity-guard.service
)

for UNIT in "${IMPORTANT_UNITS[@]}"; do
    if systemctl status "$UNIT" >/dev/null 2>&1; then

        journalctl \
          -u "$UNIT" \
          -n "$MAX_JOURNAL_LINES" \
          --no-pager \
          --output=short-iso \
          2>/dev/null \
          | head -c 65536 \
          | sanitize_stream \
          > "$ROOT/journal/$UNIT.txt" \
          || true
    fi
done

echo "JOURNALS=PASS"


section "[4/8] STATE MAP"

mkdir -p "$ROOT/state"

STATE_ROOT="/var/lib/config-location"

if [ -d "$STATE_ROOT" ]; then
    {
        echo "===== FILESYSTEM MAP ====="

        find "$STATE_ROOT" \
          -mindepth 1 \
          -maxdepth 2 \
          -printf '%y %m %u:%g %s %p\n' \
          2>/dev/null \
          | sort \
          | head -n 2000

        echo
        echo "===== DIRECTORY COUNTS ====="

        find "$STATE_ROOT" \
          -mindepth 1 \
          -maxdepth 2 \
          -type d \
          2>/dev/null \
          | sort \
          | while read -r D
        do
            COUNT="$(
                find "$D" \
                  -maxdepth 1 \
                  -type f \
                  2>/dev/null \
                  | wc -l
            )"

            BYTES="$(
                du -sb "$D" \
                  2>/dev/null \
                  | awk '{print $1}'
            )"

            echo "$D files=$COUNT bytes=${BYTES:-0}"
        done
    } > "$ROOT/state/filesystem-map.txt"
fi

echo "STATE_MAP=PASS"


section "[5/8] PERMISSIONS"

mkdir -p "$ROOT/permissions"

{
    for P in \
      /opt/config-location \
      /opt/config-location/app \
      /etc/config-location \
      /var/lib/config-location \
      /var/lib/config-location/health-results \
      /var/lib/config-location/country \
      /var/lib/config-location/configs \
      /var/log/config-location
    do
        if [ -e "$P" ]; then
            stat \
              -c '%A mode=%a owner=%U group=%G uid=%u gid=%g path=%n' \
              "$P" \
              2>/dev/null || true
        fi
    done
} > "$ROOT/permissions/stat.txt"

if command -v getfacl >/dev/null 2>&1; then
    {
        for P in \
          /opt/config-location \
          /var/lib/config-location \
          /var/lib/config-location/health-results \
          /var/lib/config-location/country
        do
            if [ -e "$P" ]; then
                echo
                echo "===== $P ====="
                getfacl -p "$P" 2>/dev/null || true
            fi
        done
    } > "$ROOT/permissions/acl.txt"
fi

echo "PERMISSIONS=PASS"

