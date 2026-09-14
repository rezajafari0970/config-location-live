#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

echo "=== 1. ALL XRAY PROCESS CREATION ==="

grep -RIn \
--include='*.py' \
-E \
'subprocess\.(run|Popen|check_output|check_call)|Popen\(' \
"$R/app" \
| grep -Ei \
'xray|runtime|health|runner' \
| head -n 500


echo
echo "=== 2. DIRECT XRAY COMMAND REFERENCES ==="

grep -RIn \
--include='*.py' \
-E \
'(/usr/(local/)?bin/xray|XRAY_BIN|xray.*-c|xray.*run|["'\'']xray["'\''])' \
"$R/app" \
| head -n 500


echo
echo "=== 3. HEALTH EXECUTION REFERENCES ==="

grep -RIn \
--include='*.py' \
-E \
'real_transfer_health|launch|runtime_path|runtime_file|stderr|stdout|returncode|communicate' \
"$R/app/health" \
"$R/app" \
2>/dev/null \
| head -n 1000


echo
echo "=== 4. LIKELY EXECUTOR FILES ==="

find "$R/app" \
-type f \
-name '*.py' \
-print0 |
xargs -0 grep -IlE \
'subprocess|Popen|xray' |
sort


echo
echo "=== 5. SOURCE WINDOWS AROUND PROCESS START ==="

python3 <<'PY'
from pathlib import Path
import re

root=Path("/opt/config-location/app")

patterns=[
    re.compile(r"subprocess\.(?:run|Popen|check_output|check_call)"),
    re.compile(r"\bPopen\s*\("),
]

for p in root.rglob("*.py"):

    try:
        lines=p.read_text(
            errors="replace"
        ).splitlines()
    except Exception:
        continue

    hits=[]

    for i,line in enumerate(lines):

        if any(
            pattern.search(line)
            for pattern in patterns
        ):
            hits.append(i)

    if not hits:
        continue

    print()
    print(
        "########################################"
    )
    print(
        "FILE=",
        p
    )
    print(
        "########################################"
    )

    for i in hits:

        start=max(
            0,
            i-25
        )

        end=min(
            len(lines),
            i+45
        )

        print(
            f"--- WINDOW {start+1}-{end} ---"
        )

        for n in range(
            start,
            end
        ):
            print(
                f"{n+1:05d}: "
                f"{lines[n]}"
            )
PY


echo
echo "=== 6. CURRENT SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"
    test "$X" = active
done


echo
echo "======================================================"
echo "POSTK_XRAY_CALLSITE_PIN=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=XRAY-RETENTION-INTEGRATION"
echo "======================================================"
