#!/usr/bin/env bash
set -Eeuo pipefail

REPO="rezajafari0970/Devlog_fetch-x-ray-country"

SANDBOX="/opt/config-location/app/health/runtime/sandbox.py"
LAUNCHER="/opt/config-location/app/health/runtime/launcher.py"

TS=$(date -u +%Y%m%d-%H%M%S)

BASE="diagnostics/xray-retention/$TS"
TMP="/tmp/xray-retention-github-$TS"

mkdir -p "$TMP"

echo "=== VERIFY FILES ==="

test -f "$SANDBOX"
test -f "$LAUNCHER"

echo "SANDBOX=$SANDBOX"
echo "LAUNCHER=$LAUNCHER"


echo
echo "=== VERIFY GH ==="

command -v gh >/dev/null

gh auth status

echo "GH_AUTH=PASS"


echo
echo "=== PREPARE FILES ==="

cp -a \
"$SANDBOX" \
"$TMP/sandbox.py"

cp -a \
"$LAUNCHER" \
"$TMP/launcher.py"


nl -ba "$SANDBOX" \
| sed -n '1,320p' \
>"$TMP/sandbox-lines-1-320.txt"


nl -ba "$LAUNCHER" \
| sed -n '240,340p' \
>"$TMP/launcher-lines-240-340.txt"


cat >"$TMP/README.txt" <<EOF
CONFIG LOCATION — XRAY RETENTION CALLSITE

UTC_TIMESTAMP=$TS

SOURCE_SANDBOX:
$SANDBOX

SOURCE_LAUNCHER:
$LAUNCHER

FILES:
sandbox.py
launcher.py
sandbox-lines-1-320.txt
launcher-lines-240-340.txt

PURPOSE:
Inspect Xray runtime lifecycle and integrate forensic
log retention before sandbox cleanup without running
a second Xray process.
EOF


echo
echo "=== UPLOAD FUNCTION ==="

upload_file() {

    LOCAL="$1"
    REMOTE="$2"

    CONTENT=$(
        base64 -w0 "$LOCAL"
    )

    SHA=$(
        gh api \
        -H "Accept: application/vnd.github+json" \
        "/repos/$REPO/contents/$REMOTE" \
        --jq '.sha' \
        2>/dev/null || true
    )

    if [ -n "$SHA" ]; then

        echo "UPDATE=$REMOTE"

        gh api \
        --method PUT \
        -H "Accept: application/vnd.github+json" \
        "/repos/$REPO/contents/$REMOTE" \
        -f message="Update Xray retention diagnostic $TS" \
        -f content="$CONTENT" \
        -f sha="$SHA" \
        >/dev/null

    else

        echo "CREATE=$REMOTE"

        gh api \
        --method PUT \
        -H "Accept: application/vnd.github+json" \
        "/repos/$REPO/contents/$REMOTE" \
        -f message="Add Xray retention diagnostic $TS" \
        -f content="$CONTENT" \
        >/dev/null

    fi
}


echo
echo "=== PUSH TO GITHUB ==="

upload_file \
"$TMP/sandbox.py" \
"$BASE/sandbox.py"

upload_file \
"$TMP/launcher.py" \
"$BASE/launcher.py"

upload_file \
"$TMP/sandbox-lines-1-320.txt" \
"$BASE/sandbox-lines-1-320.txt"

upload_file \
"$TMP/launcher-lines-240-340.txt" \
"$BASE/launcher-lines-240-340.txt"

upload_file \
"$TMP/README.txt" \
"$BASE/README.txt"


echo
echo "=== WRITE POINTER FILE ==="

cat >"$TMP/latest-xray-retention-diagnostic.txt" <<EOF
LATEST_XRAY_RETENTION_DIAGNOSTIC=$BASE
TIMESTAMP=$TS
SANDBOX=$BASE/sandbox.py
LAUNCHER=$BASE/launcher.py
SANDBOX_LINES=$BASE/sandbox-lines-1-320.txt
LAUNCHER_LINES=$BASE/launcher-lines-240-340.txt
EOF

upload_file \
"$TMP/latest-xray-retention-diagnostic.txt" \
"latest-xray-retention-diagnostic.txt"


echo
echo "=============================================="
echo "XRAY_SOURCE_GITHUB_PUSH=PASS"
echo "REPO=$REPO"
echo "GITHUB_PATH=$BASE"
echo "POINTER=latest-xray-retention-diagnostic.txt"
echo "=============================================="
