#!/usr/bin/env bash
set -Eeuo pipefail

SVC=config-location-health-adaptive.service
SB=/var/lib/config-location/health-sandboxes

RESTORED=0

restore() {
    rc=$?

    if [ "$RESTORED" -eq 0 ]; then
        systemctl reset-failed "$SVC" || true
        systemctl start "$SVC" || true
        sleep 4
        echo "RESTORE_STATE=$(systemctl is-active "$SVC" 2>/dev/null || true)"
    fi

    exit "$rc"
}

trap restore EXIT

echo "=== BEFORE ==="

systemctl show "$SVC" \
-p ActiveState \
-p SubState \
-p Result \
-p MainPID \
--no-pager

test "$(systemctl is-active "$SVC")" = active

echo "XRAY_BEFORE=$(ps -eo args= | grep "[x]ray" | grep -c "$SB/" || true)"
echo "SANDBOX_BEFORE=$(find "$SB" -mindepth 1 -maxdepth 1 -type d | wc -l)"

START_NS=$(date +%s%N)

echo "=== STOP ==="

systemctl stop "$SVC"

END_NS=$(date +%s%N)

ELAPSED_MS=$(
    echo $(( (END_NS - START_NS) / 1000000 ))
)

echo "STOP_ELAPSED_MS=$ELAPSED_MS"

ACTIVE=$(systemctl is-active "$SVC" 2>/dev/null || true)
RESULT=$(systemctl show "$SVC" -p Result --value 2>/dev/null || true)
MAINPID=$(systemctl show "$SVC" -p MainPID --value 2>/dev/null || true)

echo "ACTIVE_AFTER_STOP=$ACTIVE"
echo "RESULT_AFTER_STOP=$RESULT"
echo "MAINPID_AFTER_STOP=$MAINPID"

test "$ACTIVE" = inactive
test "$RESULT" = success
test "$MAINPID" = 0

echo "=== CHILD DRAIN ==="

XRAY=999
CURL=999

for i in $(seq 1 30); do

    XRAY=$(
        ps -eo args= \
        | grep "[x]ray" \
        | grep -c "$SB/" \
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

echo "=== JOURNAL ==="

J=$(journalctl -u "$SVC" --since "-4 min" --no-pager)

echo "$J" | tail -n 140

if echo "$J" | grep -q "State .stop-sigterm. timed out"; then
    echo "STOP_TIMEOUT_DETECTED"
    exit 1
fi

if echo "$J" | grep -q "Failed with result .timeout."; then
    echo "FAILED_TIMEOUT_DETECTED"
    exit 1
fi

echo "STOP_TIMEOUT=NO"

echo "=== START ==="

systemctl reset-failed "$SVC" || true
systemctl start "$SVC"

sleep 5

STATE=$(systemctl is-active "$SVC")

echo "HEALTH_STATE=$STATE"

test "$STATE" = active

systemctl show "$SVC" \
-p ActiveState \
-p SubState \
-p Result \
-p MainPID \
--no-pager

echo "=== ALL SERVICES ==="

for s in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$s" 2>/dev/null || true)
    echo "$s=$X"
    test "$X" = active
done

RESTORED=1
trap - EXIT

echo "========================================"
echo "FIX20.8AH=PASS"
echo "GRACEFUL_STOP=PASS"
echo "STOP_ELAPSED_MS=$ELAPSED_MS"
echo "STOP_RESULT=success"
echo "STOP_TIMEOUT=NO"
echo "XRAY_CHILDREN_AFTER_STOP=0"
echo "CURL_CHILDREN_AFTER_STOP=0"
echo "PRODUCTION_RESTORED=PASS"
echo "========================================"
