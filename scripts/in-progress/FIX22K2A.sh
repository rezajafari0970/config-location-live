#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
F="$R/app/health/core/engine.py"
PY="$R/venv/bin/python"

echo "=== 1. ENGINE EXACT HEALTH/RUNTIME WINDOW ==="

grep -n \
-B80 -A120 \
-E \
'apply_health_decision|runtime.stop\(\)|proxy_url|runtime =|launcher|download_verified|upload_verified' \
"$F" \
| tail -n 700

echo
echo "=== 2. FUNCTION MAP ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/health/core/engine.py"
)

s=p.read_text()
t=ast.parse(s)

for n in t.body:
    if isinstance(
        n,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):
        text=ast.get_source_segment(
            s,n
        ) or ""

        if (
            "apply_health_decision"
            in text
            and "runtime.stop"
            in text
        ):
            print(
                "TARGET_FUNCTION=",
                n.name,
            )
            print(
                "LINES=",
                n.lineno,
                n.end_lineno,
            )

            Path(
                "/tmp/FIX22K2-target.txt"
            ).write_text(
                f"{n.name}\n"
                f"{n.lineno}\n"
                f"{n.end_lineno}\n"
            )
PY

test -s /tmp/FIX22K2-target.txt

echo
echo "=== 3. RUNTIME OBJECT CONTRACT ==="

grep -RIn \
--include='*.py' \
-B20 -A100 \
-E \
'class .*Runtime|proxy_url|socks_port|def stop\(' \
"$R/app/health/runtime" \
| head -n 1200

echo
echo "=== 4. EXISTING COUNTRY EXIT PROBES ==="

grep -RIn \
--include='*.py' \
-B25 -A100 \
-E \
'observe_exit_ip|proxy_url|socks5h|checkip|exit_ip|probe.*exit' \
"$R/app/country" \
| head -n 1800

echo
echo "=== 5. COUNTRY RESULT SAVE API ==="

grep -RIn \
--include='*.py' \
-B25 -A100 \
-E \
'save_country_result|save.*country|confirmed_stable|pending_confirmation|process_country' \
"$R/app/country" \
| head -n 1600

echo
echo "=== 6. K1 QUEUE CURRENT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY

echo
echo "=== 7. SERVICES ==="

for svc in \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-fetcher.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "========================================"
echo "FIX22K2A=PASS"
echo "MODE=SAME-RUNTIME-CONTRACT-PIN"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K2B"
echo "========================================"
