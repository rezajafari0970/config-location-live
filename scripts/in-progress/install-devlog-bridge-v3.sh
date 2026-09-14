#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/devlog-bridge"
REPO="/var/lib/config-location/devlog-github/repo"

echo "=========================================="
echo " Config Location DevLog Bridge v3"
echo "=========================================="

mkdir -p \
"$BASE/live" \
"$BASE/logs" \
"$BASE/errors" \
"$BASE/tests" \
"$REPO/audit/history"


cat > /usr/local/bin/config-location-devlog-collector <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/devlog-bridge"

while true
do

TS="$(date -Is)"

SERVICES=$(systemctl list-units \
--type=service \
--state=running \
--no-legend 2>/dev/null |
grep -Ei "config-location|health|country|fetch|lifecycle|panel" || true)


ERRORS=$(journalctl \
--since "5 minutes ago" \
--no-pager 2>/dev/null |
grep -Ei "error|fail|exception|timeout|killed" |
tail -50 || true)


PORTS=$(ss -lntp 2>/dev/null |
grep -Ei "4040|1010|80|443|10808|xray|python" || true)


CONFIG_COUNT=$(find /var/lib/config-location \
-type f 2>/dev/null | wc -l || true)


python3 <<PY
import json
from datetime import datetime

data={
"time":"$TS",

"project":{
"name":"Config Location",
"config_files":"$CONFIG_COUNT"
},

"services":"""$SERVICES""",

"errors":"""$ERRORS""",

"ports":"""$PORTS"""
}

open(
"$BASE/live/state.json",
"w"
).write(
json.dumps(data,indent=2,ensure_ascii=False)
)
PY


cp "$BASE/live/state.json" \
"$BASE/live/latest.json"


sleep 2

done
SCRIPT


chmod 700 /usr/local/bin/config-location-devlog-collector


cat >/etc/systemd/system/config-location-devlog-collector.service <<EOF
[Unit]
Description=Config Location DevLog Live Collector
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/config-location-devlog-collector
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
