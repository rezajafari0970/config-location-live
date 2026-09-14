#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT="/root/make-config-location-runtime-evidence.sh"
DEST="/root/631"
REPO="/root/config-location-live-git"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$DEST/runtime-evidence-run-$STAMP.log"

mkdir -p "$DEST"

exec > >(tee -a "$RUNLOG") 2>&1

echo "============================================================"
echo " CONFIG LOCATION RUNTIME EVIDENCE RUN"
echo "============================================================"
echo "STARTED_AT=$(date --iso-8601=seconds)"
echo "LOG=$RUNLOG"

if [ ! -x "$SCRIPT" ]; then
    echo "ERROR=SCRIPT_NOT_EXECUTABLE"
    exit 1
fi

set +e

"$SCRIPT"

RC=$?

set -e

echo
echo "RUNTIME_EVIDENCE_EXIT=$RC"

if [ "$RC" -ne 0 ]; then
    echo "RUNTIME_EVIDENCE_RESULT=FAIL"
    echo "SCRIPT_PRESERVED=YES"
    echo "LOG_PRESERVED=$RUNLOG"
    exit "$RC"
fi

echo "RUNTIME_EVIDENCE_RESULT=PASS"

ARCHIVE="$(
    ls -1t \
      "$DEST"/CONFIG-LOCATION-RUNTIME-EVIDENCE-*.tar.zst \
      2>/dev/null \
      | sed -n '1p'
)"

if [ -z "${ARCHIVE:-}" ]; then
    echo "ERROR=ARCHIVE_NOT_FOUND_AFTER_PASS"
    exit 1
fi

BASE="${ARCHIVE%.tar.zst}"

FILES=(
    "$ARCHIVE"
    "$ARCHIVE.sha256"
    "$BASE.manifest.txt"
    "$BASE.files.sha256"
    "$BASE.info.txt"
)

for F in "${FILES[@]}"; do
    if [ ! -s "$F" ]; then
        echo "ERROR=MISSING_OUTPUT:$F"
        exit 1
    fi
done

echo
echo "OUTPUT_FILES:"
printf '%s\n' "${FILES[@]}"

if [ ! -d "$REPO/.git" ]; then
    echo "ERROR=GIT_MIRROR_NOT_FOUND:$REPO"
    exit 1
fi

cd "$REPO"

BRANCH="$(
    git rev-parse --abbrev-ref HEAD
)"

echo "GIT_BRANCH=$BRANCH"

TARGET_DIR="runtime-evidence/$STAMP"

mkdir -p "$TARGET_DIR"

for F in "${FILES[@]}"; do
    cp -a "$F" "$TARGET_DIR/"
done

cp -a "$RUNLOG" "$TARGET_DIR/"

cat > "$TARGET_DIR/README.txt" <<TXT
CONFIG LOCATION RUNTIME EVIDENCE

Created:
$(date --iso-8601=seconds)

Production source:
$SCRIPT

Result:
PASS

Included:
- Runtime Evidence archive
- Archive SHA256
- File manifest
- Per-file SHA256
- Info summary
- Execution log

Sensitive raw VPN config bodies are not intentionally collected.
TXT

echo
echo "GIT STATUS BEFORE COMMIT:"
git status --short "$TARGET_DIR"

git add "$TARGET_DIR"

if git diff --cached --quiet; then
    echo "GIT_COMMIT=NO_CHANGES"
else
    git commit \
      -m "runtime-evidence: $STAMP"

    git push origin "$BRANCH"

    echo "GITHUB_PUSH=PASS"
fi

echo
echo "============================================================"
echo " RUNTIME EVIDENCE COMPLETE"
echo "============================================================"
echo "TARGET_DIR=$TARGET_DIR"
echo "RUNLOG=$RUNLOG"
echo "FINAL_RESULT=PASS"
