#!/bin/bash

set -Eeuo pipefail

ROOT="/root/only-source-code-final"

PROJECT="/opt/config-location"

OUT="$ROOT/project-brain-v3"

rm -rf "$OUT"

mkdir -p \
"$OUT"/{code-metrics,dependency-graph,impact-analysis,runtime-map,data-contracts,state-machine,risk-analysis,security-intelligence,test-intelligence,deployment-simulator,upgrade-matrix,docs}


echo "===== PROJECT BRAIN V3 ====="


################################
# CODE METRICS
################################

echo "[1] Code metrics"

find "$PROJECT" \
-name "*.py" \
-not -path "*/venv/*" \
-exec wc -l {} \; \
| sort -nr \
> "$OUT/code-metrics/python-lines.txt"


grep -R "^class \|^def " \
"$PROJECT/app" \
> "$OUT/code-metrics/symbols.txt" 2>/dev/null || true



################################
# DEPENDENCY GRAPH
################################

echo "[2] Dependency graph"

grep -R "^import \|^from " \
"$PROJECT/app" \
> "$OUT/dependency-graph/import-map.txt" 2>/dev/null || true


cat > "$OUT/dependency-graph/architecture-flow.md" <<MAP

Fetcher
  |
  v
Parser
  |
  v
Normalizer
  |
  v
Storage
  |
  +------ Country
  |
  +------ Health
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



################################
# IMPACT ANALYSIS
################################

echo "[3] Impact"

for M in \
parser \
storage \
health \
country \
publish \
panel \
fetcher

do

echo "===== $M =====" >> "$OUT/impact-analysis/module-impact.txt"

grep -R "$M" \
"$PROJECT/app" \
>> "$OUT/impact-analysis/module-impact.txt" 2>/dev/null || true

done



################################
# RUNTIME MAP
################################

echo "[4] Runtime"

find "$PROJECT" \
-type f \
| grep -Ei \
"worker|daemon|scheduler|consumer|runner" \
> "$OUT/runtime-map/workers.txt"


systemctl list-units \
--type=service \
| grep -Ei \
"config|location|health|country|fetch" \
> "$OUT/runtime-map/services.txt" || true



################################
# DATA CONTRACT
################################

echo "[5] Data contracts"

find "$PROJECT" \
-type f \
\( \
-name "*.json" \
-o -name "*.yaml" \
-o -name "*.yml" \
-o -name "*.toml" \
\) \
> "$OUT/data-contracts/config-files.txt"


cat > "$OUT/data-contracts/data-flow.md" <<MAP

Input
 |
Fetcher
 |
Parser
 |
Validation
 |
Storage
 |
Health
 |
Publish

MAP



################################
# STATE MACHINE
################################

cat > "$OUT/state-machine/config-lifecycle.md" <<MAP

NEW
 |
FETCHED
 |
PARSED
 |
VALIDATED
 |
ACTIVE
 |
FAILED
 |
EXPIRED
 |
REMOVED

MAP



################################
# RISK ANALYSIS
################################

echo "[6] Risk"

find "$PROJECT" \
-name "*.py" \
-printf "%s %p\n" \
| sort -nr \
> "$OUT/risk-analysis/largest-python-files.txt"


grep -R \
"TODO\|FIXME\|except Exception" \
"$PROJECT" \
> "$OUT/risk-analysis/warnings.txt" 2>/dev/null || true



################################
# SECURITY
################################

echo "[7] Security"

find "$PROJECT" \
-type f \
-perm /o+w \
> "$OUT/security-intelligence/world-writable.txt" 2>/dev/null || true


grep -R \
"password\|secret\|token\|api_key" \
"$PROJECT" \
> "$OUT/security-intelligence/sensitive-patterns.txt" 2>/dev/null || true



################################
# TEST INTELLIGENCE
################################

find "$PROJECT/tests" \
-type f \
> "$OUT/test-intelligence/tests.txt" 2>/dev/null || true



################################
# DEPLOYMENT
################################

cat > "$OUT/deployment-simulator/DEPLOYMENT.md" <<MAP

Fresh Server:

1. Install dependencies
2. Deploy source
3. Configure environment
4. Install systemd
5. Start workers
6. Verify health
7. Verify publish

MAP



################################
# UPGRADE MATRIX
################################

cat > "$OUT/upgrade-matrix/UPGRADE.md" <<MAP

Module Impact:

Parser:
- Validation
- Storage
- Tests

Storage:
- All workers

Health:
- Runtime
- Lifecycle

Panel:
- API
- UI

Country:
- Remark
- Publish

MAP



################################
# PROJECT BRAIN
################################

cat > "$OUT/PROJECT-BRAIN.md" <<MAP

CONFIG LOCATION PROJECT BRAIN V3

Main Architecture:

Fetcher
Parser
Storage
Country
Health
Lifecycle
Publish
Panel

Development Rules:

- Backup before change
- Test affected module
- Check service impact
- Verify restore path

Generated:
$(date)

MAP



################################
# PACK
################################

tar -cf - \
-C "$ROOT" \
project-brain-v3 \
| zstd -10 -T0 \
-o "$ROOT/project-brain-v3.tar.zst"


sha256sum \
"$ROOT/project-brain-v3.tar.zst" \
> "$ROOT/project-brain-v3.tar.zst.sha256"


echo
echo "DONE"

ls -lh "$ROOT/project-brain-v3.tar.zst"

