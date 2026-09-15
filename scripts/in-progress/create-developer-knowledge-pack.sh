#!/bin/bash

set -Eeuo pipefail

ROOT="/root/only-source-code-final"
PROJECT="/opt/config-location"
OUT="$ROOT/developer-knowledge-pack"

rm -rf "$OUT"

mkdir -p \
"$OUT"/{architecture,dependency,data-model,error-map,deployment,developer-context,manifest}


echo "===== DEVELOPER KNOWLEDGE PACK ====="


####################################
# ARCHITECTURE
####################################

cat > "$OUT/architecture/architecture-map.md" <<MAP
# CONFIG LOCATION ARCHITECTURE

## Main Flow

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
  +------------+
  |            |
  v            v
Country     Health
  |            |
  +------------+
       |
       v
Lifecycle
       |
       v
Publish
       |
       v
Panel


Generated:
$(date)

MAP


find "$PROJECT/app" -maxdepth 2 -type d \
> "$OUT/architecture/modules.txt"



####################################
# DEPENDENCY
####################################

echo "[1] Dependency"

grep -R "^import \|^from " \
"$PROJECT/app" \
> "$OUT/dependency/import-map.txt" \
2>/dev/null || true


grep -R "^class \|^def " \
"$PROJECT/app" \
> "$OUT/dependency/code-symbols.txt" \
2>/dev/null || true



####################################
# DATA MODEL
####################################

echo "[2] Data model"

find "$PROJECT" \
-type f \
\( \
-name "*.json" \
-o -name "*.yaml" \
-o -name "*.yml" \
-o -name "*.schema*" \
\) \
> "$OUT/data-model/data-files.txt"


grep -R "model\|schema\|dataclass\|pydantic" \
"$PROJECT/app" \
> "$OUT/data-model/model-map.txt" \
2>/dev/null || true



####################################
# ERROR MAP
####################################

echo "[3] Error map"

grep -R \
"except \|raise \|Exception\|Error" \
"$PROJECT/app" \
> "$OUT/error-map/error-handling.txt" \
2>/dev/null || true


grep -R \
"logger\.error\|logging\.error" \
"$PROJECT/app" \
> "$OUT/error-map/error-logs.txt" \
2>/dev/null || true



####################################
# DEPLOYMENT
####################################

echo "[4] Deployment"

find "$PROJECT/installer" \
-type f \
> "$OUT/deployment/installer-files.txt" \
2>/dev/null || true


systemctl list-units --type=service \
| grep -Ei "config|location|health|country|fetch" \
> "$OUT/deployment/services.txt" || true



cat > "$OUT/deployment/deployment-guide.md" <<MAP
# Deployment Guide

Order:

1. Dependencies
2. Source
3. Configuration
4. Systemd
5. Runtime
6. Workers
7. Health
8. Publish

Generated:
$(date)

MAP



####################################
# DEVELOPER CONTEXT
####################################

cat > "$OUT/developer-context/DEVELOPER-START.md" <<MAP
# Developer Start

Project:
Config Location

Main Areas:

- Fetcher
- Parser
- Storage
- Country Detection
- Health Engine
- Lifecycle
- Publish
- Panel

Before changing code:

1. Check dependencies
2. Check affected services
3. Check storage impact
4. Run tests

Generated:
$(date)

MAP



####################################
# MANIFEST
####################################

find "$PROJECT" \
-type f \
-not -path "*/venv/*" \
-not -path "*/__pycache__/*" \
-print0 \
| sort -z \
| xargs -0 sha256sum \
> "$OUT/manifest/source-sha256.txt"


find "$PROJECT" \
-type f \
| wc -l \
> "$OUT/manifest/file-count.txt"


du -sh "$PROJECT" \
> "$OUT/manifest/project-size.txt"



####################################
# PACK
####################################

tar -cf - \
-C "$ROOT" \
developer-knowledge-pack \
| zstd -10 -T0 \
-o "$ROOT/developer-knowledge-pack.tar.zst"


sha256sum \
"$ROOT/developer-knowledge-pack.tar.zst" \
> "$ROOT/developer-knowledge-pack.tar.zst.sha256"


echo
echo "DONE"

ls -lh "$ROOT/developer-knowledge-pack.tar.zst"

