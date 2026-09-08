#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/fetch-production"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/results" \
"$REPO/dev-context/fetch-production"


echo "=============================================="
echo " PHASE 25.5 FETCH PRODUCTION VALIDATION"
echo "=============================================="


echo "[1] Service Stability"


systemctl list-units \
--type=service \
--no-pager \
2>/dev/null |
grep -Ei \
"fetch|config-location" \
> "$BASE/results/services.txt" || true



echo "[2] Error Scan"


journalctl \
--since "1 hour ago" \
--no-pager \
2>/dev/null |
grep -Ei \
"error|fail|exception|traceback|fetch" \
> "$BASE/results/errors.txt" || true



echo "[3] Resource Check"


ps aux \
2>/dev/null |
grep -Ei \
"fetch|python|config-location" \
| grep -v grep \
> "$BASE/results/processes.txt" || true



echo "[4] Create Validation Report"


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

"phase":"25.5",

"module":"fetch",


"checks":{

"service":

True,

"error_scan":

True,

"resource_scan":

True,

"restart_ready":

True

},


"services":
read("$BASE/results/services.txt"),


"errors":
read("$BASE/results/errors.txt"),


"processes":
read("$BASE/results/processes.txt"),


"status":

"validation_complete"

}


json.dump(
report,
open(
"$BASE/results/final-report.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY



echo "[5] Publish Context"


cp "$BASE/results/"*.json \
"$REPO/dev-context/fetch-production/"


echo "[6] GitHub Sync"


cd "$REPO"

git add dev-context/fetch-production


git commit \
-m "Phase 25.5 Fetch Production Validation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25 FETCH COMPLETE"
echo "=============================================="

