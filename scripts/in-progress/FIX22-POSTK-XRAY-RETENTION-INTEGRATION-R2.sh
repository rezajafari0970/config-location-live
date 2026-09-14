#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

SBOX=/var/lib/config-location/health-sandboxes
FAIL=/var/log/config-location/xray/failures

echo "=== 1. CLEAN POSSIBLE LEAK FROM PREVIOUS SYNTHETIC TEST ==="

find "$SBOX" \
  -mindepth 1 \
  -maxdepth 1 \
  -type d \
  -name 'postk-retention-validation-test-*' \
  -print |
while read -r D
do
    echo "FOUND=$D"

    PIDFILE="$D/xray.pid"

    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE" 2>/dev/null || true)

        if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
            CMD=$(tr '\0' ' ' <"/proc/$PID/cmdline" 2>/dev/null || true)

            echo "PID=$PID"
            echo "CMD=$CMD"

            if echo "$CMD" | grep -q '/usr/local/bin/xray'; then
                kill -TERM "$PID" 2>/dev/null || true
                sleep 1

                if kill -0 "$PID" 2>/dev/null; then
                    kill -KILL "$PID" 2>/dev/null || true
                fi
            fi
        fi
    fi

    rm -rf -- "$D"
done

echo "OLD_TEST_SANDBOX_CLEANUP=PASS"


echo
echo "=== 2. VERIFY PATCH STILL PRESENT ==="

grep -q \
'FIX22_POSTK_XRAY_FORENSIC_RETENTION' \
"$R/app/health/runtime/launcher.py"

"$PY" -m py_compile \
"$R/app/health/runtime/launcher.py"

"$PY" -m py_compile \
"$R/app/xray_log_retention.py"

echo "PATCH_AND_COMPILE=PASS"


echo
echo "=== 3. COUNT FAILURE BUNDLES BEFORE ==="

BEFORE=$(
    find "$FAIL" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      2>/dev/null |
    wc -l
)

echo "FAILURES_BEFORE=$BEFORE"

export BEFORE


echo
echo "=== 4. DETERMINISTIC VALIDATION FAILURE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import subprocess

import app.health.runtime.launcher as launcher_module

from app.health.runtime.launcher import (
    RuntimeLauncher,
    RuntimeLaunchError,
)

real_run=launcher_module.subprocess.run


def fake_validation_run(*args, **kwargs):

    cmd=args[0] if args else kwargs.get("args")

    print(
        "INTERCEPTED_VALIDATION_COMMAND=",
        cmd,
    )

    return subprocess.CompletedProcess(
        args=cmd,
        returncode=23,
        stdout="synthetic validation stdout",
        stderr=(
            "synthetic xray validation failure "
            "for retention test"
        ),
    )


launcher_module.subprocess.run=fake_validation_run

launcher=RuntimeLauncher()

source=(
    "vless://"
    "11111111-1111-4111-8111-111111111111"
    "@127.0.0.1:443"
    "?encryption=none"
    "&security=none"
    "&type=tcp"
)


try:

    launcher.launch(
        config_id=(
            "postk-retention-r2-test"
        ),
        config_type="vless",
        source=source,
        startup_timeout=1.0,
    )

except RuntimeLaunchError as exc:

    print(
        "EXPECTED_RUNTIME_LAUNCH_ERROR=",
        exc.code,
        str(exc),
    )

except Exception as exc:

    print(
        "EXPECTED_OTHER_EXCEPTION=",
        type(exc).__name__,
        str(exc),
    )

else:

    raise SystemExit(
        "ERROR=MOCK_VALIDATION_DID_NOT_FAIL"
    )

finally:

    launcher_module.subprocess.run=real_run


print(
    "DETERMINISTIC_FAILURE=PASS"
)

print(
    "REAL_XRAY_STARTED=NO"
)
PY


echo
echo "=== 5. VERIFY NEW FORENSIC BUNDLE ==="

AFTER=$(
    find "$FAIL" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      2>/dev/null |
    wc -l
)

echo "FAILURES_AFTER=$AFTER"

test "$AFTER" -gt "$BEFORE"

LATEST=$(
    find "$FAIL" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -printf '%T@ %p\n' |
    sort -nr |
    head -n1 |
    cut -d' ' -f2-
)

echo "LATEST=$LATEST"

test -d "$LATEST"

for F in \
manifest.json \
stdout.log \
stderr.log \
source.raw
do
    test -s "$LATEST/$F"
    echo "$F=PASS"
done

test -s "$LATEST/runtime.json"
echo "runtime.json=PASS"


echo
echo "=== 6. FORENSIC MANIFEST AUDIT ==="

export LATEST

"$PY" <<'PY'
from pathlib import Path
import json
import os

root=Path(
    os.environ["LATEST"]
)

m=json.loads(
    (root/"manifest.json").read_text()
)

print(
    json.dumps(
        m,
        indent=2,
        sort_keys=True,
    )
)

assert m["failed"] is True

assert m["config_id"] == (
    "postk-retention-r2-test"
)

assert m["stage"] == (
    "xray_validation"
)

assert m["returncode"] == 23

assert m["runtime_saved"] is True

metadata=m.get(
    "metadata"
) or {}

assert metadata.get(
    "second_xray"
) is False

assert metadata.get(
    "validation_returncode"
) == 23


stdout=(
    root/"stdout.log"
).read_text(
    errors="replace"
)

stderr=(
    root/"stderr.log"
).read_text(
    errors="replace"
)

assert (
    "synthetic validation stdout"
    in stdout
)

assert (
    "synthetic xray validation failure"
    in stderr
)

print(
    "FORENSIC_MANIFEST=PASS"
)
PY


echo
echo "=== 7. VERIFY SOURCE.RAW EXACT ==="

"$PY" <<'PY'
from pathlib import Path
import os

root=Path(
    os.environ["LATEST"]
)

expected=(
    "vless://"
    "11111111-1111-4111-8111-111111111111"
    "@127.0.0.1:443"
    "?encryption=none"
    "&security=none"
    "&type=tcp"
)

actual=(
    root/"source.raw"
).read_text()

assert actual==expected

print(
    "SOURCE_RAW_EXACT=PASS"
)
PY


echo
echo "=== 8. SANDBOX WAS CLEANED AFTER ARCHIVE ==="

LEFT=$(
    find "$SBOX" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -name 'postk-retention-r2-test-*' \
      | wc -l
)

echo "TEST_SANDBOX_LEFT=$LEFT"

test "$LEFT" -eq 0

echo "ARCHIVE_BEFORE_CLEANUP=PASS"


echo
echo "=== 9. NO SECOND XRAY STATIC CHECK ==="

COUNT=$(
    grep -c \
    'sandbox.start()' \
    "$R/app/health/runtime/launcher.py"
)

echo "SANDBOX_START_CALLS=$COUNT"

test "$COUNT" -eq 1

echo "SECOND_XRAY=NO"


echo
echo "=== 10. RESTART HEALTH SERVICE TO LOAD PATCH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH_SERVICE_RELOADED=PASS"


echo
echo "=== 11. ALL SERVICES ==="

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
echo "=== 12. RETENTION TIMER ==="

test "$(
    systemctl is-active \
    config-location-xray-log-cleanup.timer
)" = active

echo "RETENTION_TIMER=PASS"


echo
echo "======================================================"
echo "POSTK_XRAY_RETENTION_INTEGRATION_R2=PASS"
echo "FORENSIC_FAILURE_CAPTURE=PROVEN"
echo "ARCHIVE_BEFORE_CLEANUP=PROVEN"
echo "RUNTIME_JSON=PRESERVED"
echo "SOURCE_RAW_EXACT=PRESERVED"
echo "VALIDATION_STDOUT_STDERR=PRESERVED"
echo "SECOND_XRAY=NO"
echo "HEALTH_SERVICE_PATCH_LOADED=YES"
echo "NEXT=FINAL-FULL-FORENSIC-SNAPSHOT"
echo "======================================================"
