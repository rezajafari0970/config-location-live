#!/bin/bash

set -Eeuo pipefail

ROOT="/root/only-source-code-final"
PROJECT="/opt/config-location"

OUT="$ROOT/ultimate-project-intelligence"

rm -rf "$OUT"

mkdir -p \
"$OUT"/{architecture,code-index,call-map,storage-model,state-machine,service-map,failure-analysis,security,performance,testing,upgrade,restore}


echo "===== ULTIMATE PROJECT INTELLIGENCE ====="


################################
# ARCHITECTURE
################################

tree -a -L 7 "$PROJECT" \
> "$OUT/architecture/full-tree.txt" 2>/dev/null || true


find "$PROJECT/app" -maxdepth 2 -type d \
> "$OUT/architecture/modules.txt"


################################
# CODE INDEX
################################

find "$PROJECT" \
-type f \
-name "*.py" \
-not -path "*/venv/*" \
> "$OUT/code-index/python-files.txt"


grep -R "^class \|^def " \
"$PROJECT/app" \
> "$OUT/code-index/classes-functions.txt" \
2>/dev/null || true


################################
# CALL MAP
################################

grep -R "[a-zA-Z_][a-zA-Z0-9_]*(" \
"$PROJECT/app" \
> "$OUT/call-map/function-calls.txt" \
2>/dev/null || true


################################
# STORAGE MODEL
################################

find "$PROJECT" \
-type f \
| grep -Ei "storage|database|model|schema|json" \
> "$OUT/storage-model/storage-files.txt"


cat > "$OUT/storage-model/storage-flow.md" <<TXT
Storage Flow

Input
 |
Parser
 |
Normalizer
 |
Storage
 |
Health
 |
Lifecycle
 |
Publish

TXT


################################
# STATE MACHINE
################################

cat > "$OUT/state-machine/config-state.md" <<TXT
Configuration Lifecycle

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
REMOVED

TXT


################################
# SERVICE MAP
################################

systemctl list-units \
--type=service \
| grep -Ei "config|location|health|country|fetch" \
> "$OUT/service-map/services.txt" || true


for s in $(cat "$OUT/service-map/services.txt" | awk '{print $1}')
do
 echo "===== $s =====" >> "$OUT/service-map/details.txt"
 systemctl cat "$s" >> "$OUT/service-map/details.txt" 2>&1 || true
done


################################
# FAILURE ANALYSIS
################################

cat > "$OUT/failure-analysis/failure-map.md" <<TXT

Failure Analysis

Fetcher failure:
- impact: source collection stops
- recovery: service restart

Parser failure:
- impact: new configs rejected

Storage failure:
- impact: persistence problem

Health failure:
- impact: monitoring degradation

TXT


################################
# SECURITY
################################

find "$PROJECT" \
-type f \
-perm /o+w \
> "$OUT/security/world-writable.txt" 2>/dev/null || true


find "$PROJECT" \
-type f \
| grep -Ei "secret|token|key|password|env" \
> "$OUT/security/sensitive-map.txt" 2>/dev/null || true


################################
# PERFORMANCE
################################

du -sh "$PROJECT" \
> "$OUT/performance/project-size.txt"


find "$PROJECT" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$OUT/performance/largest-files.txt"


################################
# TESTING
################################

find "$PROJECT/tests" \
-type f \
> "$OUT/testing/tests-list.txt" 2>/dev/null || true


grep -R "test_" "$PROJECT/tests" \
> "$OUT/testing/test-functions.txt" 2>/dev/null || true


################################
# UPGRADE
################################

cat > "$OUT/upgrade/upgrade-safety.md" <<TXT

Before modifying:

1. Backup source
2. Run parser tests
3. Check storage impact
4. Check affected services
5. Restart controlled services only

TXT


################################
# RESTORE
################################

cat > "$OUT/restore/restore-playbook.md" <<TXT

Restore Order:

1. OS
2. Dependencies
3. Source
4. Configuration
5. Systemd
6. Runtime
7. Storage
8. Workers
9. Health verification

TXT


################################
# PROJECT BRAIN
################################

cat > "$OUT/PROJECT-BRAIN.md" <<TXT

CONFIG LOCATION PROJECT BRAIN

Purpose:
Configuration collection,
parsing,
validation,
country detection,
health management,
publishing.

Main Components:

- Fetcher
- Parser
- Storage
- Country
- Health
- Lifecycle
- Publish
- Panel

Generated:
$(date)

TXT


################################
# MANIFEST
################################

find "$OUT" -type f \
-print0 \
| sort -z \
| xargs -0 sha256sum \
> "$OUT/manifest.sha256"


################################
# PACK
################################

tar -cf - \
-C "$ROOT" \
ultimate-project-intelligence \
| zstd -10 -T0 \
-o "$ROOT/ultimate-project-intelligence.tar.zst"


sha256sum \
"$ROOT/ultimate-project-intelligence.tar.zst" \
> "$ROOT/ultimate-project-intelligence.tar.zst.sha256"


echo
echo "DONE"
ls -lh "$ROOT/ultimate-project-intelligence.tar.zst"

