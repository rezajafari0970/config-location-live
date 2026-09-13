#!/bin/bash

set -Eeuo pipefail

ROOT="/root/only-source-code-final"
PROJECT="/opt/config-location"

OUT="$ROOT/ultimate-engineering-intelligence"

rm -rf "$OUT"

mkdir -p \
"$OUT"/{code-intelligence/file-cards,dependency-graph,api-contract,config-intelligence,runtime-behavior,failure-analysis,performance-profile,security-audit,test-intelligence,change-guide,project-memory,deployment-playbook}


echo "===== ULTIMATE ENGINEERING INTELLIGENCE V2 ====="


#################################
# CODE INTELLIGENCE
#################################

echo "[1] Code intelligence"


find "$PROJECT" \
-type f \
-name "*.py" \
-not -path "*/venv/*" \
> "$OUT/code-intelligence/python-files.txt"


grep -R "^class \|^def " \
"$PROJECT" \
> "$OUT/code-intelligence/classes-functions.txt" 2>/dev/null || true


while read -r FILE
do

NAME=$(echo "$FILE" | sed 's#/#_#g')

{
echo "=============================="
echo "FILE:"
echo "$FILE"
echo

echo "SIZE:"
wc -l "$FILE"

echo

echo "IMPORTS:"
grep "^import \|^from " "$FILE" || true

echo

echo "SYMBOLS:"
grep "^class \|^def " "$FILE" || true

} > "$OUT/code-intelligence/file-cards/$NAME.txt"

done < "$OUT/code-intelligence/python-files.txt"



#################################
# DEPENDENCY GRAPH
#################################

echo "[2] Dependency graph"


grep -R "^import \|^from " \
"$PROJECT/app" \
> "$OUT/dependency-graph/python-import-graph.txt" 2>/dev/null || true


cat > "$OUT/dependency-graph/dependency-map.md" <<MAP

Fetcher
 |
Parser
 |
Storage
 |
Country
 |
Health
 |
Lifecycle
 |
Publish
 |
Panel

MAP



#################################
# API
#################################

echo "[3] API"


grep -R \
"@app\.|router\.|route|FastAPI|Flask" \
"$PROJECT" \
> "$OUT/api-contract/api-map.txt" 2>/dev/null || true



#################################
# CONFIG
#################################

echo "[4] Config"


grep -R \
"os.getenv\|environ\|config\|settings" \
"$PROJECT/app" \
> "$OUT/config-intelligence/config-usage-map.txt" 2>/dev/null || true



#################################
# RUNTIME
#################################

echo "[5] Runtime"


find "$PROJECT" \
-type f \
| grep -Ei \
"worker|daemon|scheduler|consumer|runner" \
> "$OUT/runtime-behavior/workers.txt"


ps aux \
> "$OUT/runtime-behavior/process-map.txt"



#################################
# FAILURE
#################################

cat > "$OUT/failure-analysis/failure-scenarios.md" <<MAP

Failure Scenarios

Fetcher:
- Source unavailable
- Retry required

Parser:
- Invalid input
- Validation failure

Storage:
- Write failure
- Lock conflict

Health:
- Xray failure
- Network failure

Publish:
- Output generation failure

MAP



#################################
# PERFORMANCE
#################################

echo "[6] Performance"


find "$PROJECT" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$OUT/performance-profile/largest-files.txt"


find "$PROJECT" \
-name "*.py" \
-exec wc -l {} \; \
| sort -nr \
> "$OUT/performance-profile/line-count.txt"


du -h --max-depth=2 "$PROJECT" \
> "$OUT/performance-profile/module-size.txt"



#################################
# SECURITY
#################################

echo "[7] Security"


find "$PROJECT" \
-type f \
-perm /o+w \
> "$OUT/security-audit/world-writable.txt"


find "$PROJECT" \
-type f \
| grep -Ei \
"secret|token|password|key|env" \
> "$OUT/security-audit/sensitive-map.txt" || true



#################################
# TESTS
#################################

find "$PROJECT/tests" \
-type f \
> "$OUT/test-intelligence/tests-map.txt" 2>/dev/null || true



#################################
# GUIDES
#################################

cat > "$OUT/change-guide/SAFE-CHANGE-RULES.md" <<MAP

Safe Change Rules

1. Backup before modifying.
2. Run related tests.
3. Check affected services.
4. Verify storage compatibility.
5. Deploy gradually.

MAP


cat > "$OUT/project-memory/PROJECT-MEMORY.md" <<MAP

CONFIG LOCATION

Main modules:

- Fetcher
- Parser
- Storage
- Country
- Health
- Lifecycle
- Publish
- Panel

Purpose:
Collect, validate, classify and publish configurations.

MAP


cat > "$OUT/deployment-playbook/RESTORE-DEPLOY.md" <<MAP

Restore Order:

1. Dependencies
2. Source
3. Config
4. Systemd
5. Runtime
6. Workers
7. Health verification

MAP



#################################
# PACK
#################################

tar -cf - \
-C "$ROOT" \
ultimate-engineering-intelligence \
| zstd -10 -T0 \
-o "$ROOT/ultimate-engineering-intelligence.tar.zst"


sha256sum \
"$ROOT/ultimate-engineering-intelligence.tar.zst" \
> "$ROOT/ultimate-engineering-intelligence.tar.zst.sha256"


echo
echo "DONE"

ls -lh "$ROOT/ultimate-engineering-intelligence.tar.zst"

