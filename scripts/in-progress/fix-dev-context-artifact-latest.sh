#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

echo "=============================================="
echo " DEV CONTEXT ARTIFACT LATEST FIX"
echo "=============================================="

mkdir -p \
"$DEV/scripts" \
"$REPO/dev-context"


echo "[1/5] Creating artifact helper..."

cat >"$DEV/scripts/update-latest-artifact.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$1"
PATTERN="$2"
LATEST="$3"

FILE=$(ls -1t "$DIR"/$PATTERN 2>/dev/null | head -1 || true)

if [ -n "$FILE" ]; then
    cp "$FILE" "$DIR/$LATEST"
    echo "UPDATED:"
    echo "$DIR/$LATEST"
else
    echo "NO FILE:"
    echo "$PATTERN"
fi
SCRIPT

chmod 700 "$DEV/scripts/update-latest-artifact.sh"


echo "[2/5] Fixing audit latest..."

"$DEV/scripts/update-latest-artifact.sh" \
"$DEV/audit" \
"core-architecture-audit-*.json" \
"core-architecture-audit-latest.json" || true


"$DEV/scripts/update-latest-artifact.sh" \
"$DEV/audit" \
"core-architecture-audit-*.txt" \
"core-architecture-audit-latest.txt" || true


echo "[3/5] Fixing analysis latest..."

"$DEV/scripts/update-latest-artifact.sh" \
"$DEV/analysis" \
"core-analysis-*.json" \
"core-analysis-latest.json" || true


"$DEV/scripts/update-latest-artifact.sh" \
"$DEV/analysis" \
"core-analysis-*.txt" \
"core-analysis-latest.txt" || true


echo "[4/5] Publishing Dev Context..."

mkdir -p \
"$REPO/dev-context/audit" \
"$REPO/dev-context/analysis"


cp "$DEV/audit/"*-latest.* \
"$REPO/dev-context/audit/" 2>/dev/null || true


cp "$DEV/analysis/"*-latest.* \
"$REPO/dev-context/analysis/" 2>/dev/null || true


echo "[5/5] GitHub Sync..."

cd "$REPO"

git add dev-context


if git diff --cached --quiet
then
    echo "NO CHANGES"
else

git commit \
-m "Fix Dev Context latest artifact pointers $(date -Is)"

git push origin main

fi


echo
echo "=============================================="
echo " DEV CONTEXT FIX COMPLETE"
echo "=============================================="

echo
echo "Latest artifacts:"

find "$DEV" \
-name "*latest*" \
-type f \
2>/dev/null | sort

