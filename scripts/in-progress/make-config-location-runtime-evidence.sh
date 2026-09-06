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
          | sed -n '1,2000p'

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


###############################################################################
# [6/8] SANITIZED STATE SAMPLES
###############################################################################

section "[6/8] SANITIZED STATE SAMPLES"

SAMPLES="$ROOT/samples"
mkdir -p "$SAMPLES"

sanitize_json_file() {
    local SRC="$1"
    local OUT="$2"

    mkdir -p "$(dirname "$OUT")"

    python3 - "$SRC" "$OUT" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])

SECRET_KEYS = {
    "password",
    "passwd",
    "secret",
    "token",
    "api_key",
    "apikey",
    "private_key",
    "privatekey",
    "client_secret",
    "authorization",
    "cookie",
    "session",
    "credential",
    "control_token",
}

CONFIG_KEYS = {
    "raw",
    "canonical",
    "config",
    "configuration",
    "payload",
    "content",
    "subscription_content",
    "source_raw",
}

KEY_MATERIAL = {
    "publickey",
    "public_key",
    "privatekey",
    "private_key",
    "secretkey",
    "secret_key",
    "presharedkey",
    "pre_shared_key",
    "pbk",
    "psk",
}

PROXY_PREFIXES = (
    "vless://",
    "vmess://",
    "trojan://",
    "ss://",
    "socks://",
    "socks5://",
    "wireguard://",
    "wg://",
    "hysteria://",
    "hysteria2://",
    "hy2://",
    "tuic://",
)

def clean(value, key=None, depth=0):
    if depth > 20:
        return "<MAX_DEPTH>"

    lk = str(key or "").lower()

    if lk in SECRET_KEYS:
        return "<REDACTED>"

    if lk in CONFIG_KEYS:
        if isinstance(value, (str, bytes)):
            return f"<CONFIG_CONTENT_REDACTED len={len(value)}>"
        return "<CONFIG_CONTENT_REDACTED>"

    if lk in KEY_MATERIAL:
        return "<KEY_MATERIAL_REDACTED>"

    if isinstance(value, dict):
        result = {}
        for k, v in value.items():
            result[str(k)] = clean(v, k, depth + 1)
        return result

    if isinstance(value, list):
        result = [
            clean(v, key, depth + 1)
            for v in value[:50]
        ]

        if len(value) > 50:
            result.append(
                f"<TRUNCATED {len(value) - 50} ITEMS>"
            )

        return result

    if isinstance(value, str):
        low = value.strip().lower()

        if low.startswith(PROXY_PREFIXES):
            return f"<PROXY_URI_REDACTED len={len(value)}>"

        if "private key-----" in low:
            return "<PRIVATE_KEY_REDACTED>"

        if len(value) > 2048:
            return (
                value[:512]
                + f"...<TRUNCATED len={len(value)}>"
            )

    return value

try:
    raw = src.read_bytes()
except Exception as exc:
    out.write_text(
        json.dumps(
            {
                "source": str(src),
                "read_error": str(exc),
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    raise SystemExit(0)

if len(raw) > 1024 * 1024:
    raw = raw[:1024 * 1024]

try:
    data = json.loads(
        raw.decode(
            "utf-8",
            errors="strict",
        )
    )
except Exception:
    out.write_text(
        json.dumps(
            {
                "source": str(src),
                "status": "not_valid_json",
                "size_bytes": (
                    src.stat().st_size
                    if src.exists()
                    else None
                ),
                "content": "<NOT_COLLECTED>",
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    raise SystemExit(0)

cleaned = clean(data)

text = json.dumps(
    cleaned,
    ensure_ascii=False,
    indent=2,
    sort_keys=True,
)

encoded = text.encode("utf-8")

if len(encoded) > 24576:
    summary = {
        "source": str(src),
        "status": "sanitized_but_too_large",
        "original_size_bytes": src.stat().st_size,
        "sanitized_size_bytes": len(encoded),
        "top_level_type": type(data).__name__,
    }

    if isinstance(data, dict):
        summary["top_level_keys"] = [
            str(k)
            for k in list(data)[:100]
        ]

    if isinstance(data, list):
        summary["list_length"] = len(data)

    text = json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )

out.write_text(
    text + "\n",
    encoding="utf-8",
)
PY
}

CANDIDATES=(
    /var/lib/config-location/fetcher-status.json
    /var/lib/config-location/health-scheduler/state.json
    /var/lib/config-location/integrity/xray-runtime/capability-matrix.json
    /var/lib/config-location/publish/status.json
    /var/lib/config-location/country/state.json
)

for SRC in "${CANDIDATES[@]}"; do
    if [ -f "$SRC" ]; then
        NAME="$(
            echo "${SRC#/var/lib/config-location/}" \
              | tr '/' '_'
        )"

        echo "SANITIZE=$SRC"

        sanitize_json_file \
          "$SRC" \
          "$SAMPLES/$NAME"
    fi
done

###############################################################################
# Representative latest Health result
###############################################################################

HEALTH_DIR="/var/lib/config-location/health-results/latest"

if [ -d "$HEALTH_DIR" ]; then
    HEALTH_SAMPLE="$(
        find "$HEALTH_DIR" \
          -maxdepth 1 \
          -type f \
          -name '*.json' \
          -printf '%T@ %p\n' \
          2>/dev/null \
          | sort -nr \
          | sed -n '1p' \
          | cut -d' ' -f2-
    )"

    if [ -n "${HEALTH_SAMPLE:-}" ] && [ -f "$HEALTH_SAMPLE" ]; then
        sanitize_json_file \
          "$HEALTH_SAMPLE" \
          "$SAMPLES/health-latest-sample.json"
    fi
fi

###############################################################################
# Representative Country identity
###############################################################################

COUNTRY_ID_DIR="/var/lib/config-location/country/country-identity"

if [ -d "$COUNTRY_ID_DIR" ]; then
    COUNTRY_SAMPLE="$(
        find "$COUNTRY_ID_DIR" \
          -maxdepth 1 \
          -type f \
          -name '*.json' \
          -printf '%T@ %p\n' \
          2>/dev/null \
          | sort -nr \
          | sed -n '1p' \
          | cut -d' ' -f2-
    )"

    if [ -n "${COUNTRY_SAMPLE:-}" ] && [ -f "$COUNTRY_SAMPLE" ]; then
        sanitize_json_file \
          "$COUNTRY_SAMPLE" \
          "$SAMPLES/country-identity-sample.json"
    fi
fi

echo "SANITIZED_SAMPLES=PASS"


###############################################################################
# [7/8] RUNTIME / NETWORK / TIMERS / HTTP
###############################################################################

section "[7/8] RUNTIME CONTRACT"

mkdir -p "$ROOT/runtime"

###############################################################################
# Ports + processes
###############################################################################

{
    echo "===== LISTEN SOCKETS ====="

    ss -lntup \
      2>/dev/null \
      | grep -E \
        '(:4040\b|config-location|python|xray)' \
      || true

    echo
    echo "===== PROJECT PROCESSES ====="

    ps \
      -eo pid,ppid,user,group,etimes,%cpu,%mem,cmd \
      | grep -E \
        '[c]onfig-location|/opt/config-location|[x]ray' \
      || true

} \
  | sanitize_stream \
  > "$ROOT/runtime/network-processes.txt"

###############################################################################
# Timers
###############################################################################

systemctl list-timers \
    'config-location-*' \
    --all \
    --no-pager \
    > "$ROOT/runtime/timers.txt" \
    2>&1 || true

###############################################################################
# Runtime versions
###############################################################################

{
    echo "===== OS ====="
    cat /etc/os-release 2>/dev/null || true

    echo
    echo "===== KERNEL ====="
    uname -a 2>/dev/null || true

    echo
    echo "===== PYTHON SYSTEM ====="
    python3 --version 2>&1 || true

    echo
    echo "===== PYTHON PROJECT ====="

    if [ -x "$PROJECT/venv/bin/python" ]; then
        "$PROJECT/venv/bin/python" --version 2>&1 || true
    fi

    echo
    echo "===== XRAY ====="

    if command -v xray >/dev/null 2>&1; then
        xray version 2>&1 | head -n 30
    elif [ -x /usr/local/bin/xray ]; then
        /usr/local/bin/xray version 2>&1 | head -n 30
    fi

    echo
    echo "===== NGINX ====="

    if command -v nginx >/dev/null 2>&1; then
        nginx -v 2>&1 || true
    fi

    echo
    echo "===== GIT ====="
    git --version 2>&1 || true

} > "$ROOT/runtime/versions.txt"

###############################################################################
# HTTP read-only probes
###############################################################################

mkdir -p "$ROOT/http"

probe_http() {
    local NAME="$1"
    local URL="$2"

    local HDR="$ROOT/http/$NAME.headers"
    local BODY="$ROOT/http/$NAME.body"
    local META="$ROOT/http/$NAME.meta"

    CODE="$(
        curl \
          -sS \
          --max-time 10 \
          -D "$HDR" \
          -o "$BODY" \
          -w '%{http_code}' \
          "$URL" \
          2>/dev/null \
          || true
    )"

    SIZE="$(
        stat -c '%s' "$BODY" \
          2>/dev/null \
          || echo 0
    )"

    {
        echo "name=$NAME"
        echo "url=$URL"
        echo "http_code=$CODE"
        echo "body_bytes=$SIZE"
    } > "$META"

    # Never keep subscription bodies.
    case "$NAME" in
        sub_all|country_unknown|country_invalid)
            rm -f "$BODY"
            echo "<BODY_NOT_COLLECTED>" > "$BODY"
            ;;
        *)
            # If body is JSON, sanitize it.
            if [ -s "$BODY" ]; then
                if python3 -m json.tool \
                    "$BODY" \
                    >/dev/null 2>&1
                then
                    sanitize_json_file \
                      "$BODY" \
                      "$BODY.sanitized"

                    mv \
                      "$BODY.sanitized" \
                      "$BODY"
                else
                    head -c 4096 "$BODY" \
                      | sanitize_stream \
                      > "$BODY.safe"

                    mv \
                      "$BODY.safe" \
                      "$BODY"
                fi
            fi
            ;;
    esac

    sanitize_stream \
      < "$HDR" \
      > "$HDR.safe"

    mv "$HDR.safe" "$HDR"

    echo "$NAME=$CODE"
}

probe_http \
  health \
  "http://127.0.0.1:4040/health"

probe_http \
  publish_status \
  "http://127.0.0.1:4040/api/publish/status"

probe_http \
  countries \
  "http://127.0.0.1:4040/api/countries"

probe_http \
  sub_all \
  "http://127.0.0.1:4040/sub/all"

probe_http \
  country_unknown \
  "http://127.0.0.1:4040/sub/country/UNKNOWN"

probe_http \
  country_invalid \
  "http://127.0.0.1:4040/sub/country/INVALID"

###############################################################################
# Read-only permission probes with actual service users
###############################################################################

{
    echo "===== SERVICE USERS ====="

    for UNIT in \
      config-location-panel.service \
      config-location-fetcher.service \
      config-location-country-worker.service \
      config-location-country-event-consumer.service
    do
        USER="$(
            systemctl show "$UNIT" \
              -p User \
              --value \
              2>/dev/null \
              || true
        )"

        GROUP="$(
            systemctl show "$UNIT" \
              -p Group \
              --value \
              2>/dev/null \
              || true
        )"

        echo "$UNIT user=${USER:-root} group=${GROUP:-default}"
    done

    echo
    echo "===== PANEL USER READABILITY ====="

    PANEL_USER="$(
        systemctl show \
          config-location-panel.service \
          -p User \
          --value \
          2>/dev/null \
          || true
    )"

    PANEL_USER="${PANEL_USER:-root}"

    for P in \
      /var/lib/config-location \
      /var/lib/config-location/health-results \
      /var/lib/config-location/health-results/latest \
      /var/lib/config-location/country \
      /var/lib/config-location/country/country-identity
    do
        [ -e "$P" ] || continue

        if command -v runuser >/dev/null 2>&1; then
            if runuser \
                -u "$PANEL_USER" \
                -- test -r "$P" \
                2>/dev/null
            then
                echo "READ=YES user=$PANEL_USER path=$P"
            else
                echo "READ=NO user=$PANEL_USER path=$P"
            fi
        fi
    done

} > "$ROOT/runtime/service-user-access.txt"

echo "RUNTIME_CONTRACT=PASS"


###############################################################################
# [8/8] FINAL SANITIZE + MANIFEST + ARCHIVE
###############################################################################

section "[8/8] FINALIZE EVIDENCE"

###############################################################################
# Remove files that should never be present
###############################################################################

find "$ROOT" -type f \
  \( \
    -iname '*.pem' \
    -o -iname '*.key' \
    -o -iname '*.p12' \
    -o -iname '*.pfx' \
    -o -iname 'id_rsa*' \
    -o -iname 'id_ed25519*' \
    -o -iname '.env' \
    -o -iname '.env.*' \
  \) \
  -print \
  -delete \
  2>/dev/null || true

###############################################################################
# Final textual redaction pass
###############################################################################

while IFS= read -r FILE; do

    [ -f "$FILE" ] || continue

    if grep -Iq . "$FILE" 2>/dev/null; then

        TMP="$FILE.redacted"

        sanitize_stream \
          < "$FILE" \
          > "$TMP"

        mv "$TMP" "$FILE"
    fi

done < <(
    find "$ROOT" \
      -type f \
      -print
)

###############################################################################
# Detect obvious private key markers after redaction
###############################################################################

if grep -RIl \
    --binary-files=without-match \
    -E \
    'BEGIN .*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY' \
    "$ROOT" \
    2>/dev/null \
    | grep -q .
then
    echo "ERROR: PRIVATE_KEY_MARKER_REMAINS"
    grep -RIl \
      --binary-files=without-match \
      -E \
      'BEGIN .*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY' \
      "$ROOT" \
      2>/dev/null \
      || true

    exit 1
fi

echo "PRIVATE_KEY_AUDIT=PASS"

###############################################################################
# Detect obvious proxy URI leakage
###############################################################################

PROXY_LEAKS="$WORK/proxy-leaks.txt"

grep -RIl \
  --binary-files=without-match \
  -E \
  '(^|[^A-Za-z])(vless|vmess|trojan|ss|socks5?|wireguard|wg|hysteria2?|hy2|tuic)://' \
  "$ROOT" \
  2>/dev/null \
  > "$PROXY_LEAKS" || true

if [ -s "$PROXY_LEAKS" ]; then

    echo "WARNING: proxy URI-like content found in:"
    cat "$PROXY_LEAKS"

    echo
    echo "Sanitizing matching text files..."

    while IFS= read -r FILE; do

        [ -f "$FILE" ] || continue

        python3 - "$FILE" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])

try:
    text = p.read_text(
        encoding="utf-8",
    )
except Exception:
    raise SystemExit(0)

rx = re.compile(
    r'(?i)\b(?:vless|vmess|trojan|ss|socks5?|wireguard|wg|hysteria2?|hy2|tuic)://[^\s"\'<>]+'
)

text = rx.sub(
    "<PROXY_URI_REDACTED>",
    text,
)

p.write_text(
    text,
    encoding="utf-8",
)
PY

    done < "$PROXY_LEAKS"
fi

echo "PROXY_URI_AUDIT=PASS"

###############################################################################
# Cap unexpectedly large files
###############################################################################

while IFS= read -r FILE; do

    SIZE="$(
        stat -c '%s' "$FILE" \
          2>/dev/null \
          || echo 0
    )"

    if [ "$SIZE" -gt 131072 ]; then

        echo "TRUNCATING_LARGE_EVIDENCE_FILE=$FILE size=$SIZE"

        TMP="$FILE.truncated"

        {
            head -c 65536 "$FILE" 2>/dev/null || true
            echo
            echo "<EVIDENCE_TRUNCATED original_bytes=$SIZE>"
        } > "$TMP"

        mv "$TMP" "$FILE"
    fi

done < <(
    find "$ROOT" \
      -type f \
      -print
)

###############################################################################
# Manifest
###############################################################################

(
    cd "$ROOT"

    find . \
      -type f \
      -printf '%P\n' \
      | LC_ALL=C sort

) > "$MANIFEST"

FILE_COUNT="$(
    wc -l < "$MANIFEST"
)"

###############################################################################
# Per-file hashes
###############################################################################

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

HASH_COUNT="$(
    wc -l < "$HASHES"
)"

test "$FILE_COUNT" -eq "$HASH_COUNT" \
  || die "FILE_HASH_COUNT_MISMATCH"

###############################################################################
# Summary / info
###############################################################################

TOTAL_BYTES="$(
    du -sb "$ROOT" \
      | awk '{print $1}'
)"

JOURNAL_FILES="$(
    find "$ROOT/journal" \
      -type f \
      2>/dev/null \
      | wc -l
)"

SYSTEMD_CONTRACTS="$(
    find "$ROOT/systemd/contracts" \
      -type f \
      2>/dev/null \
      | wc -l
)"

SAMPLE_FILES="$(
    find "$ROOT/samples" \
      -type f \
      2>/dev/null \
      | wc -l
)"

{
    echo "CONFIG_LOCATION_RUNTIME_EVIDENCE"
    echo
    echo "created_at=$(date --iso-8601=seconds)"
    echo "hostname=$(hostname)"
    echo "project=$PROJECT"
    echo
    echo "mode=READ_ONLY"
    echo "files=$FILE_COUNT"
    echo "total_bytes=$TOTAL_BYTES"
    echo "systemd_contracts=$SYSTEMD_CONTRACTS"
    echo "journal_files=$JOURNAL_FILES"
    echo "sanitized_samples=$SAMPLE_FILES"
    echo
    echo "COLLECTED:"
    echo "systemd units/runtime contracts"
    echo "bounded recent journals"
    echo "state filesystem structure only"
    echo "permissions/ACL"
    echo "sanitized representative states"
    echo "ports/processes"
    echo "timers"
    echo "runtime versions"
    echo "read-only HTTP probes"
    echo "service-user readability"
    echo
    echo "NOT_COLLECTED:"
    echo "raw VPN configs"
    echo "subscription bodies"
    echo "private keys"
    echo "passwords"
    echo "tokens"
    echo "cookies/sessions"
    echo "full /var/lib state"
    echo "full journals"
    echo "source mutation"
    echo "service restart"
    echo "Fetch Now"
    echo "Health execution"
    echo
    echo "REDACTION:"
    echo "private-key marker audit=PASS"
    echo "proxy URI audit=PASS"
} > "$INFO"

cat "$INFO"

###############################################################################
# Archive
###############################################################################

echo
echo "========== CREATE ARCHIVE =========="

tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$WORK" \
    -cf - \
    config-location-runtime-evidence \
  | zstd \
      -T0 \
      -10 \
      -q \
      -o "$ARCHIVE"

test -s "$ARCHIVE" \
  || die "ARCHIVE_EMPTY"

###############################################################################
# Archive SHA
###############################################################################

sha256sum "$ARCHIVE" > "$SHA"

###############################################################################
# Verify zstd
###############################################################################

zstd -t "$ARCHIVE"

###############################################################################
# Verify tar
###############################################################################

tar \
    --use-compress-program=unzstd \
    -tf "$ARCHIVE" \
    >/dev/null

###############################################################################
# Verify archive SHA
###############################################################################

(
    cd "$DEST"

    sha256sum \
      -c "$(basename "$SHA")"
)

###############################################################################
# Final summary
###############################################################################

ARCHIVE_SIZE="$(
    du -h "$ARCHIVE" \
      | awk '{print $1}'
)"

echo
echo "============================================================"
echo " CONFIG LOCATION RUNTIME EVIDENCE READY"
echo "============================================================"

echo "ARCHIVE=$ARCHIVE"
echo "ARCHIVE_SIZE=$ARCHIVE_SIZE"
echo "SHA256=$SHA"
echo "MANIFEST=$MANIFEST"
echo "FILE_HASHES=$HASHES"
echo "INFO=$INFO"

echo
echo "EVIDENCE_FILES=$FILE_COUNT"
echo "EVIDENCE_BYTES=$TOTAL_BYTES"

echo
echo "UPLOAD THESE 5 FILES:"
echo "1) $ARCHIVE"
echo "2) $SHA"
echo "3) $MANIFEST"
echo "4) $HASHES"
echo "5) $INFO"

echo
echo "CONFIG_LOCATION_RUNTIME_EVIDENCE=SUCCESS"

###############################################################################
# [8/8] FINAL SANITIZE + MANIFEST + ARCHIVE
###############################################################################

section "[8/8] FINALIZE EVIDENCE"

###############################################################################
# Remove files that should never be present
###############################################################################

find "$ROOT" -type f \
  \( \
    -iname '*.pem' \
    -o -iname '*.key' \
    -o -iname '*.p12' \
    -o -iname '*.pfx' \
    -o -iname 'id_rsa*' \
    -o -iname 'id_ed25519*' \
    -o -iname '.env' \
    -o -iname '.env.*' \
  \) \
  -print \
  -delete \
  2>/dev/null || true

###############################################################################
# Final textual redaction pass
###############################################################################

while IFS= read -r FILE; do

    [ -f "$FILE" ] || continue

    if grep -Iq . "$FILE" 2>/dev/null; then

        TMP="$FILE.redacted"

        sanitize_stream \
          < "$FILE" \
          > "$TMP"

        mv "$TMP" "$FILE"
    fi

done < <(
    find "$ROOT" \
      -type f \
      -print
)

###############################################################################
# Detect obvious private key markers after redaction
###############################################################################

if grep -RIl \
    --binary-files=without-match \
    -E \
    'BEGIN .*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY' \
    "$ROOT" \
    2>/dev/null \
    | grep -q .
then
    echo "ERROR: PRIVATE_KEY_MARKER_REMAINS"
    grep -RIl \
      --binary-files=without-match \
      -E \
      'BEGIN .*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY' \
      "$ROOT" \
      2>/dev/null \
      || true

    exit 1
fi

echo "PRIVATE_KEY_AUDIT=PASS"

###############################################################################
# Detect obvious proxy URI leakage
###############################################################################

PROXY_LEAKS="$WORK/proxy-leaks.txt"

grep -RIl \
  --binary-files=without-match \
  -E \
  '(^|[^A-Za-z])(vless|vmess|trojan|ss|socks5?|wireguard|wg|hysteria2?|hy2|tuic)://' \
  "$ROOT" \
  2>/dev/null \
  > "$PROXY_LEAKS" || true

if [ -s "$PROXY_LEAKS" ]; then

    echo "WARNING: proxy URI-like content found in:"
    cat "$PROXY_LEAKS"

    echo
    echo "Sanitizing matching text files..."

    while IFS= read -r FILE; do

        [ -f "$FILE" ] || continue

        python3 - "$FILE" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])

try:
    text = p.read_text(
        encoding="utf-8",
    )
except Exception:
    raise SystemExit(0)

rx = re.compile(
    r'(?i)\b(?:vless|vmess|trojan|ss|socks5?|wireguard|wg|hysteria2?|hy2|tuic)://[^\s"\'<>]+'
)

text = rx.sub(
    "<PROXY_URI_REDACTED>",
    text,
)

p.write_text(
    text,
    encoding="utf-8",
)
PY

    done < "$PROXY_LEAKS"
fi

echo "PROXY_URI_AUDIT=PASS"

###############################################################################
# Cap unexpectedly large files
###############################################################################

while IFS= read -r FILE; do

    SIZE="$(
        stat -c '%s' "$FILE" \
          2>/dev/null \
          || echo 0
    )"

    if [ "$SIZE" -gt 131072 ]; then

        echo "TRUNCATING_LARGE_EVIDENCE_FILE=$FILE size=$SIZE"

        TMP="$FILE.truncated"

        {
            head -c 65536 "$FILE" 2>/dev/null || true
            echo
            echo "<EVIDENCE_TRUNCATED original_bytes=$SIZE>"
        } > "$TMP"

        mv "$TMP" "$FILE"
    fi

done < <(
    find "$ROOT" \
      -type f \
      -print
)

###############################################################################
# Manifest
###############################################################################

(
    cd "$ROOT"

    find . \
      -type f \
      -printf '%P\n' \
      | LC_ALL=C sort

) > "$MANIFEST"

FILE_COUNT="$(
    wc -l < "$MANIFEST"
)"

###############################################################################
# Per-file hashes
###############################################################################

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

HASH_COUNT="$(
    wc -l < "$HASHES"
)"

test "$FILE_COUNT" -eq "$HASH_COUNT" \
  || die "FILE_HASH_COUNT_MISMATCH"

###############################################################################
# Summary / info
###############################################################################

TOTAL_BYTES="$(
    du -sb "$ROOT" \
      | awk '{print $1}'
)"

JOURNAL_FILES="$(
    find "$ROOT/journal" \
      -type f \
      2>/dev/null \
      | wc -l
)"

SYSTEMD_CONTRACTS="$(
    find "$ROOT/systemd/contracts" \
      -type f \
      2>/dev/null \
      | wc -l
)"

SAMPLE_FILES="$(
    find "$ROOT/samples" \
      -type f \
      2>/dev/null \
      | wc -l
)"

{
    echo "CONFIG_LOCATION_RUNTIME_EVIDENCE"
    echo
    echo "created_at=$(date --iso-8601=seconds)"
    echo "hostname=$(hostname)"
    echo "project=$PROJECT"
    echo
    echo "mode=READ_ONLY"
    echo "files=$FILE_COUNT"
    echo "total_bytes=$TOTAL_BYTES"
    echo "systemd_contracts=$SYSTEMD_CONTRACTS"
    echo "journal_files=$JOURNAL_FILES"
    echo "sanitized_samples=$SAMPLE_FILES"
    echo
    echo "COLLECTED:"
    echo "systemd units/runtime contracts"
    echo "bounded recent journals"
    echo "state filesystem structure only"
    echo "permissions/ACL"
    echo "sanitized representative states"
    echo "ports/processes"
    echo "timers"
    echo "runtime versions"
    echo "read-only HTTP probes"
    echo "service-user readability"
    echo
    echo "NOT_COLLECTED:"
    echo "raw VPN configs"
    echo "subscription bodies"
    echo "private keys"
    echo "passwords"
    echo "tokens"
    echo "cookies/sessions"
    echo "full /var/lib state"
    echo "full journals"
    echo "source mutation"
    echo "service restart"
    echo "Fetch Now"
    echo "Health execution"
    echo
    echo "REDACTION:"
    echo "private-key marker audit=PASS"
    echo "proxy URI audit=PASS"
} > "$INFO"

cat "$INFO"

###############################################################################
# Archive
###############################################################################

echo
echo "========== CREATE ARCHIVE =========="

tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$WORK" \
    -cf - \
    config-location-runtime-evidence \
  | zstd \
      -T0 \
      -10 \
      -q \
      -o "$ARCHIVE"

test -s "$ARCHIVE" \
  || die "ARCHIVE_EMPTY"

###############################################################################
# Archive SHA
###############################################################################

sha256sum "$ARCHIVE" > "$SHA"

###############################################################################
# Verify zstd
###############################################################################

zstd -t "$ARCHIVE"

###############################################################################
# Verify tar
###############################################################################

tar \
    --use-compress-program=unzstd \
    -tf "$ARCHIVE" \
    >/dev/null

###############################################################################
# Verify archive SHA
###############################################################################

(
    cd "$DEST"

    sha256sum \
      -c "$(basename "$SHA")"
)

###############################################################################
# Final summary
###############################################################################

ARCHIVE_SIZE="$(
    du -h "$ARCHIVE" \
      | awk '{print $1}'
)"

echo
echo "============================================================"
echo " CONFIG LOCATION RUNTIME EVIDENCE READY"
echo "============================================================"

echo "ARCHIVE=$ARCHIVE"
echo "ARCHIVE_SIZE=$ARCHIVE_SIZE"
echo "SHA256=$SHA"
echo "MANIFEST=$MANIFEST"
echo "FILE_HASHES=$HASHES"
echo "INFO=$INFO"

echo
echo "EVIDENCE_FILES=$FILE_COUNT"
echo "EVIDENCE_BYTES=$TOTAL_BYTES"

echo
echo "UPLOAD THESE 5 FILES:"
echo "1) $ARCHIVE"
echo "2) $SHA"
echo "3) $MANIFEST"
echo "4) $HASHES"
echo "5) $INFO"

echo
echo "CONFIG_LOCATION_RUNTIME_EVIDENCE=SUCCESS"
