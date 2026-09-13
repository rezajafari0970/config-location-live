#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT="/opt/config-location"
BASE="/var/lib/config-location/config-model-integration"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/adapter" \
"$BASE/migration" \
"$BASE/validation" \
"$BASE/schema" \
"$BASE/backup" \
"$REPO/dev-context/config-model-integration"


echo "=============================================="
echo " PHASE 22 CONFIG MODEL INTEGRATION"
echo "=============================================="


echo "[1] Creating pre-change snapshot..."

tar czf \
"$BASE/backup/config-model-before-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$PROJECT" \
2>/dev/null || true



echo "[2] Creating Unified Config Object..."

cat >"$BASE/schema/unified-config.json" <<'JSON'
{
"id":"",

"raw":{

"content":"",
"hash":"",
"source":""

},


"type":"",


"parsed":{},


"runtime":{},


"health":{},


"location":{},


"remark":"",


"lifecycle":{},


"publish":true

}
JSON



echo "[3] Creating Store Adapter..."

cat >"$BASE/adapter/store-adapter.json" <<'JSON'
{
"version":1,

"mode":"compatibility",


"purpose":

"convert existing records to unified config model",


"write_mode":

"disabled_until_validation"

}
JSON



echo "[4] Creating Field Mapping..."

cat >"$BASE/migration/field-mapping.json" <<'JSON'
{
"mapping":{

"url":"raw.content",

"remarks":"remark",

"protocol":"type",

"source":"raw.source"

},


"preserve_unknown_fields":true

}
JSON



echo "[5] Creating Migration Layer..."

cat >"$BASE/migration/migration-policy.json" <<'JSON'
{
"version":1,

"strategy":

"non_destructive",


"steps":[

"read_old_record",

"map_fields",

"validate",

"create_unified_record"

],


"rollback":true

}
JSON



echo "[6] Creating Validation Engine..."

cat >"$BASE/validation/validation-policy.json" <<'JSON'
{
"required":[

"id",

"raw",

"type"

],


"checks":[

"schema",

"hash",

"raw_preservation"

]

}
JSON



echo "[7] Backward Compatibility..."

cat >"$BASE/adapter/compatibility-policy.json" <<'JSON'
{
"old_store":

"active",


"new_model":

"shadow_mode",


"cutover":

"manual_after_validation"

}
JSON



echo "[8] Dev Context..."

python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),


"phase":22,


"module":
"config-model-integration",


"features":[

"store-adapter",

"unified-config-object",

"field-mapping",

"migration-layer",

"validation",

"backward-compatibility"

],


"mode":
"shadow-migration"

}


json.dump(
data,
open(
"$REPO/dev-context/config-model-integration/status.json",
"w"
),
indent=2
)

PY



cp "$BASE/schema/unified-config.json" \
"$REPO/dev-context/config-model-integration/unified-config-schema.json"

cp "$BASE/migration/field-mapping.json" \
"$REPO/dev-context/config-model-integration/field-mapping.json"

cp "$BASE/validation/validation-policy.json" \
"$REPO/dev-context/config-model-integration/validation-policy.json"



echo "[9] GitHub Sync..."

cd "$REPO"

git add dev-context/config-model-integration


git commit \
-m "Phase 22 Config Model Integration Foundation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 22 COMPLETE"
echo "=============================================="

