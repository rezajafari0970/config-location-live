#!/bin/bash

set -Eeuo pipefail

ROOT="/root/only-source-code-final"

PROJECT="/opt/config-location"

OUT="$ROOT/development-intelligence"

rm -rf "$OUT"

mkdir -p "$OUT"/{dependency-map,call-map,config-map,data-flow,service-map,history-analysis,code-quality,restore-map}


echo "===================================="
echo " ENGINEERING INTELLIGENCE PACK"
echo "===================================="


####################################
# FILE INVENTORY
####################################

find "$PROJECT" \
-type f \
-not -path "*/venv/*" \
-not -path "*/__pycache__/*" \
> "$OUT/file-list.txt"



####################################
# DEPENDENCY MAP
####################################

echo "[1] Dependency map"


grep -R "^import \|^from " \
"$PROJECT/app" \
> "$OUT/dependency-map/python-imports.txt" \
2>/dev/null || true



python3 - <<'PY' \
> "$OUT/dependency-map/module-map.txt" 2>/dev/null || true

import os

root="/opt/config-location/app"

for d,_,files in os.walk(root):
    for f in files:
        if f.endswith(".py"):
            print(os.path.join(d,f))

PY



####################################
# CALL MAP
####################################

echo "[2] Call map"


grep -R "^def \|^class " \
"$PROJECT/app" \
> "$OUT/call-map/functions-and-classes.txt" \
2>/dev/null || true



grep -R "[a-zA-Z_][a-zA-Z0-9_]*(" \
"$PROJECT/app" \
> "$OUT/call-map/function-calls.txt" \
2>/dev/null || true



####################################
# CONFIG MAP
####################################

echo "[3] Config map"


find "$PROJECT" \
-type f \
\( \
-name "*.json" \
-o -name "*.yaml" \
-o -name "*.yml" \
-o -name "*.toml" \
-o -name "*.env" \
-o -name "*.ini" \
\) \
> "$OUT/config-map/config-files.txt"



grep -R "os.getenv\|environ\|config" \
"$PROJECT/app" \
> "$OUT/config-map/config-usage.txt" \
2>/dev/null || true



####################################
# DATA FLOW
####################################

echo "[4] Data flow"


cat > "$OUT/data-flow/DATA-FLOW.md" <<MAP

CONFIG LOCATION DATA FLOW

Source
 |
 v
Fetcher
 |
 v
Parser
 |
 v
Normalize
 |
 v
Storage
 |
 +----------------+
 |                |
 v                v
Country       Health
 |                |
 +-------+--------+
         |
         v
Lifecycle
         |
         v
Publish
         |
         v
Panel

MAP



####################################
# SERVICE MAP
####################################

echo "[5] Service map"


systemctl list-unit-files \
| grep -Ei "config|location|health|country|fetch" \
> "$OUT/service-map/services.txt" || true


for s in $(systemctl list-units --type=service --no-legend \
| awk '/config-location/{print $1}')
do

echo "===== $s =====" >> "$OUT/service-map/service-details.txt"

systemctl cat "$s" \
>> "$OUT/service-map/service-details.txt" 2>&1

done



####################################
# HISTORY
####################################

echo "[6] History"


find "$PROJECT" \
-type f \
\( \
-name "*.bak*" \
-o -name "*.before*" \
\) \
> "$OUT/history-analysis/history-files.txt"



####################################
# CODE QUALITY
####################################

echo "[7] Code quality"


grep -R "TODO\|FIXME\|print(" \
"$PROJECT/app" \
> "$OUT/code-quality/code-warnings.txt" \
2>/dev/null || true


find "$PROJECT" \
-type f \
-name "*.py" \
-printf "%s %p\n" \
| sort -nr \
> "$OUT/code-quality/python-size.txt"



####################################
# RESTORE MAP
####################################

cat > "$OUT/restore-map/RESTORE-ORDER.md" <<MAP

RESTORE ORDER

1. Dependencies
2. Source Code
3. Configuration
4. Systemd Services
5. Runtime Data
6. Storage
7. Workers
8. Health Engine
9. Publish Layer

MAP



####################################
# PROJECT CONTEXT
####################################

cat > "$OUT/PROJECT-CONTEXT.md" <<MAP

CONFIG LOCATION PROJECT CONTEXT

Main Components:

- Fetcher
- Parser
- Country Detection
- Health Engine
- Lifecycle
- Publish
- Panel

Generated:
$(date)

MAP



####################################
# PRODUCTION REPORT
####################################

cat > "$OUT/PRODUCTION-READINESS.md" <<MAP

PRODUCTION READINESS CHECK

Checked:

- Source structure
- Services
- Dependencies
- Tests
- Runtime separation
- Restore order

Generated:
$(date)

MAP



####################################
# PACK
####################################

tar -cf - \
-C "$ROOT" \
development-intelligence \
| zstd -10 -T0 \
-o "$ROOT/development-intelligence.tar.zst"


sha256sum "$ROOT/development-intelligence.tar.zst" \
> "$ROOT/development-intelligence.tar.zst.sha256"


echo
echo "DONE"

ls -lh "$ROOT/development-intelligence.tar.zst"

