#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# CONFIG LOCATION — SOURCE ONLY SNAPSHOT
#
# Source of snapshot:
#   /opt/config-location
#
# INCLUDED:
#   project source code
#   tests
#   scripts/tools
#   templates/static assets
#   project metadata / requirements / docs
#
# EXCLUDED:
#   venv
#   .git
#   backups
#   runtime/state/data
#   logs
#   caches
#   bytecode
#   secrets/env files
#   generated evidence/reports
###############################################################################

PROJECT="/opt/config-location"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUTROOT="/root/CONFIG-LOCATION-SOURCE-AUDIT"
WORK="$OUTROOT/work-$STAMP"
SNAPROOT="$WORK/config-location-source"

ARCHIVE="$OUTROOT/CONFIG-LOCATION-SOURCE-ONLY-$STAMP.tar.zst"
SHA="$ARCHIVE.sha256"

MANIFEST="$OUTROOT/CONFIG-LOCATION-SOURCE-ONLY-$STAMP.manifest.txt"
HASHES="$OUTROOT/CONFIG-LOCATION-SOURCE-ONLY-$STAMP.files.sha256"
INFO="$OUTROOT/CONFIG-LOCATION-SOURCE-ONLY-$STAMP.info.txt"

###############################################################################
# helpers
###############################################################################

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    rm -rf "$WORK" 2>/dev/null || true
}

trap cleanup EXIT

echo
echo "============================================================"
echo " CONFIG LOCATION — SOURCE ONLY SNAPSHOT"
echo "============================================================"
echo

###############################################################################
# [1/12] precheck
###############################################################################

echo "========== [1/12] PRECHECK =========="

test -d "$PROJECT" || die "PROJECT_NOT_FOUND=$PROJECT"

mkdir -p "$OUTROOT"

command -v rsync >/dev/null 2>&1 || {
    echo "Installing rsync..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y rsync
}

command -v zstd >/dev/null 2>&1 || {
    echo "Installing zstd..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y zstd
}

command -v sha256sum >/dev/null 2>&1 \
    || die "sha256sum not found"

command -v tar >/dev/null 2>&1 \
    || die "tar not found"

echo "PROJECT=$PROJECT"
echo "OUTPUT=$OUTROOT"
echo "PRECHECK=PASS"

###############################################################################
# [2/12] source inventory before copy
###############################################################################

echo
echo "========== [2/12] SOURCE INVENTORY =========="

echo "Top level:"
find "$PROJECT" \
    -mindepth 1 \
    -maxdepth 1 \
    -printf '%f\n' \
    | sort

echo
echo "Total filesystem entries:"
find "$PROJECT" | wc -l

###############################################################################
# [3/12] prepare staging
###############################################################################

echo
echo "========== [3/12] PREPARE STAGING =========="

mkdir -p "$SNAPROOT"

echo "STAGING=$SNAPROOT"
echo "STAGING=READY"

###############################################################################
# [4/12] copy current source only
###############################################################################

echo
echo "========== [4/12] COPY SOURCE ONLY =========="

rsync \
    -aH \
    --itemize-changes \
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
    --exclude='*.pyd' \
    \
    --exclude='.pytest_cache/' \
    --exclude='.mypy_cache/' \
    --exclude='.ruff_cache/' \
    --exclude='.coverage' \
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
    --exclude='state/' \
    --exclude='states/' \
    --exclude='data/' \
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
    --exclude='*.tgz' \
    --exclude='*.tar.zst' \
    --exclude='*.zip' \
    --exclude='*.7z' \
    \
    --exclude='.env' \
    --exclude='.env.*' \
    --exclude='*.pem' \
    --exclude='*.key' \
    --exclude='*.p12' \
    --exclude='*.pfx' \
    --exclude='id_rsa*' \
    --exclude='id_ed25519*' \
    --exclude='credentials*.json' \
    --exclude='token*.json' \
    --exclude='secrets*.json' \
    --exclude='secret*.json' \
    \
    "$PROJECT/" \
    "$SNAPROOT/"

echo
echo "SOURCE_COPY=PASS"

###############################################################################
# [5/12] remove accidental runtime/artifact files
###############################################################################

echo
echo "========== [5/12] SANITIZE =========="

find "$SNAPROOT" -type d \
    \( \
       -name '__pycache__' \
       -o -name '.pytest_cache' \
       -o -name '.mypy_cache' \
       -o -name '.ruff_cache' \
       -o -name 'node_modules' \
       -o -name 'venv' \
       -o -name '.venv' \
    \) \
    -prune \
    -exec rm -rf {} + 2>/dev/null || true

find "$SNAPROOT" -type f \
    \( \
       -name '*.pyc' \
       -o -name '*.pyo' \
       -o -name '*.log' \
       -o -name '*.sqlite' \
       -o -name '*.sqlite3' \
       -o -name '*.db' \
    \) \
    -delete 2>/dev/null || true

echo "SANITIZE=PASS"

###############################################################################
# [6/12] sensitive-name audit
###############################################################################

echo
echo "========== [6/12] SENSITIVE FILE NAME AUDIT =========="

SENSITIVE="$WORK/sensitive-files.txt"

find "$SNAPROOT" -type f \
    | grep -Ei \
      '/(\.env($|\.)|.*credential.*|.*secret.*|.*token.*|.*private.*key.*|id_rsa|id_ed25519|.*\.pem$|.*\.p12$|.*\.pfx$)' \
    > "$SENSITIVE" || true

if [ -s "$SENSITIVE" ]; then

    echo "WARNING: suspicious filenames found:"
    cat "$SENSITIVE"

    echo
    echo "For safety these files will NOT be included."

    while IFS= read -r FILE; do
        rm -f -- "$FILE"
    done < "$SENSITIVE"

else
    echo "SENSITIVE_FILENAMES=NONE"
fi

echo "SENSITIVE_FILE_AUDIT=PASS"

###############################################################################
# [7/12] manifest
###############################################################################

echo
echo "========== [7/12] FILE MANIFEST =========="

(
    cd "$SNAPROOT"

    find . \
        -type f \
        -printf '%P\n' \
        | LC_ALL=C sort
) > "$MANIFEST"

FILE_COUNT="$(wc -l < "$MANIFEST")"

echo "SOURCE_FILES=$FILE_COUNT"

echo
echo "Top extensions:"

find "$SNAPROOT" -type f \
    | sed 's/.*\.//' \
    | tr '[:upper:]' '[:lower:]' \
    | sort \
    | uniq -c \
    | sort -nr \
    | head -n 30 || true

###############################################################################
# [8/12] per-file hashes
###############################################################################

echo
echo "========== [8/12] PER-FILE SHA256 =========="

(
    cd "$SNAPROOT"

    while IFS= read -r FILE; do
        sha256sum "$FILE"
    done < <(
        find . \
            -type f \
            -printf '%P\n' \
            | LC_ALL=C sort
    )
) > "$HASHES"

HASH_COUNT="$(wc -l < "$HASHES")"

test "$HASH_COUNT" -eq "$FILE_COUNT" \
    || die "HASH_COUNT_MISMATCH"

echo "HASHED_FILES=$HASH_COUNT"
echo "HASH_MANIFEST=PASS"

###############################################################################
# [9/12] syntax inventory
###############################################################################

echo
echo "========== [9/12] PYTHON SOURCE CHECK =========="

PYTHON_COUNT="$(
    find "$SNAPROOT" \
        -type f \
        -name '*.py' \
        | wc -l
)"

echo "PYTHON_FILES=$PYTHON_COUNT"

PYTHON_OK="UNKNOWN"

if [ -x "$PROJECT/venv/bin/python" ]; then

    set +e

    "$PROJECT/venv/bin/python" - <<PY
from pathlib import Path
import ast
import sys

root = Path(r"$SNAPROOT")

files = sorted(root.rglob("*.py"))

failed = []

for path in files:
    try:
        source = path.read_text(
            encoding="utf-8",
        )
        ast.parse(
            source,
            filename=str(path),
        )
    except Exception as exc:
        failed.append(
            (
                str(path.relative_to(root)),
                repr(exc),
            )
        )

print("PYTHON_FILES_CHECKED=", len(files))
print("PYTHON_PARSE_FAILED=", len(failed))

for path, exc in failed[:100]:
    print(
        "PARSE_FAIL",
        path,
        exc,
    )

if failed:
    sys.exit(1)
PY

    RC=$?

    set -e

    if [ "$RC" -eq 0 ]; then
        PYTHON_OK="PASS"
    else
        PYTHON_OK="FAIL"
    fi

else
    echo "Project Python unavailable; syntax audit skipped."
fi

echo "PYTHON_SOURCE_PARSE=$PYTHON_OK"

###############################################################################
# [10/12] metadata
###############################################################################

echo
echo "========== [10/12] BUILD INFO =========="

TOTAL_BYTES="$(
    du -sb "$SNAPROOT" \
      | awk '{print $1}'
)"

{
    echo "CONFIG_LOCATION_SOURCE_ONLY_SNAPSHOT"
    echo
    echo "created_at=$(date --iso-8601=seconds)"
    echo "hostname=$(hostname)"
    echo "project=$PROJECT"
    echo "source_files=$FILE_COUNT"
    echo "python_files=$PYTHON_COUNT"
    echo "python_parse=$PYTHON_OK"
    echo "uncompressed_bytes=$TOTAL_BYTES"
    echo
    echo "EXCLUDED:"
    echo "venv"
    echo ".git"
    echo "runtime/state/data"
    echo "logs"
    echo "backups"
    echo "snapshots"
    echo "caches"
    echo "bytecode"
    echo "archives"
    echo "known credential/private-key files"
    echo
    echo "NOTE:"
    echo "This archive is intended for source-code audit only."
} > "$INFO"

cat "$INFO"

###############################################################################
# [11/12] create archive
###############################################################################

echo
echo "========== [11/12] CREATE TAR.ZST =========="

tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$WORK" \
    -cf - \
    "config-location-source" \
    | zstd \
        -T0 \
        -10 \
        -q \
        -o "$ARCHIVE"

test -s "$ARCHIVE" \
    || die "ARCHIVE_EMPTY"

sha256sum "$ARCHIVE" > "$SHA"

echo "ARCHIVE=PASS"

###############################################################################
# [12/12] verify archive
###############################################################################

echo
echo "========== [12/12] VERIFY =========="

zstd -t "$ARCHIVE"

tar \
    --use-compress-program=unzstd \
    -tf "$ARCHIVE" \
    >/dev/null

(
    cd "$OUTROOT"
    sha256sum -c "$(basename "$SHA")"
)

ARCHIVE_SIZE="$(
    du -h "$ARCHIVE" \
    | awk '{print $1}'
)"

echo
echo "============================================================"
echo " SOURCE SNAPSHOT READY"
echo "============================================================"

echo "ARCHIVE=$ARCHIVE"
echo "ARCHIVE_SIZE=$ARCHIVE_SIZE"
echo "SHA256=$SHA"
echo "MANIFEST=$MANIFEST"
echo "FILE_HASHES=$HASHES"
echo "INFO=$INFO"

echo
echo "SOURCE_FILES=$FILE_COUNT"
echo "PYTHON_FILES=$PYTHON_COUNT"
echo "PYTHON_PARSE=$PYTHON_OK"

echo
echo "UPLOAD THESE 4 FILES:"
echo "1) $ARCHIVE"
echo "2) $SHA"
echo "3) $MANIFEST"
echo "4) $HASHES"

echo
echo "CONFIG_LOCATION_SOURCE_ONLY_SNAPSHOT=SUCCESS"
