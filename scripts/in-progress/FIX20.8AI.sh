#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

D=/var/lib/config-location
C="$D/configs"
H="$D/health-results/latest"
S="$D/health-sandboxes"

O="$D/integrity/runtime-hygiene"
A="$O/archives"

mkdir -p "$O" "$A"

WRITERS="
config-location-fetcher.service
config-location-health-adaptive.service
config-location-lifecycle-sync.service
config-location-lifecycle-watchdog.service
"

RESTORED=0

restore() {
    rc=$?

    if [ "$RESTORED" -eq 0 ]; then

        echo "=== EMERGENCY RESTORE ==="

        for svc in $WRITERS; do
            systemctl reset-failed "$svc" || true
            systemctl start "$svc" || true
        done

        sleep 4

        for svc in $WRITERS; do
            echo "$svc=$(systemctl is-active "$svc" 2>/dev/null || true)"
        done

        echo "config-location-panel.service=$(systemctl is-active config-location-panel.service 2>/dev/null || true)"
    fi

    exit "$rc"
}

trap restore EXIT


echo "=== 1. PRECHECK ==="

test "$(systemctl is-active config-location-panel.service)" = active

for svc in $WRITERS; do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done


echo "=== 2. QUIESCE WRITERS ==="

systemctl stop $WRITERS

sleep 3

for svc in $WRITERS; do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = inactive
done


echo "=== 3. VERIFY NO PROJECT RUNTIME ==="

for i in $(seq 1 20); do

    XRAY=$(
        ps -eo args= \
        | grep "[x]ray" \
        | grep -c "$S/" \
        || true
    )

    CURL=$(
        ps -eo pid=,cgroup=,comm= 2>/dev/null \
        | grep "config-location-health-adaptive.service" \
        | grep -c "[c]url" \
        || true
    )

    echo "DRAIN[$i] XRAY=$XRAY CURL=$CURL"

    if [ "$XRAY" -eq 0 ] && [ "$CURL" -eq 0 ]; then
        break
    fi

    sleep 1
done

test "$XRAY" -eq 0
test "$CURL" -eq 0


echo "=== 4. REFERENTIAL GUARD ==="

PYTHONPATH="$R" \
"$PY" -m app.integrity.referential_guard


echo "=== 5. ORPHAN VERIFY ==="

ORPHAN=0

for F in "$H"/*.json; do

    [ -f "$F" ] || continue

    ID=$(basename "$F" .json)

    if [ ! -f "$C/$ID.json" ]; then
        echo "ORPHAN=$ID"
        ORPHAN=$((ORPHAN+1))
    fi
done

echo "ORPHAN_HEALTH=$ORPHAN"

test "$ORPHAN" -eq 0


echo "=== 6. SANDBOX GC ==="

TS=$(date -u +%Y%m%d-%H%M%S)

LIST="/tmp/fix20.8ai-sandbox-$TS.txt"
ARCH="$A/fix20.8ai-sandboxes-$TS.tar.gz"

find "$S" \
-mindepth 1 \
-maxdepth 1 \
-type d \
-printf "%f\n" \
| sort > "$LIST"

COUNT=$(wc -l < "$LIST")

echo "SANDBOX_CANDIDATES=$COUNT"

if [ "$COUNT" -gt 0 ]; then

    tar -C "$S" \
        -czf "$ARCH" \
        -T "$LIST"

    sha256sum "$ARCH" \
        > "$ARCH.sha256"

    sha256sum -c \
        "$ARCH.sha256"

    while IFS= read -r NAME; do

        [ -n "$NAME" ] || continue

        TARGET="$S/$NAME"

        [ -d "$TARGET" ] || continue

        if ps -eo args= \
            | grep "[x]ray" \
            | grep -F "$TARGET/config.json" \
            >/dev/null
        then
            echo "REFUSE_ACTIVE_SANDBOX=$NAME"
            exit 1
        fi

        case "$TARGET" in
            "$S"/*)
                rm -rf -- "$TARGET"
                ;;
            *)
                echo "SAFETY_REFUSE=$TARGET"
                exit 1
                ;;
        esac

    done < "$LIST"

    echo "SANDBOX_ARCHIVE=$ARCH"
    echo "SANDBOX_SHA256=$ARCH.sha256"
fi

rm -f "$LIST"

LEFT=$(
    find "$S" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    | wc -l
)

echo "SANDBOX_AFTER_GC=$LEFT"

test "$LEFT" -eq 0


echo "=== 7. RUNTIME RESIDUALS ==="

RF=$(
    {
        grep -l \
        '"state"[[:space:]]*:[[:space:]]*"runtime_failed"' \
        "$H"/*.json 2>/dev/null \
        || true
    } | wc -l
)

XV=$(
    {
        grep -l \
        'xray_validation_failed' \
        "$H"/*.json 2>/dev/null \
        || true
    } | wc -l
)

UC=$(
    {
        grep -l \
        'unsupported_config_type' \
        "$H"/*.json 2>/dev/null \
        || true
    } | wc -l
)

echo "RUNTIME_FAILED=$RF"
echo "XRAY_VALIDATION_FAILED=$XV"
echo "UNSUPPORTED_CONFIG_TYPE=$UC"

test "$RF" -eq 0
test "$XV" -eq 0
test "$UC" -eq 0


echo "=== 8. SOCKS DISPATCH ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.health.runtime.launcher import RuntimeLauncher

builder = RuntimeLauncher()._builder("socks")

print(
    "SOCKS_BUILDER=",
    type(builder).__name__,
)

assert (
    type(builder).__name__
    == "UriXrayRuntimeBuilder"
)

print("SOCKS_DISPATCH=PASS")
PY


echo "=== 9. RUNTIME SELFTESTS ==="

PYTHONPATH="$R" \
"$PY" -m app.health.runtime.builders.selftest_xray_json

PYTHONPATH="$R" \
"$PY" -m app.health.runtime.selftest


echo "=== 10. SELFTEST SANDBOX CLEANUP ==="

LEFT2=$(
    find "$S" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    | wc -l
)

echo "SANDBOX_AFTER_SELFTEST=$LEFT2"

test "$LEFT2" -eq 0


echo "=== 11. STORE HEALTH ==="

PYTHONPATH="$R" \
"$PY" -m app.integrity.run_store_health \
>/dev/null


"$PY" <<'PY'
import json
from pathlib import Path

p = Path(
    "/var/lib/config-location/"
    "integrity/store-health-latest.json"
)

counts = json.loads(
    p.read_text()
)["counts"]

invalid = (
    counts["invalid_config_files"]
    + counts["invalid_health_files"]
)

mismatch = (
    counts["config_filename_mismatches"]
    + counts["health_filename_mismatches"]
)

duplicates = (
    counts["duplicate_config_ids"]
    + counts["duplicate_health_ids"]
)

print(
    "CONFIGS=",
    counts["configs"],
)

print(
    "HEALTH_LATEST=",
    counts["health_latest"],
)

print(
    "CONFIGS_WITHOUT_HEALTH=",
    counts["configs_without_health"],
)

print(
    "ORPHAN_HEALTH=",
    counts["orphan_health"],
)

print(
    "INVALID=",
    invalid,
)

print(
    "MISMATCH=",
    mismatch,
)

print(
    "DUPLICATES=",
    duplicates,
)

assert counts["orphan_health"] == 0
assert invalid == 0
assert mismatch == 0
assert duplicates == 0

print(
    "STORE_INTEGRITY=PASS"
)
PY


echo "=== 12. RESTORE PRODUCTION ==="

for svc in $WRITERS; do
    systemctl reset-failed "$svc" || true
    systemctl start "$svc"
done

sleep 5

for svc in $WRITERS; do

    X=$(systemctl is-active "$svc")

    echo "$svc=$X"

    test "$X" = active
done

PANEL=$(
    systemctl is-active \
    config-location-panel.service
)

echo "config-location-panel.service=$PANEL"

test "$PANEL" = active

RESTORED=1
trap - EXIT


echo "========================================"
echo "FIX20.8AI=PASS"
echo "REFERENTIAL_INTEGRITY=PASS"
echo "ORPHAN_HEALTH=0"
echo "SANDBOX_AFTER_GC=0"
echo "RUNTIME_FAILED=0"
echo "XRAY_VALIDATION_FAILED=0"
echo "UNSUPPORTED_CONFIG_TYPE=0"
echo "SOCKS_DISPATCH=PASS"
echo "RUNTIME_SELFTEST=PASS"
echo "STORE_INTEGRITY=PASS"
echo "PRODUCTION_RESTORED=PASS"
echo "========================================"
