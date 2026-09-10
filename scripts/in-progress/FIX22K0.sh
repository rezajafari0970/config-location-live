#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
CORE="$R/app/health/core"
COUNTRY="$R/app/country"

echo "======================================================"
echo "FIX22K0 — HEALTH/COUNTRY INTEGRATION CONTRACT AUDIT"
echo "======================================================"

echo
echo "=== 0. J BACKGROUND STATE ==="

X=$(systemctl is-active fix22j-all-background.service 2>/dev/null || true)
echo "FIX22J_BACKGROUND=$X"

test "$X" != active

echo
echo "=== 1. PRESERVED J DATA ==="

find "$R/backups" \
-maxdepth 1 \
-type d \
-name 'FIX22J-PARTIAL-*' \
-printf '%T@ %p\n' 2>/dev/null \
| sort -nr \
| head -n 3 || true

echo
echo "=== 2. HEALTH PIPELINE FILE MAP ==="

find "$R/app/health" \
-type f \
-name '*.py' \
| sort

echo
echo "=== 3. REAL TRANSFER / QUALIFICATION POINTS ==="

grep -RIn \
--include='*.py' \
-B25 -A90 \
-E \
'real_transfer_health|health_qualified|upload|download|uplink|downlink|transfer_health|qualified' \
"$R/app/health" \
| head -n 1800 || true

echo
echo "=== 4. HEALTH RESULT COMMIT / STORAGE ==="

grep -RIn \
--include='*.py' \
-B25 -A100 \
-E \
'health-results|latest|atomic|replace|write_text|json.dump|save.*health|store.*health|result.*path' \
"$R/app/health" \
| head -n 1600 || true

echo
echo "=== 5. RUNTIME OWNERSHIP ==="

grep -RIn \
--include='*.py' \
-B25 -A120 \
-E \
'RuntimeLauncher|launcher.launch|runtime.stop|finally:|proxy_url|socks_port|sandbox|cleanup' \
"$R/app/health" \
| head -n 2200 || true

echo
echo "=== 6. HEALTH SCHEDULER / JOB BOUNDARY ==="

grep -RIn \
--include='*.py' \
-B25 -A120 \
-E \
'run_job|process_job|execute_job|run_health|process_health|worker|scheduler|candidate|config_id' \
"$CORE" \
| head -n 2200 || true

echo
echo "=== 7. HEALTH ADAPTIVE CONTROLLER ==="

for f in \
"$CORE/production_scheduler.py" \
"$CORE/production_adaptive.py" \
"$CORE/continuous_adaptive_runner.py" \
"$CORE/always_on_adaptive.py"
do
    echo
    echo "----- $f -----"
    sed -n '1,520p' "$f" 2>/dev/null || true
done

echo
echo "=== 8. HEALTH SYSTEMD CONTRACT ==="

systemctl cat \
config-location-health-adaptive.service

echo
echo "=== 9. COUNTRY PIPELINE CURRENT CONTRACT ==="

grep -RIn \
--include='*.py' \
-B20 -A100 \
-E \
'process_country|healthy_candidates|run_country_worker_adaptive|confirmed_stable|confirmed_rotating_ip|observe_exit_ip|resolve_geo' \
"$COUNTRY" \
| head -n 2200 || true

echo
echo "=== 10. XRAY LOGGING / WARNING OWNERSHIP ==="

grep -RIn \
--include='*.py' \
-B20 -A100 \
-E \
'loglevel|warning|stderr|stdout|xray.*log|error_log|access_log|Popen|subprocess' \
"$R/app/health" \
"$COUNTRY" \
| head -n 1800 || true

echo
echo "=== 11. RUNTIME OBJECT CONTRACT ==="

sed -n '1,520p' \
"$R/app/health/runtime/launcher.py" \
2>/dev/null || true

echo
echo "=== 12. CURRENT RUNTIME COUNTS ==="

HEALTH_COUNT=$(
    find /var/lib/config-location/health-sandboxes \
    -mindepth 1 -maxdepth 1 -type d \
    ! -name 'country-*' \
    2>/dev/null | wc -l
)

COUNTRY_COUNT=$(
    find /var/lib/config-location/health-sandboxes \
    -mindepth 1 -maxdepth 1 -type d \
    -name 'country-*' \
    2>/dev/null | wc -l
)

echo "HEALTH_RUNTIME_DIRS=$HEALTH_COUNT"
echo "COUNTRY_RUNTIME_DIRS=$COUNTRY_COUNT"

echo
echo "=== 13. CURRENT COUNTRY RESULT DISTRIBUTION ==="

python3 <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path("/var/lib/config-location/country/pipeline/latest")
H=Path("/var/lib/config-location/health-results/latest")

country=Counter()
health=Counter()

for p in P.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        country["corrupt"] += 1
        continue
    country[str(o.get("state","unknown"))] += 1

for p in H.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        health["corrupt"] += 1
        continue
    health[str(o.get("state","unknown"))] += 1

print("HEALTH=",dict(health))
print("COUNTRY=",dict(country))
PY

echo
echo "=== 14. CORE SERVICES ==="

for svc in \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "=== 15. SAFETY FREEZE ==="

python3 <<'PY'
from pathlib import Path
import json

p=Path(
    "/var/lib/config-location/"
    "country/worker-safety.json"
)

o=json.loads(p.read_text())

print(json.dumps(o,indent=2))

assert o["publication_enabled"] is False
assert o["remark_mutation_enabled"] is False
assert o["subscription_mutation_enabled"] is False
assert o["source_raw_mutation_enabled"] is False

print("SAFETY_FREEZE=PASS")
PY

echo
echo "======================================================"
echo "FIX22K0=PASS"
echo "HEALTH_PASS_BOUNDARY=AUDITED"
echo "UPLOAD_DOWNLOAD_BOUNDARY=AUDITED"
echo "RUNTIME_OWNERSHIP=AUDITED"
echo "RUNTIME_CLEANUP=AUDITED"
echo "HEALTH_COMMIT_POINT=AUDITED"
echo "ADAPTIVE_CONTROLLER=AUDITED"
echo "XRAY_WARNING_BOUNDARY=AUDITED"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K1"
echo "======================================================"
