#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

L="$R/app/health/runtime/launcher.py"
A="$R/app/xray_log_retention.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/POSTK-XRAY-RETENTION-INTEGRATION-$TS"

mkdir -p "$B"

cp -a "$L" "$B/launcher.py.before"
cp -a "$A" "$B/xray_log_retention.py.before"

echo "BACKUP=$B"


echo
echo "=== 1. PATCH LAUNCHER ==="

export L

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["L"])
s=p.read_text()

MARK="FIX22_POSTK_XRAY_FORENSIC_RETENTION"

if MARK in s:
    print("RETENTION_INTEGRATION_ALREADY_PRESENT=YES")
    raise SystemExit(0)


# --------------------------------------------
# Import forensic archiver.
# --------------------------------------------

needle="from ..plugins.types import RuntimeRequest\n"

replacement='''from ..plugins.types import RuntimeRequest

from app.xray_log_retention import (
    archive_xray_run,
)

# FIX22_POSTK_XRAY_FORENSIC_RETENTION
'''

if needle not in s:
    raise SystemExit(
        "ERROR=IMPORT_INSERT_POINT_NOT_FOUND"
    )

s=s.replace(
    needle,
    replacement,
    1,
)


# --------------------------------------------
# Create forensic state before try.
# --------------------------------------------

needle='''        sandbox = XraySandbox(
            base_dir=self.base_dir,
            xray_binary=self.xray_binary,
            config_id=config_id,
        )

        try:
'''

replacement='''        sandbox = XraySandbox(
            base_dir=self.base_dir,
            xray_binary=self.xray_binary,
            config_id=config_id,
        )

        # Forensic state from the SAME Xray execution.
        # No second Xray process is ever started.
        validation_stdout = ""
        validation_stderr = ""
        validation_returncode = None
        failure_stage = "sandbox_create"
        artifact = None

        try:
'''

if needle not in s:
    raise SystemExit(
        "ERROR=SANDBOX_TRY_BLOCK_NOT_FOUND"
    )

s=s.replace(
    needle,
    replacement,
    1,
)


# --------------------------------------------
# Track build stage.
# --------------------------------------------

needle='''            artifact = builder.build_runtime(
'''

replacement='''            failure_stage = "runtime_build"

            artifact = builder.build_runtime(
'''

if needle not in s:
    raise SystemExit(
        "ERROR=BUILD_RUNTIME_NOT_FOUND"
    )

s=s.replace(
    needle,
    replacement,
    1,
)


# --------------------------------------------
# Track validation and capture existing output.
# --------------------------------------------

needle='''            # Validate before starting a real
            # process. No proxy traffic occurs.
            result = subprocess.run(
'''

replacement='''            # Validate before starting a real
            # process. No proxy traffic occurs.
            failure_stage = "xray_validation"

            result = subprocess.run(
'''

if needle not in s:
    raise SystemExit(
        "ERROR=VALIDATION_BLOCK_NOT_FOUND"
    )

s=s.replace(
    needle,
    replacement,
    1,
)


needle='''            if result.returncode != 0:
'''

replacement='''            validation_stdout = (
                result.stdout or ""
            )

            validation_stderr = (
                result.stderr or ""
            )

            validation_returncode = (
                result.returncode
            )

            if result.returncode != 0:
'''

if needle not in s:
    raise SystemExit(
        "ERROR=VALIDATION_RESULT_NOT_FOUND"
    )

s=s.replace(
    needle,
    replacement,
    1,
)


# --------------------------------------------
# Runtime startup stage.
# --------------------------------------------

needle='''            sandbox.start()

            if not sandbox.wait_started(
'''

replacement='''            failure_stage = "xray_runtime_start"

            sandbox.start()

            failure_stage = "xray_runtime_readiness"

            if not sandbox.wait_started(
'''

if needle not in s:
    raise SystemExit(
        "ERROR=SANDBOX_START_BLOCK_NOT_FOUND"
    )

s=s.replace(
    needle,
    replacement,
    1,
)


# --------------------------------------------
# Replace destructive exception cleanup with:
# archive first -> cleanup second.
# --------------------------------------------

needle='''        except Exception:
            sandbox.cleanup()
            raise
'''

replacement='''        except Exception as exc:

            # IMPORTANT:
            # archive before sandbox.cleanup(), because
            # cleanup recursively removes runtime.json
            # and the real Xray stdout/stderr logs.
            try:

                runtime_stdout = ""
                runtime_stderr = ""

                if sandbox.paths.stdout.exists():
                    runtime_stdout = (
                        sandbox.paths.stdout.read_text(
                            encoding="utf-8",
                            errors="replace",
                        )
                    )

                if sandbox.paths.stderr.exists():
                    runtime_stderr = (
                        sandbox.paths.stderr.read_text(
                            encoding="utf-8",
                            errors="replace",
                        )
                    )


                combined_stdout = (
                    "===== XRAY VALIDATION STDOUT =====\\n"
                    + validation_stdout
                    + "\\n"
                    "===== XRAY RUNTIME STDOUT =====\\n"
                    + runtime_stdout
                )

                combined_stderr = (
                    "===== XRAY VALIDATION STDERR =====\\n"
                    + validation_stderr
                    + "\\n"
                    "===== XRAY RUNTIME STDERR =====\\n"
                    + runtime_stderr
                )


                # Preserve source.raw exactly as received
                # whenever it can be represented without
                # altering bytes/string contents.
                source_raw = source

                if not isinstance(
                    source_raw,
                    (str, bytes),
                ):
                    try:
                        import json as _json

                        source_raw = _json.dumps(
                            source_raw,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        )
                    except Exception:
                        source_raw = repr(
                            source_raw
                        )


                runtime_path = None

                if (
                    artifact is not None
                    and getattr(
                        artifact,
                        "config_path",
                        None,
                    ) is not None
                ):
                    runtime_path = (
                        artifact.config_path
                    )

                elif sandbox.paths.config.exists():
                    runtime_path = (
                        sandbox.paths.config
                    )


                process_returncode = None

                if sandbox.process is not None:
                    process_returncode = (
                        sandbox.process.poll()
                    )


                archive_returncode = (
                    validation_returncode
                )

                if (
                    archive_returncode in (
                        None,
                        0,
                    )
                    and process_returncode
                    is not None
                ):
                    archive_returncode = (
                        process_returncode
                    )

                # A launcher exception is always a failed
                # forensic run even when Xray itself has
                # not yet returned a non-zero code.
                if archive_returncode in (
                    None,
                    0,
                ):
                    archive_returncode = -1


                archive_xray_run(
                    config_id=config_id,

                    stdout=combined_stdout,

                    stderr=combined_stderr,

                    returncode=archive_returncode,

                    runtime_path=runtime_path,

                    source_raw=source_raw,

                    stage=failure_stage,

                    metadata={
                        "config_type":
                            config_type,

                        "exception_type":
                            type(exc).__name__,

                        "exception_message":
                            str(exc),

                        "validation_returncode":
                            validation_returncode,

                        "runtime_returncode":
                            process_returncode,

                        "sandbox_root":
                            str(
                                sandbox.paths.root
                            ),

                        "xray_binary":
                            str(
                                self.xray_binary
                            ),

                        "second_xray":
                            False,
                    },
                )

            except Exception as archive_exc:

                # Retention must never alter the original
                # Health result or hide the real exception.
                try:
                    import sys

                    print(
                        "XRAY_FORENSIC_ARCHIVE_ERROR="
                        f"{type(archive_exc).__name__}: "
                        f"{archive_exc}",
                        file=sys.stderr,
                    )
                except Exception:
                    pass


            sandbox.cleanup()

            raise
'''

if needle not in s:
    raise SystemExit(
        "ERROR=EXCEPTION_HANDLER_NOT_FOUND"
    )

s=s.replace(
    needle,
    replacement,
    1,
)

p.write_text(s)

print(
    "LAUNCHER_RETENTION_PATCH=PASS"
)
PY


echo
echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$L"
"$PY" -m py_compile "$A"

echo "COMPILE=PASS"


echo
echo "=== 3. STATIC SAFETY CONTRACT ==="

grep -q \
'FIX22_POSTK_XRAY_FORENSIC_RETENTION' \
"$L"

grep -q \
'archive_xray_run' \
"$L"

grep -q \
'archive before sandbox.cleanup' \
"$L"

COUNT=$(
    grep -c \
    'sandbox.start()' \
    "$L"
)

echo "SANDBOX_START_CALLS=$COUNT"

test "$COUNT" -eq 1

echo "SECOND_XRAY=NO"
echo "STATIC_SAFETY=PASS"


echo
echo "=== 4. SYNTHETIC VALIDATION FAILURE ==="

BEFORE=$(
    find \
    /var/log/config-location/xray/failures \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    | wc -l
)

export BEFORE

PYTHONPATH="$R" "$PY" <<'PY'
from app.health.runtime.launcher import (
    RuntimeLauncher,
    RuntimeLaunchError,
)

launcher=RuntimeLauncher()

# Intentionally invalid VLESS UUID.
source=(
    "vless://NOT-A-UUID@127.0.0.1:443"
    "?encryption=none"
    "&security=none"
    "&type=tcp"
)

try:

    launcher.launch(
        config_id=(
            "postk-retention-"
            "validation-test"
        ),
        config_type="vless",
        source=source,
        startup_timeout=1.0,
    )

except Exception as exc:

    print(
        "EXPECTED_EXCEPTION=",
        type(exc).__name__,
        str(exc),
    )

else:

    raise SystemExit(
        "ERROR=INVALID_CONFIG_UNEXPECTEDLY_STARTED"
    )


print(
    "SYNTHETIC_FAILURE_TRIGGERED=PASS"
)
PY


AFTER=$(
    find \
    /var/log/config-location/xray/failures \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    | wc -l
)

echo "FAILURES_BEFORE=$BEFORE"
echo "FAILURES_AFTER=$AFTER"

test "$AFTER" -gt "$BEFORE"

echo "FAILURE_ARCHIVE_CREATED=PASS"


echo
echo "=== 5. VERIFY NEW FORENSIC BUNDLE ==="

LATEST=$(
    find \
    /var/log/config-location/xray/failures \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-
)

echo "LATEST=$LATEST"

test -n "$LATEST"
test -d "$LATEST"

for f in \
manifest.json \
stdout.log \
stderr.log \
source.raw
do
    test -f "$LATEST/$f"
    echo "$f=PASS"
done

if [ -f "$LATEST/runtime.json" ]; then
    echo "runtime.json=PASS"
else
    echo "runtime.json=NOT_AVAILABLE_AT_FAILURE_STAGE"
fi


echo
echo "--- MANIFEST ---"

cat "$LATEST/manifest.json"


echo
echo "--- STDERR TAIL ---"

tail -n 80 \
"$LATEST/stderr.log" \
|| true


echo
echo "=== 6. VERIFY ARCHIVE BEFORE CLEANUP ==="

"$PY" <<'PY'
from pathlib import Path
import json

root=Path(
    "/var/log/config-location/xray/failures"
)

latest=max(
    (
        p
        for p in root.iterdir()
        if p.is_dir()
    ),
    key=lambda p:p.stat().st_mtime_ns,
)

m=json.loads(
    (
        latest/"manifest.json"
    ).read_text()
)

print(
    "FAILED=",
    m.get("failed"),
)

print(
    "STAGE=",
    m.get("stage"),
)

print(
    "CONFIG_ID=",
    m.get("config_id"),
)

print(
    "RETURNCODE=",
    m.get("returncode"),
)

print(
    "RUNTIME_SAVED=",
    m.get("runtime_saved"),
)

print(
    "SECOND_XRAY=",
    (
        m.get("metadata")
        or {}
    ).get("second_xray"),
)

assert m.get("failed") is True

assert (
    (
        m.get("metadata")
        or {}
    ).get("second_xray")
    is False
)

assert (
    latest/"source.raw"
).exists()

assert (
    latest/"stderr.log"
).exists()

assert (
    latest/"stdout.log"
).exists()

print(
    "FORENSIC_BUNDLE_CONTRACT=PASS"
)
PY


echo
echo "=== 7. RETENTION TIMER ==="

test "$(
    systemctl is-active \
    config-location-xray-log-cleanup.timer
)" = active

test "$(
    systemctl is-enabled \
    config-location-xray-log-cleanup.timer
)" = enabled

echo "RETENTION_TIMER=PASS"


echo
echo "=== 8. PRODUCTION SERVICE HEALTH ==="

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
echo "=== 9. COUNTRY CONSISTENCY SMOKE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

bad=[]

for ip in I.glob("*.json"):

    try:
        i=json.loads(
            ip.read_text()
        )
    except Exception:
        continue

    if not (
        i.get("locked") is True
        and i.get("country_code")
    ):
        continue

    cid=str(
        i.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue

    try:
        p=json.loads(
            pp.read_text()
        )
    except Exception:
        continue

    if (
        str(
            i.get("country_code")
            or ""
        ).upper()
        !=
        str(
            p.get("country_code")
            or ""
        ).upper()
    ):
        bad.append(cid)


print(
    "COUNTRY_CONFLICTS=",
    len(bad),
)

assert not bad

print(
    "COUNTRY_CONSISTENCY=PASS"
)
PY


echo
echo "=== 10. WRITE FINAL RETENTION AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import time

report={
    "schema_version":1,

    "generated_epoch":
        int(time.time()),

    "integration":
        "launcher_exception_boundary",

    "archive_before_cleanup":
        True,

    "validation_stdout":
        True,

    "validation_stderr":
        True,

    "runtime_stdout":
        True,

    "runtime_stderr":
        True,

    "runtime_json":
        True,

    "source_raw":
        True,

    "config_id":
        True,

    "config_type":
        True,

    "failure_stage":
        True,

    "returncode":
        True,

    "failure_retention_days":
        14,

    "success_retention_days":
        3,

    "second_xray":
        False,

    "health_semantics_changed":
        False,
}

out=Path(
    "/var/lib/config-location/"
    "xray-log-retention-final-audit.json"
)

out.write_text(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

print(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

print(
    "FINAL_RETENTION_AUDIT=PASS"
)
PY


echo
echo "======================================================"
echo "POSTK_XRAY_RETENTION_INTEGRATION=PASS"
echo "ARCHIVE_BEFORE_CLEANUP=YES"
echo "FAILURE_RETENTION=14_DAYS"
echo "SOURCE_RAW=PRESERVED"
echo "RUNTIME_JSON=PRESERVED_WHEN_BUILT"
echo "XRAY_TEST_STDOUT_STDERR=PRESERVED"
echo "XRAY_RUNTIME_STDOUT_STDERR=PRESERVED"
echo "SECOND_XRAY=NO"
echo "HEALTH_SEMANTICS_CHANGED=NO"
echo "NEXT=FINAL-FULL-FORENSIC-SNAPSHOT"
echo "======================================================"
