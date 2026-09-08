#!/usr/bin/env bash
set -euo pipefail
umask 077

echo "======================================"
echo " Installing Config Location Agent v1"
echo "======================================"

mkdir -p \
/var/log/config-location-agent/history

cat >/usr/local/bin/config-location-agent <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
umask 077

OUT="/var/log/config-location-agent"
TS="$(date +%Y%m%d-%H%M%S)"

JSON="$OUT/latest.json"
TXT="$OUT/latest.txt"

mkdir -p "$OUT/history"

echo "Running audit..."

SERVICES=$(systemctl list-units \
--type=service \
--state=running \
--no-legend 2>/dev/null | \
grep -Ei 'config|health|country|fetch|panel|xray' || true)

PORTS=$(ss -lntp 2>/dev/null | \
grep -Ei '4040|1010|80|443|xray|python' || true)

PROCESSES=$(ps aux | \
grep -Ei 'config|health|country|fetch|xray' | \
grep -v grep || true)

ERRORS=$(journalctl \
--since "24 hours ago" \
-p warning \
--no-pager 2>/dev/null | \
grep -Ei 'config|health|country|fetch|xray|error|fail' \
| tail -100 || true)

CONFIG_DIR="/var/lib/config-location"

COUNT=0
if [ -d "$CONFIG_DIR" ]; then
COUNT=$(find "$CONFIG_DIR" -type f 2>/dev/null | wc -l)
fi

cat >"$JSON" <<EOFJSON
{
 "timestamp":"$(date -Is)",
 "hostname":"$(hostname)",
 "config_files":"$COUNT",
 "services":$(python3 - <<PY
import json
print(json.dumps("""$SERVICES"""))
PY
),
 "ports":$(python3 - <<PY
import json
print(json.dumps("""$PORTS"""))
PY
),
 "processes":$(python3 - <<PY
import json
print(json.dumps("""$PROCESSES"""))
PY
),
 "errors":$(python3 - <<PY
import json
print(json.dumps("""$ERRORS"""))
PY
)
}
EOFJSON


cat >"$TXT" <<EOFTXT
CONFIG LOCATION AUDIT

Time:
$(date -Is)

Config Files:
$COUNT

====================
SERVICES
====================
$SERVICES

====================
PORTS
====================
$PORTS

====================
PROCESSES
====================
$PROCESSES

====================
ERRORS
====================
$ERRORS

EOFTXT


cp "$JSON" "$OUT/history/audit-$TS.json"
cp "$TXT" "$OUT/history/audit-$TS.txt"

echo "======================================"
echo " AUDIT COMPLETE"
echo "======================================"

echo
echo "JSON:"
echo "$JSON"

echo
echo "TEXT:"
echo "$TXT"
SCRIPT

chmod 700 /usr/local/bin/config-location-agent

echo
echo "Running first audit..."
config-location-agent

echo
echo "DONE"
