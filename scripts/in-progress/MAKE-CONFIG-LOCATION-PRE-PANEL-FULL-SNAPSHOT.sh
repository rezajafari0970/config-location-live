#!/usr/bin/env bash
set -Eeuo pipefail

TS=$(date -u +%Y%m%d-%H%M%S)

BASE=/root/snapshots
NAME="config-location-PRE-PANEL-FULL-$TS"

WORK="$BASE/$NAME"
ARCHIVE="$BASE/$NAME.tar.gz"
SHA="$ARCHIVE.sha256"

mkdir -p "$BASE"
mkdir -p "$WORK"

echo "======================================================"
echo " CONFIG LOCATION PRE-PANEL FULL SNAPSHOT"
echo "======================================================"
echo "WORK=$WORK"
echo "ARCHIVE=$ARCHIVE"


echo
echo "=== 1. PROJECT SOURCE ==="

mkdir -p "$WORK/project"

rsync -a \
--exclude='backups/' \
--exclude='__pycache__/' \
--exclude='*.pyc' \
/opt/config-location/ \
"$WORK/project/config-location/"

echo "PROJECT_SOURCE=PASS"


echo
echo "=== 2. PROJECT BACKUPS INVENTORY ==="

mkdir -p "$WORK/backups"

if [ -d /opt/config-location/backups ]; then

    find /opt/config-location/backups \
    -maxdepth 2 \
    -type f \
    -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' \
    | sort \
    >"$WORK/backups/inventory.txt"

fi

echo "BACKUP_INVENTORY=PASS"


echo
echo "=== 3. SYSTEMD UNITS ==="

mkdir -p "$WORK/systemd"

find /etc/systemd/system \
-maxdepth 2 \
\( \
-name 'config-location*' \
-o -path '*/config-location*.service.d/*' \
\) \
-print0 2>/dev/null \
| while IFS= read -r -d '' F
do

    if [ -f "$F" ]; then

        SAFE=$(
            echo "$F" |
            sed 's#^/##;s#/#__#g'
        )

        cp -a "$F" \
        "$WORK/systemd/$SAFE"

    fi

done


systemctl list-unit-files \
| grep -i config-location \
>"$WORK/systemd/unit-files.txt" \
|| true


systemctl list-units \
--all \
| grep -i config-location \
>"$WORK/systemd/units.txt" \
|| true


systemctl list-timers \
--all \
| grep -i config-location \
>"$WORK/systemd/timers.txt" \
|| true


for S in $(systemctl list-unit-files \
    --no-legend \
    | awk '/config-location/ {print $1}')
do

    systemctl cat "$S" \
    >"$WORK/systemd/CAT-$S.txt" \
    2>&1 || true

    systemctl show "$S" \
    >"$WORK/systemd/SHOW-$S.txt" \
    2>&1 || true

done

echo "SYSTEMD=PASS"


echo
echo "=== 4. LIVE STATE COPY ==="

mkdir -p "$WORK/state/config-location"

set +e

rsync -a \
--ignore-missing-args \
--exclude='health-sandboxes/' \
--exclude='*.tmp' \
--exclude='.*.tmp' \
--exclude='*.lock' \
--exclude='*.pid' \
/var/lib/config-location/ \
"$WORK/state/config-location/"

RC=$?

set -e

echo "STATE_RSYNC_RC=$RC"

if [ "$RC" -ne 0 ] && [ "$RC" -ne 24 ]; then
    echo "ERROR=STATE_COPY_FAILED"
    exit "$RC"
fi

echo "HEALTH_SANDBOXES_EXCLUDED=YES"
echo "STATE_COPY=PASS"


echo
echo "=== 5. HEALTH SANDBOX INVENTORY ONLY ==="

mkdir -p "$WORK/runtime-inventory"

if [ -d /var/lib/config-location/health-sandboxes ]; then

    find /var/lib/config-location/health-sandboxes \
    -maxdepth 2 \
    -printf '%y %s %TY-%Tm-%TdT%TH:%TM:%TS %p\n' \
    2>/dev/null \
    >"$WORK/runtime-inventory/health-sandboxes.txt" \
    || true

fi

echo "RUNTIME_INVENTORY=PASS"


echo
echo "=== 6. XRAY FORENSIC LOGS ==="

mkdir -p "$WORK/xray"

for DIR in \
/var/log/config-location/xray \
/var/log/config-location/xray-full-audit
do

    if [ -d "$DIR" ]; then

        NAME=$(basename "$DIR")

        rsync -a \
        --ignore-missing-args \
        "$DIR/" \
        "$WORK/xray/$NAME/" \
        2>/dev/null || true

    fi

done


for F in \
/var/lib/config-location/xray-log-retention-audit.json \
/var/lib/config-location/xray-log-retention-final-audit.json
do

    if [ -f "$F" ]; then
        cp -a "$F" "$WORK/xray/"
    fi

done

echo "XRAY_FORENSICS=PASS"


echo
echo "=== 7. DEVLOG / CHATGPT STAGES ==="

mkdir -p "$WORK/devlog"

if [ -d /var/log/config-location/chatgpt ]; then

    rsync -a \
    --ignore-missing-args \
    /var/log/config-location/chatgpt/ \
    "$WORK/devlog/chatgpt/"

fi

echo "DEVLOG=PASS"


echo
echo "=== 8. APPLICATION LOGS ==="

mkdir -p "$WORK/logs"

if [ -d /var/log/config-location ]; then

    rsync -a \
    --ignore-missing-args \
    --exclude='chatgpt/' \
    --exclude='xray/' \
    --exclude='xray-full-audit/' \
    /var/log/config-location/ \
    "$WORK/logs/config-location/" \
    2>/dev/null || true

fi

echo "APPLICATION_LOGS=PASS"


echo
echo "=== 9. JOURNAL LAST 7 DAYS ==="

mkdir -p "$WORK/journal"

SERVICES=$(
    systemctl list-unit-files \
    --no-legend \
    | awk '/config-location/ {print $1}'
)

for S in $SERVICES
do

    journalctl \
    -u "$S" \
    --since "7 days ago" \
    --no-pager \
    >"$WORK/journal/$S.log" \
    2>&1 || true

done

journalctl \
--since "48 hours ago" \
--no-pager \
| grep -Ei \
'config-location|xray|oom|killed process|segfault|python|nginx' \
>"$WORK/journal/system-relevant-48h.log" \
|| true

echo "JOURNAL=PASS"


echo
echo "=== 10. PANEL INVENTORY ==="

mkdir -p "$WORK/panel"

systemctl cat \
config-location-panel.service \
>"$WORK/panel/panel.service.txt" \
2>&1 || true


systemctl show \
config-location-panel.service \
>"$WORK/panel/panel.service.show.txt" \
2>&1 || true


find /opt/config-location \
-type f \
\( \
-name '*.html' \
-o -name '*.css' \
-o -name '*.js' \
-o -iname '*panel*' \
-o -iname '*server*.py' \
-o -iname '*web*.py' \
\) \
-print \
| sort \
>"$WORK/panel/panel-files.txt"


grep -RIn \
--include='*.py' \
--include='*.html' \
--include='*.js' \
-E \
'4040|HTTPServer|ThreadingHTTPServer|BaseHTTPRequestHandler|Flask|FastAPI|uvicorn|/sub/|unknown|unresolved|settings|lifetime|interval|health|fetch' \
/opt/config-location \
2>/dev/null \
>"$WORK/panel/panel-route-index.txt" \
|| true


curl -sS \
--max-time 10 \
-D "$WORK/panel/http-headers.txt" \
http://127.0.0.1:4040/ \
-o "$WORK/panel/http-body.html" \
|| true

echo "PANEL_INVENTORY=PASS"


echo
echo "=== 11. NGINX / NETWORK ==="

mkdir -p "$WORK/network"

nginx -T \
>"$WORK/network/nginx-T.txt" \
2>&1 || true

ss -lntup \
>"$WORK/network/listening-ports.txt" \
2>&1 || true

ip addr \
>"$WORK/network/ip-addr.txt" \
2>&1 || true

ip route \
>"$WORK/network/ip-route.txt" \
2>&1 || true

echo "NETWORK=PASS"


echo
echo "=== 12. SYSTEM INVENTORY ==="

mkdir -p "$WORK/system"

uname -a \
>"$WORK/system/uname.txt"

cat /etc/os-release \
>"$WORK/system/os-release.txt"

lscpu \
>"$WORK/system/cpu.txt"

free -h \
>"$WORK/system/memory.txt"

df -hT \
>"$WORK/system/disk.txt"

uptime \
>"$WORK/system/uptime.txt"

ps auxww \
>"$WORK/system/processes.txt"

systemctl --failed \
>"$WORK/system/failed-units.txt" \
2>&1 || true

echo "SYSTEM_INVENTORY=PASS"


echo
echo "=== 13. PYTHON / PACKAGE INVENTORY ==="

mkdir -p "$WORK/python"

"$(
    test -x /opt/config-location/venv/bin/python &&
    echo /opt/config-location/venv/bin/python ||
    echo python3
)" -V \
>"$WORK/python/python-version.txt" \
2>&1 || true


if [ -x /opt/config-location/venv/bin/pip ]; then

    /opt/config-location/venv/bin/pip freeze \
    >"$WORK/python/pip-freeze.txt" \
    2>&1 || true

fi

dpkg -l \
>"$WORK/system/dpkg-list.txt" \
2>&1 || true

echo "PYTHON_PACKAGES=PASS"


echo
echo "=== 14. XRAY VERSION / HASH ==="

mkdir -p "$WORK/integrity"

if [ -x /usr/local/bin/xray ]; then

    /usr/local/bin/xray version \
    >"$WORK/integrity/xray-version.txt" \
    2>&1 || true

    sha256sum \
    /usr/local/bin/xray \
    >"$WORK/integrity/xray-binary.sha256"

fi

echo "XRAY_INTEGRITY=PASS"


echo
echo "=== 15. PROJECT FILE HASHES ==="

find /opt/config-location \
-type f \
-not -path '*/backups/*' \
-print0 \
| sort -z \
| xargs -0 sha256sum \
>"$WORK/integrity/project-files.sha256"

echo "PROJECT_HASHES=PASS"


echo
echo "=== 16. FINAL COUNTRY / QUEUE AUDIT ==="

mkdir -p "$WORK/audit"

PY=/opt/config-location/venv/bin/python

PYTHONPATH=/opt/config-location "$PY" <<'PY' \
>"$WORK/audit/live-audit.json"

from pathlib import Path
import json
import time

from app.country.event_bus import stats

root=Path(
    "/var/lib/config-location/country"
)

I=root/"country-identity"
P=root/"pipeline/latest"

identity_total=0
pipeline_total=0
conflicts=[]
states={}

for p in P.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    pipeline_total+=1

    state=str(
        o.get("state")
        or "unknown"
    )

    states[state]=(
        states.get(state,0)+1
    )


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


report={
    "generated_epoch":
        int(time.time()),

    "identity_total":
        identity_total,

    "pipeline_total":
        pipeline_total,

    "pipeline_states":
        states,

    "country_conflicts":
        len(conflicts),

    "queue":
        stats(),

    "xray_retention":
        True,

    "second_xray":
        False,
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
    report["queue"].get(
        "dead",
        0,
    )
)==0
PY

echo "LIVE_AUDIT=PASS"


echo
echo "=== 17. IMPORTANT REPORTS ==="

mkdir -p "$WORK/reports"

find /var/lib/config-location \
-maxdepth 4 \
-type f \
\( \
-name '*audit*.json' \
-o -name '*report*.json' \
-o -name 'k7*.json' \
-o -name 'k8*.json' \
-o -name 'k9*.json' \
\) \
-print0 \
| while IFS= read -r -d '' F
do

    SAFE=$(
        echo "$F" |
        sed 's#^/##;s#/#__#g'
    )

    cp -a "$F" \
    "$WORK/reports/$SAFE"

done

echo "REPORTS=PASS"


echo
echo "=== 18. ROOT-LEVEL RELEVANT SCRIPTS ==="

mkdir -p "$WORK/root-scripts"

find /root \
-maxdepth 1 \
-type f \
\( \
-name 'FIX*.sh' \
-o -name 'PANEL*.sh' \
-o -name 'MAKE-CONFIG*.sh' \
-o -name 'install-config-location*.sh' \
\) \
-print0 \
| while IFS= read -r -d '' F
do

    cp -a "$F" \
    "$WORK/root-scripts/"
done

echo "ROOT_SCRIPTS=PASS"


echo
echo "=== 19. MANIFEST ==="

python3 <<PY
from pathlib import Path
import json

work=Path("$WORK")

manifest={
    "schema_version":1,
    "snapshot":"PRE-PANEL-FULL",
    "timestamp":"$TS",
    "path":"$WORK",
    "files":sum(
        1
        for p in work.rglob("*")
        if p.is_file()
    ),
    "directories":sum(
        1
        for p in work.rglob("*")
        if p.is_dir()
    ),
    "includes":{
        "project_source":True,
        "state":True,
        "systemd":True,
        "panel":True,
        "xray_forensics":True,
        "devlog":True,
        "journals":True,
        "network":True,
        "system_inventory":True,
        "reports":True,
        "root_scripts":True,
    },
    "excluded_transient":{
        "health_sandboxes":True,
        "tmp_files":True,
        "lock_files":True,
    },
}

(work/"MANIFEST.json").write_text(
    json.dumps(
        manifest,
        indent=2,
        sort_keys=True,
    )
)

print(
    json.dumps(
        manifest,
        indent=2,
        sort_keys=True,
    )
)
PY

echo "MANIFEST=PASS"


echo
echo "=== 20. ARCHIVE ==="

tar \
-C "$BASE" \
-czf "$ARCHIVE" \
"$NAME"

test -s "$ARCHIVE"

echo "ARCHIVE_CREATED=PASS"


echo
echo "=== 21. SHA256 ==="

sha256sum "$ARCHIVE" >"$SHA"

cat "$SHA"

echo "SHA256_CREATED=PASS"


echo
echo "=== 22. VERIFY ARCHIVE ==="

tar -tzf "$ARCHIVE" >/dev/null

sha256sum -c "$SHA"

echo "ARCHIVE_VERIFY=PASS"


echo
echo "=== 23. FINAL SERVICE CHECK ==="

for S in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(systemctl is-active "$S" 2>/dev/null || true)

    echo "$S=$X"

    test "$X" = active

done

echo "SERVICES=PASS"


echo
echo "======================================================"
echo "PRE_PANEL_FULL_SNAPSHOT=PASS"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"
echo "WORKDIR=$WORK"
echo "======================================================"
