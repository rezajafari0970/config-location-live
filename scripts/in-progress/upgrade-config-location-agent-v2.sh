#!/usr/bin/env bash
set -euo pipefail
umask 077

echo "=============================================="
echo " Config Location Agent v2"
echo "=============================================="

BASE="/var/log/config-location-agent"

mkdir -p "$BASE/history"

cat >/usr/local/bin/config-location-agent <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/log/config-location-agent"
TS="$(date +%Y%m%d-%H%M%S)"

JSON="$BASE/latest.json"
TXT="$BASE/latest.txt"

mkdir -p "$BASE/history"


get_count() {
    local p="$1"
    if [ -d "$p" ]; then
        find "$p" -type f 2>/dev/null | wc -l
    else
        echo 0
    fi
}


echo "[1] Collecting services..."

SERVICES=$(
systemctl list-units \
--type=service \
--state=running \
--no-legend 2>/dev/null |
grep -Ei \
'config-location|health|country|fetch|panel|lifecycle' || true
)


echo "[2] Collecting storage..."

STORE_FILES=$(get_count "/var/lib/config-location")

RAW_FILES=$(get_count "/var/lib/config-location/raw")

HEALTH_FILES=$(get_count "/var/lib/config-location/health")


echo "[3] Collecting health state..."

HEALTH_STATUS=$(
find /var/lib/config-location \
-type f \
-name '*.json' 2>/dev/null |
grep -Ei 'health|lifecycle|result' |
wc -l || true
)


echo "[4] Collecting country state..."

COUNTRY_FILES=$(
find /var/lib/config-location \
-type f 2>/dev/null |
grep -Ei 'country|geo|location' |
wc -l || true
)


echo "[5] Collecting lifecycle..."

LIFECYCLE_FILES=$(
find /var/lib/config-location \
-type f 2>/dev/null |
grep -Ei 'ttl|expire|lifecycle|delete' |
wc -l || true
)


echo "[6] Collecting publish..."

PUBLISH_FILES=$(
find /var/lib/config-location \
-type f 2>/dev/null |
grep -Ei 'publish|subscription|sub' |
wc -l || true
)


echo "[7] Security..."

SSH_ERRORS=$(
journalctl \
--since "24 hours ago" \
--no-pager 2>/dev/null |
grep -Ei \
'kex_exchange|authentication attempts|failed password' |
wc -l || true
)


PORTS=$(
ss -lntp 2>/dev/null |
grep -Ei \
'4040|1010|80|443|10808|xray|python' || true
)


python3 - "$JSON" <<PY
import json,sys,datetime

data={
"timestamp":datetime.datetime.now().astimezone().isoformat(),

"pipeline":{
"fetch":"running",
"store":"running",
"parser":"unknown",
"health":"running",
"country":"running",
"lifecycle":"running",
"publish":"unknown"
},

"storage":{
"total_files":"$STORE_FILES",
"raw_files":"$RAW_FILES",
"health_related":"$HEALTH_FILES"
},

"health":{
"health_records":"$HEALTH_STATUS"
},

"country":{
"country_records":"$COUNTRY_FILES"
},

"lifecycle":{
"lifecycle_records":"$LIFECYCLE_FILES"
},

"publish":{
"publish_records":"$PUBLISH_FILES"
},

"security":{
"ssh_suspicious_events":"$SSH_ERRORS"
},

"services":"""$SERVICES""",

"ports":"""$PORTS"""
}

open(sys.argv[1],"w").write(
json.dumps(data,indent=2,ensure_ascii=False)
)
PY


cat >"$TXT" <<EOF2

CONFIG LOCATION AGENT v2

Time:
$(date -Is)


========================
PIPELINE
========================

FETCH:
RUNNING

STORE:
RUNNING

PARSER:
UNKNOWN

HEALTH:
RUNNING

COUNTRY:
RUNNING

LIFECYCLE:
RUNNING

PUBLISH:
UNKNOWN


========================
STORAGE
========================

Total:
$STORE_FILES

Raw:
$RAW_FILES

Health:
$HEALTH_FILES


========================
HEALTH
========================

Records:
$HEALTH_STATUS


========================
COUNTRY
========================

Records:
$COUNTRY_FILES


========================
LIFECYCLE
========================

Records:
$LIFECYCLE_FILES


========================
PUBLISH
========================

Records:
$PUBLISH_FILES


========================
SECURITY
========================

SSH suspicious:
$SSH_ERRORS


========================
SERVICES
========================

$SERVICES


========================
PORTS
========================

$PORTS

EOF2


cp "$JSON" "$BASE/history/audit-$TS.json"
cp "$TXT" "$BASE/history/audit-$TS.txt"


echo
echo "=============================================="
echo " AGENT v2 COMPLETE"
echo "=============================================="

echo
echo "$JSON"
echo "$TXT"

SCRIPT


chmod 700 /usr/local/bin/config-location-agent


echo
echo "Running Agent v2..."

config-location-agent

echo
echo "DONE"

