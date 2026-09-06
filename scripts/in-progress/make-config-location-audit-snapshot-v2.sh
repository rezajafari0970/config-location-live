#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# CONFIG LOCATION — AUDIT SNAPSHOT V2
#
# Includes:
#   - current production source
#   - project configuration files
#   - systemd contracts
#   - sanitized /etc/config-location configuration
#   - nginx fragments relevant to Config Location / port 4040
#   - users / groups / permissions / ACL contracts
#   - ports / process / service metadata
#
# Excludes:
#   - runtime config database/state
#   - logs/journal
#   - VPN configs
#   - secrets/tokens/passwords/private keys
#   - venv / caches / backups
###############################################################################

PROJECT="/opt/config-location"
DEST="/root/631"

STAMP="$(date +%Y%m%d-%H%M%S)"

WORK="$(mktemp -d)"
ROOT="$WORK/config-location-audit"

SOURCE="$ROOT/source"
RUNTIME="$ROOT/runtime-contracts"

ARCHIVE="$DEST/CONFIG-LOCATION-AUDIT-$STAMP.tar.zst"
ARCHIVE_SHA="$ARCHIVE.sha256"

MANIFEST="$DEST/CONFIG-LOCATION-AUDIT-$STAMP.manifest.txt"
HASHES="$DEST/CONFIG-LOCATION-AUDIT-$STAMP.files.sha256"
INFO="$DEST/CONFIG-LOCATION-AUDIT-$STAMP.info.txt"

RUNTIME_SOFT_LIMIT=102400

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

mkdir -p "$DEST" "$SOURCE" "$RUNTIME"

###############################################################################
# 1. PRECHECK
###############################################################################

section "[1/16] PRECHECK"

test -d "$PROJECT" \
    || die "PROJECT_NOT_FOUND=$PROJECT"

for CMD in \
    rsync \
    tar \
    zstd \
    sha256sum \
    systemctl \
    find \
    sed \
    awk \
    grep
do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "Installing missing dependency: $CMD"

        apt-get update -qq

        DEBIAN_FRONTEND=noninteractive \
        apt-get install -y \
          rsync \
          zstd \
          acl
        break
    fi
done

echo "PROJECT=$PROJECT"
echo "DEST=$DEST"
echo "PRECHECK=PASS"

###############################################################################
# 2. SOURCE COPY
###############################################################################

section "[2/16] CURRENT SOURCE"

rsync \
    -aH \
    \
    --exclude='.git/' \
    --exclude='.github/' \
    \
    --exclude='venv/' \
    --exclude='.venv/' \
    --exclude='env/' \
    \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='*.pyo' \
    \
    --exclude='.pytest_cache/' \
    --exclude='.mypy_cache/' \
    --exclude='.ruff_cache/' \
    --exclude='htmlcov/' \
    \
    --exclude='node_modules/' \
    \
    --exclude='backup/' \
    --exclude='backups/' \
    --exclude='snapshot/' \
    --exclude='snapshots/' \
    --exclude='archive/' \
    --exclude='archives/' \
    \
    --exclude='logs/' \
    --exclude='log/' \
    --exclude='*.log' \
    \
    --exclude='runtime/' \
    --exclude='run/' \
    --exclude='tmp/' \
    --exclude='temp/' \
    \
    --exclude='dev-observability/' \
    --exclude='evidence/' \
    --exclude='reports/' \
    \
    --exclude='*.sqlite' \
    --exclude='*.sqlite3' \
    --exclude='*.db' \
    \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='*.tar.zst' \
    --exclude='*.zip' \
    \
    --exclude='.env' \
    --exclude='.env.*' \
    --exclude='*.pem' \
    --exclude='*.key' \
    --exclude='*.p12' \
    --exclude='*.pfx' \
    --exclude='id_rsa*' \
    --exclude='id_ed25519*' \
    \
    "$PROJECT/" \
    "$SOURCE/"

echo "SOURCE_COPY=PASS"

###############################################################################
# 3. SOURCE SENSITIVE FILE CLEANUP
###############################################################################

section "[3/16] SOURCE SANITIZE"

find "$SOURCE" -type f \
    \( \
       -iname '*secret*' \
       -o -iname '*credential*' \
       -o -iname '*token*' \
       -o -iname '*.pem' \
       -o -iname '*.key' \
       -o -iname '*.p12' \
       -o -iname '*.pfx' \
       -o -iname '.env' \
       -o -iname '.env.*' \
    \) \
    -print \
    -delete \
    2>/dev/null || true

echo "SOURCE_SANITIZE=PASS"

###############################################################################
# 4. SYSTEMD UNIT FILES
###############################################################################

section "[4/16] SYSTEMD UNIT FILES"

mkdir -p "$RUNTIME/systemd/units"

while IFS= read -r UNIT_PATH; do

    [ -f "$UNIT_PATH" ] || continue

    cp -a \
      "$UNIT_PATH" \
      "$RUNTIME/systemd/units/$(basename "$UNIT_PATH")"

done < <(
    find \
      /etc/systemd/system \
      /lib/systemd/system \
      /usr/lib/systemd/system \
      -maxdepth 1 \
      -type f \
      \( \
        -name 'config-location-*.service' \
        -o -name 'config-location-*.timer' \
        -o -name 'config-location-*.path' \
        -o -name 'config-location-*.target' \
      \) \
      2>/dev/null \
      | sort -u
)

echo "SYSTEMD_FILES=$(
    find "$RUNTIME/systemd/units" \
      -type f \
      | wc -l
)"

###############################################################################
# 5. SYSTEMD EFFECTIVE CONTRACT
###############################################################################

section "[5/16] SYSTEMD EFFECTIVE CONTRACT"

SYSTEMD_REPORT="$RUNTIME/systemd/service-contracts.txt"

: > "$SYSTEMD_REPORT"

while IFS= read -r UNIT; do

    [ -n "$UNIT" ] || continue

    {
        echo
        echo "############################################################"
        echo "UNIT=$UNIT"
        echo "############################################################"

        echo
        echo "[state]"

        printf 'enabled='
        systemctl is-enabled "$UNIT" 2>/dev/null || true

        printf 'active='
        systemctl is-active "$UNIT" 2>/dev/null || true

        echo
        echo "[properties]"

        systemctl show "$UNIT" \
          --property=Type \
          --property=User \
          --property=Group \
          --property=WorkingDirectory \
          --property=ExecStart \
          --property=ExecStartPre \
          --property=ExecStartPost \
          --property=EnvironmentFiles \
          --property=Restart \
          --property=RestartSec \
          --property=TimeoutStartUSec \
          --property=TimeoutStopUSec \
          --property=RuntimeDirectory \
          --property=StateDirectory \
          --property=LogsDirectory \
          --property=ReadWritePaths \
          --property=ReadOnlyPaths \
          --property=ProtectSystem \
          --property=ProtectHome \
          --property=NoNewPrivileges \
          --no-pager \
          2>/dev/null || true

    } >> "$SYSTEMD_REPORT"

done < <(
    systemctl list-unit-files \
      'config-location-*' \
      --no-legend \
      --no-pager \
      2>/dev/null \
      | awk '{print $1}' \
      | sort -u
)

###############################################################################
# 6. SANITIZED PROJECT ETC CONFIG
###############################################################################

section "[6/16] /etc/config-location"

mkdir -p "$RUNTIME/etc-config-location"

if [ -d /etc/config-location ]; then

    find /etc/config-location \
      -type f \
      -maxdepth 4 \
      2>/dev/null \
      | sort \
      | while IFS= read -r FILE
    do
        REL="${FILE#/etc/config-location/}"

        OUT="$RUNTIME/etc-config-location/$REL"

        mkdir -p "$(dirname "$OUT")"

        # Skip obvious binary/private files.
        case "$FILE" in
            *.pem|*.key|*.p12|*.pfx|*.sqlite|*.db)
                continue
                ;;
        esac

        # Limit each individual config file.
        SIZE="$(stat -c '%s' "$FILE" 2>/dev/null || echo 0)"

        if [ "$SIZE" -gt 32768 ]; then

            {
                echo "# ORIGINAL_FILE_TOO_LARGE"
                echo "# path=$FILE"
                echo "# size=$SIZE"
                echo
                head -c 16384 "$FILE" 2>/dev/null || true
            } > "$OUT"

        else
            cp -a "$FILE" "$OUT"
        fi
    done
fi

###############################################################################
# 7. REDACT SECRETS IN TEXT CONFIGS
###############################################################################

section "[7/16] SECRET REDACTION"

python3 - "$RUNTIME" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

sensitive_key = re.compile(
    r"""
    (?ix)
    (
      password
      |passwd
      |secret
      |token
      |api[_-]?key
      |private[_-]?key
      |client[_-]?secret
      |authorization
      |bearer
      |cookie
      |session
      |credential
    )
    """
)

assign = re.compile(
    r"""
    (?ix)
    ^
    (?P<prefix>\s*
      ["']?
      [A-Za-z0-9_.-]+
      ["']?
      \s*
      (?:
        =|:
      )
      \s*
    )
    (?P<value>.+)
    $
    """
)

for path in root.rglob("*"):
    if not path.is_file():
        continue

    try:
        raw = path.read_bytes()
    except Exception:
        continue

    # Ignore binary.
    if b"\x00" in raw[:4096]:
        path.unlink(missing_ok=True)
        continue

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        try:
            text = raw.decode(
                "utf-8",
                errors="replace",
            )
        except Exception:
            continue

    output = []

    for line in text.splitlines():

        m = assign.match(line)

        if not m:
            output.append(line)
            continue

        key_part = (
            line[: line.find("=")]
            if "=" in line
            else line[: line.find(":")]
        )

        if sensitive_key.search(key_part):

            output.append(
                m.group("prefix")
                + "<REDACTED>"
            )

        else:
            output.append(line)

    try:
        path.write_text(
            "\n".join(output) + "\n",
            encoding="utf-8",
        )
    except Exception:
        pass

print("SECRET_REDACTION=PASS")
PY

###############################################################################
# 8. NGINX RELEVANT CONFIG
###############################################################################

section "[8/16] NGINX CONTRACT"

NGINX="$RUNTIME/nginx"

mkdir -p "$NGINX"

if command -v nginx >/dev/null 2>&1; then

    {
        echo "===== nginx version ====="
        nginx -v 2>&1 || true

        echo
        echo "===== matching config context ====="

        nginx -T 2>/dev/null \
          | grep -nE \
            -B8 -A20 \
            '4040|config-location|config_location' \
          || true

    } > "$NGINX/relevant-config.txt"
fi

###############################################################################
# 9. USER / GROUP / PERMISSIONS
###############################################################################

section "[9/16] USERS + PERMISSIONS"

PERM="$RUNTIME/permissions"

mkdir -p "$PERM"

{
    echo "===== PROJECT ====="
    stat \
      -c '%A %a %U:%G %n' \
      "$PROJECT" \
      "$PROJECT/app" \
      2>/dev/null || true

    echo
    echo "===== KEY DIRECTORIES ====="

    for P in \
      /opt/config-location \
      /etc/config-location \
      /var/lib/config-location \
      /var/log/config-location
    do
        if [ -e "$P" ]; then
            stat \
              -c '%A %a %U:%G %n' \
              "$P" \
              2>/dev/null || true
        fi
    done

    echo
    echo "===== SERVICE USERS ====="

    systemctl list-unit-files \
      'config-location-*.service' \
      --no-legend \
      --no-pager \
      2>/dev/null \
      | awk '{print $1}' \
      | while read -r U
    do
        USER="$(
            systemctl show "$U" \
              -p User \
              --value \
              2>/dev/null
        )"

        GROUP="$(
            systemctl show "$U" \
              -p Group \
              --value \
              2>/dev/null
        )"

        echo "$U user=${USER:-root} group=${GROUP:-default}"
    done

} > "$PERM/ownership.txt"


if command -v getfacl >/dev/null 2>&1; then

    {
        for P in \
          /opt/config-location \
          /etc/config-location \
          /var/lib/config-location
        do
            if [ -e "$P" ]; then
                echo
                echo "===== $P ====="

                getfacl \
                  -p \
                  "$P" \
                  2>/dev/null || true
            fi
        done

    } > "$PERM/acl.txt"
fi

###############################################################################
# 10. LISTEN PORTS / PROCESSES
###############################################################################

section "[10/16] NETWORK CONTRACT"

NETWORK="$RUNTIME/network"

mkdir -p "$NETWORK"

{
    echo "===== listen sockets relevant to project ====="

    ss -lntup \
      2>/dev/null \
      | grep -E \
        '(:4040\b|config-location|python)' \
      || true

    echo
    echo "===== project processes ====="

    ps \
      -eo pid,user,group,cmd \
      | grep -E \
        '[c]onfig-location|/opt/config-location' \
      || true

} > "$NETWORK/runtime.txt"

###############################################################################
# 11. TIMERS
###############################################################################

section "[11/16] TIMER CONTRACT"

{
    systemctl list-timers \
      'config-location-*' \
      --all \
      --no-pager \
      2>/dev/null \
      || true
} > "$RUNTIME/systemd/timers.txt"

###############################################################################
# 12. EXECUTION VERSIONS
###############################################################################

section "[12/16] RUNTIME VERSIONS"

VERS="$RUNTIME/versions.txt"

{
    echo "===== OS ====="
    cat /etc/os-release 2>/dev/null || true

    echo
    echo "===== Python ====="

    if [ -x "$PROJECT/venv/bin/python" ]; then
        "$PROJECT/venv/bin/python" --version 2>&1
    else
        python3 --version 2>&1 || true
    fi

    echo
    echo "===== Xray ====="

    if command -v xray >/dev/null 2>&1; then
        xray version 2>&1 | head -n 20
    fi

    echo
    echo "===== Nginx ====="

    nginx -v 2>&1 || true

    echo
    echo "===== Git ====="

    git --version 2>&1 || true

} > "$VERS"

###############################################################################
# 13. RUNTIME SIZE CONTROL
###############################################################################

section "[13/16] RUNTIME SIZE CONTROL"

CURRENT="$(
    du -sb "$RUNTIME" \
      | awk '{print $1}'
)"

echo "RUNTIME_BYTES_BEFORE=$CURRENT"
echo "TARGET_SOFT_LIMIT=$RUNTIME_SOFT_LIMIT"

# We preserve the essential files, but trim particularly verbose reports.
if [ "$CURRENT" -gt "$RUNTIME_SOFT_LIMIT" ]; then

    echo "Runtime contract is larger than target."
    echo "Trimming verbose diagnostic output..."

    for FILE in \
      "$RUNTIME/nginx/relevant-config.txt" \
      "$RUNTIME/systemd/service-contracts.txt" \
      "$RUNTIME/network/runtime.txt"
    do
        if [ -f "$FILE" ]; then

            TMP="$FILE.tmp"

            {
                head -n 300 "$FILE"
                echo
                echo "# OUTPUT_TRUNCATED_FOR_AUDIT_SNAPSHOT"
            } > "$TMP"

            mv "$TMP" "$FILE"
        fi
    done
fi

FINAL_RUNTIME="$(
    du -sb "$RUNTIME" \
      | awk '{print $1}'
)"

echo "RUNTIME_BYTES_FINAL=$FINAL_RUNTIME"

###############################################################################
# 14. PYTHON SOURCE PARSE
###############################################################################

section "[14/16] SOURCE VALIDATION"

PY_FILES="$(
    find "$SOURCE" \
      -type f \
      -name '*.py' \
      | wc -l
)"

python3 - "$SOURCE" <<'PY'
import ast
import sys
from pathlib import Path

root = Path(sys.argv[1])

failed = []

files = list(
    root.rglob("*.py")
)

for path in files:

    try:
        text = path.read_text(
            encoding="utf-8",
        )

        ast.parse(
            text,
            filename=str(path),
        )

    except Exception as exc:

        failed.append(
            (
                str(
                    path.relative_to(root)
                ),
                str(exc),
            )
        )


print(
    f"PYTHON_FILES_CHECKED={len(files)}"
)

print(
    f"PYTHON_PARSE_FAILED={len(failed)}"
)


for path, error in failed[:50]:
    print(
        f"PARSE_FAIL={path}: {error}"
    )


if failed:
    raise SystemExit(1)
PY

echo "PYTHON_PARSE=PASS"

###############################################################################
# 15. MANIFEST / HASHES / INFO
###############################################################################

section "[15/16] MANIFEST + HASHES"

(
    cd "$ROOT"

    find . \
      -type f \
      -printf '%P\n' \
      | LC_ALL=C sort

) > "$MANIFEST"


(
    cd "$ROOT"

    while IFS= read -r FILE; do
        sha256sum "$FILE"
    done < <(
        find . \
          -type f \
          -printf '%P\n' \
          | LC_ALL=C sort
    )

) > "$HASHES"


FILES="$(
    wc -l < "$MANIFEST"
)"

SOURCE_BYTES="$(
    du -sb "$SOURCE" \
      | awk '{print $1}'
)"

RUNTIME_BYTES="$(
    du -sb "$RUNTIME" \
      | awk '{print $1}'
)"

{
    echo "CONFIG_LOCATION_AUDIT_SNAPSHOT_V2"
    echo
    echo "created_at=$(date --iso-8601=seconds)"
    echo "hostname=$(hostname)"
    echo "project=$PROJECT"
    echo
    echo "files=$FILES"
    echo "python_files=$PY_FILES"
    echo "source_bytes=$SOURCE_BYTES"
    echo "runtime_contract_bytes=$RUNTIME_BYTES"
    echo
    echo "SOURCE_OF_TRUTH:"
    echo "$PROJECT"
    echo
    echo "INCLUDED:"
    echo "current project source"
    echo "project configuration"
    echo "systemd unit contracts"
    echo "sanitized /etc/config-location"
    echo "relevant nginx config"
    echo "service users/groups"
    echo "permissions/ACL"
    echo "listen/runtime contract"
    echo "timer configuration"
    echo "runtime versions"
    echo
    echo "EXCLUDED:"
    echo "venv"
    echo "git history"
    echo "backups"
    echo "logs"
    echo "journals"
    echo "runtime config database/state"
    echo "collected VPN configs"
    echo "secrets/passwords/tokens/private keys"
} > "$INFO"

cat "$INFO"

###############################################################################
# 16. ARCHIVE + VERIFY
###############################################################################

section "[16/16] ARCHIVE + VERIFY"

tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$WORK" \
    -cf - \
    config-location-audit \
  | zstd \
      -T0 \
      -10 \
      -q \
      -o "$ARCHIVE"

test -s "$ARCHIVE" \
    || die "ARCHIVE_EMPTY"

sha256sum "$ARCHIVE" > "$ARCHIVE_SHA"

zstd -t "$ARCHIVE"

tar \
    --use-compress-program=unzstd \
    -tf "$ARCHIVE" \
    >/dev/null

(
    cd "$DEST"

    sha256sum \
      -c "$(basename "$ARCHIVE_SHA")"
)

echo
echo "============================================================"
echo " CONFIG LOCATION AUDIT SNAPSHOT V2 READY"
echo "============================================================"

echo
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$ARCHIVE_SHA"
echo "MANIFEST=$MANIFEST"
echo "FILE_HASHES=$HASHES"
echo "INFO=$INFO"

echo
echo "ARCHIVE_SIZE=$(
    du -h "$ARCHIVE" \
      | awk '{print $1}'
)"

echo "SOURCE_FILES=$FILES"
echo "RUNTIME_BYTES=$RUNTIME_BYTES"

echo
echo "UPLOAD THESE FILES:"
echo "1) $ARCHIVE"
echo "2) $ARCHIVE_SHA"
echo "3) $MANIFEST"
echo "4) $HASHES"
echo "5) $INFO"

echo
echo "AUDIT_SNAPSHOT_V2=SUCCESS"
