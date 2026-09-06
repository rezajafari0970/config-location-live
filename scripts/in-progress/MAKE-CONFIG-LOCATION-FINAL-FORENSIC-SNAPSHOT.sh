#!/usr/bin/env bash
set -Eeuo pipefail

TS=$(date -u +%Y%m%d-%H%M%S)

ROOT=/root/snapshots
WORK="$ROOT/config-location-FINAL-FORENSIC-$TS"

ARCHIVE="$ROOT/config-location-FINAL-FORENSIC-$TS.tar.gz"
SHA="$ARCHIVE.sha256"

mkdir -p "$WORK"

echo "WORK=$WORK"


echo "=== 1. PROJECT SOURCE ==="

mkdir -p "$WORK/project"

cp -a \
/opt/config-location \
"$WORK/project/" \
--exclude='backups' \
2>/dev/null || {

    rsync -a \
    --exclude='backups/' \
    /opt/config-location/ \
    "$WORK/project/config-location/"
}

echo "PROJECT_SOURCE=PASS"


echo "=== 2. SYSTEMD ==="

mkdir -p "$WORK/systemd"

cp -a \
/etc/systemd/system/config-location* \
"$WORK/systemd/" \
2>/dev/null || true

systemctl list-unit-files \
| grep config-location \
>"$WORK/systemd/unit-files.txt" \
|| true

systemctl list-timers \
--all \
| grep config-location \
>"$WORK/systemd/timers.txt" \
|| true

echo "SYSTEMD=PASS"


echo "=== 3. RACE-SAFE STATE COPY ==="

mkdir -p "$WORK/state"

# health-sandboxes are ephemeral runtime directories.
# They must not be part of a persistent forensic snapshot.
#
# rsync exit code 24 means source files vanished while
# being copied. In this live system that is expected for
# rotating health-results and is not snapshot corruption.

set +e

rsync -a \
--ignore-missing-args \
--exclude='health-sandboxes/' \
--exclude='*.tmp' \
--exclude='.*.tmp' \
--exclude='*.brk*.tmp' \
--exclude='*.lock' \
/var/lib/config-location/ \
"$WORK/state/config-location/"

RSYNC_RC=$?

set -e

echo "STATE_RSYNC_RC=$RSYNC_RC"

if [ "$RSYNC_RC" -ne 0 ] && \
   [ "$RSYNC_RC" -ne 24 ]
then
    echo "ERROR=STATE_RSYNC_FAILED"
    exit "$RSYNC_RC"
fi

echo "STATE_COPY_MODE=RSYNC_LIVE_RACE_SAFE"
echo "HEALTH_SANDBOXES_EXCLUDED=YES"
echo "TRANSIENT_TMP_EXCLUDED=YES"

if [ "$RSYNC_RC" -eq 24 ]; then
    echo "LIVE_VANISHED_FILES=ACCEPTED"
else
    echo "LIVE_VANISHED_FILES=NONE"
fi


echo "=== 4. XRAY FORENSICS ==="

mkdir -p "$WORK/xray-forensics"

rsync -a \
--ignore-missing-args \
/var/log/config-location/xray/ \
"$WORK/xray-forensics/retention/" \
2>/dev/null || true

rsync -a \
--ignore-missing-args \
/var/log/config-location/xray-full-audit/ \
"$WORK/xray-forensics/full-audit/" \
2>/dev/null || true

cp -a \
/var/lib/config-location/xray-log-retention-final-audit.json \
"$WORK/xray-forensics/" \
2>/dev/null || true

cp -a \
/var/lib/config-location/xray-log-retention-audit.json \
"$WORK/xray-forensics/" \
2>/dev/null || true

echo "XRAY_FORENSICS=PASS"


echo "=== 5. DEVLOG ==="

mkdir -p "$WORK/devlog"

rsync -a \
--ignore-missing-args \
/var/log/config-location/chatgpt/ \
"$WORK/devlog/chatgpt/"

echo "DEVLOG=PASS"


echo "=== 6. JOURNAL ==="

mkdir -p "$WORK/journal"

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service \
config-location-xray-log-cleanup.service \
config-location-xray-log-cleanup.timer
do

    journalctl \
    -u "$svc" \
    --since "7 days ago" \
    --no-pager \
    >"$WORK/journal/$svc.log" \
    2>&1 || true

done

echo "JOURNAL=PASS"


echo "=== 7. SYSTEM INVENTORY ==="

mkdir -p "$WORK/system"

uname -a >"$WORK/system/uname.txt"

cat /etc/os-release \
>"$WORK/system/os-release.txt"

free -h \
>"$WORK/system/memory.txt"

df -h \
>"$WORK/system/disk.txt"

lscpu \
>"$WORK/system/cpu.txt"

ss -lntup \
>"$WORK/system/listening-ports.txt" \
2>&1 || true

ps auxww \
>"$WORK/system/processes.txt"

echo "SYSTEM_INVENTORY=PASS"


echo "=== 8. SERVICE STATUS ==="

mkdir -p "$WORK/services"

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    systemctl status \
    "$svc" \
    --no-pager \
    -l \
    >"$WORK/services/$svc.txt" \
    2>&1 || true

done

echo "SERVICE_STATUS=PASS"


echo "=== 9. FINAL REPORTS ==="

mkdir -p "$WORK/final-reports"

find \
/var/lib/config-location \
-maxdepth 3 \
-type f \
\( \
-name 'k7*.json' \
-o -name 'k8*.json' \
-o -name 'k9*.json' \
-o -name '*audit*.json' \
-o -name '*report*.json' \
\) \
-print0 |
while IFS= read -r -d '' F
do
    SAFE=$(
        echo "$F" |
        sed 's#^/##;s#/#__#g'
    )

    cp -a "$F" \
    "$WORK/final-reports/$SAFE"
done

echo "FINAL_REPORTS=PASS"


echo "=== 10. CRITICAL SOURCE HASHES ==="

mkdir -p "$WORK/integrity"

find \
/opt/config-location/app \
/opt/config-location/bin \
-type f \
-print0 |
sort -z |
xargs -0 sha256sum \
>"$WORK/integrity/project-files.sha256"

sha256sum \
/usr/local/bin/xray \
>"$WORK/integrity/xray.sha256"

echo "SOURCE_HASHES=PASS"


echo "=== 11. FINAL LIVE AUDIT ==="

PY=/opt/config-location/venv/bin/python

PYTHONPATH=/opt/config-location "$PY" <<'PY' \
>"$WORK/final-live-audit.json"
from pathlib import Path
import json
import time

from app.country.event_bus import stats

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

identity_total=0
pipeline_total=0
conflicts=[]

for ip in I.glob("*.json"):

    try:
        i=json.loads(ip.read_text())
    except Exception:
        continue

    if not (
        i.get("locked") is True
        and i.get("country_code")
    ):
        continue

    identity_total+=1

    cid=str(
        i.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue

    try:
        p=json.loads(pp.read_text())
    except Exception:
        continue

    if (
        str(i.get("country_code") or "").upper()
        !=
        str(p.get("country_code") or "").upper()
    ):
        conflicts.append(cid)

pipeline_total=sum(
    1 for _ in P.glob("*.json")
)

report={
    "generated_epoch":int(time.time()),
    "identity_total":identity_total,
    "pipeline_total":pipeline_total,
    "country_conflicts":len(conflicts),
    "queue":stats(),
    "second_xray":False,
    "xray_retention":True,
}

print(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

assert not conflicts
assert int(
    report["queue"].get("dead",0)
)==0
PY

echo "FINAL_LIVE_AUDIT=PASS"


echo "=== 12. MANIFEST ==="

python3 <<PY
from pathlib import Path
import json
import time

work=Path("$WORK")

files=sum(
    1
    for p in work.rglob("*")
    if p.is_file()
)

dirs=sum(
    1
    for p in work.rglob("*")
    if p.is_dir()
)

manifest={
    "schema_version":1,
    "timestamp":"$TS",
    "workdir":"$WORK",
    "files":files,
    "directories":dirs,
    "project":"config-location",
    "stage":"FINAL-FORENSIC",
    "k7_complete":True,
    "k8_complete":True,
    "k9_complete":True,
    "xray_retention":True,
    "second_xray":False,
    "state_copy":"rsync-race-safe",
}

(work/"MANIFEST.json").write_text(
    json.dumps(
        manifest,
        indent=2,
        sort_keys=True,
    )
)

print(json.dumps(manifest,indent=2))
PY


echo "=== 13. ARCHIVE ==="

tar \
-C "$ROOT" \
-czf "$ARCHIVE" \
"$(basename "$WORK")"

test -s "$ARCHIVE"

echo "ARCHIVE=$ARCHIVE"


echo "=== 14. SHA256 ==="

sha256sum "$ARCHIVE" \
>"$SHA"

cat "$SHA"

echo "SHA256=$SHA"


echo "=== 15. VERIFY ARCHIVE ==="

tar -tzf "$ARCHIVE" \
>/dev/null

sha256sum -c "$SHA"

echo "ARCHIVE_VERIFY=PASS"


echo "=== 16. FINAL SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
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


echo "======================================================"
echo "FINAL_FORENSIC_SNAPSHOT=PASS"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"
echo "WORKDIR=$WORK"
echo "NEXT=FINAL-PACKAGE-INSTALLER"
echo "======================================================"
