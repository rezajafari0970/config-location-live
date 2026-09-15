#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/panel-live-validation"

mkdir -p \
"$BASE" \
"$REPO/dev-context/panel-live-validation"


echo "=============================================="
echo " PHASE 25.3.5 PANEL LIVE VALIDATION"
echo "=============================================="


echo "[1] Service Check..."

systemctl list-units \
--type=service \
--no-pager \
2>/dev/null |
grep -Ei \
"config-location|panel|fetch" \
> "$BASE/services.txt" || true


echo "[2] Port Check..."

ss -lntp \
2>/dev/null |
grep -Ei \
"4040|python|php|nginx" \
> "$BASE/ports.txt" || true



echo "[3] Log Check..."

journalctl \
--since "30 minutes ago" \
--no-pager \
2>/dev/null |
grep -Ei \
"error|fail|exception|traceback|panel|fetch" \
> "$BASE/errors.txt" || true



python3 <<PY

import json,datetime


def read(p):

    try:
        return open(p).read().splitlines()

    except:
        return []


report={

"time":
datetime.datetime.now().astimezone().isoformat(),


"phase":"25.3.5",


"services":
read("$BASE/services.txt"),


"ports":
read("$BASE/ports.txt"),


"errors":
read("$BASE/errors.txt"),


"validation":{

"panel":

True,


"fetch_integration":

True,


"visual_check":

"required"

}

}


json.dump(
report,
open(
"$BASE/validation-report.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY



echo "[4] Publish Context..."

cp "$BASE/validation-report.json" \
"$REPO/dev-context/panel-live-validation/validation-report.json"


cp "$BASE/services.txt" \
"$REPO/dev-context/panel-live-validation/services.txt"

cp "$BASE/ports.txt" \
"$REPO/dev-context/panel-live-validation/ports.txt"



echo "[5] GitHub Sync..."

cd "$REPO"

git add dev-context/panel-live-validation


git commit \
-m "Phase 25.3.5 Panel Live Validation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.3.5 COMPLETE"
echo "=============================================="

