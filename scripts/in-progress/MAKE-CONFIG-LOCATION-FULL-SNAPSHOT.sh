#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=/opt/config-location
STATE=/var/lib/config-location
LOGROOT=/var/log/config-location
OUTROOT=/root/snapshots

STAMP=$(date -u +%Y%m%d-%H%M%S)
NAME="config-location-FULL-FORENSIC-$STAMP"
WORK="$OUTROOT/$NAME"
ARCHIVE="$OUTROOT/$NAME.tar.gz"
SHA="$ARCHIVE.sha256"

mkdir -p \
"$WORK/project" \
"$WORK/state" \
"$WORK/logs" \
"$WORK/systemd" \
"$WORK/runtime" \
"$WORK/root-scripts" \
"$WORK/packages" \
"$WORK/network" \
"$WORK/reports" \
"$WORK/manifests" \
"$WORK/xray-forensics" \
"$WORK/xray-forensics/files" \
"$WORK/xray-forensics/sandboxes" \
"$WORK/xray-forensics/error-configs"

echo "======================================================"
echo "CONFIG LOCATION — FULL FORENSIC SNAPSHOT"
echo "STAMP=$STAMP"
echo "WORK=$WORK"
echo "======================================================"

echo
echo "=== 1. PROJECT SOURCE — COMPLETE ==="

cp -a "$PROJECT" "$WORK/project/config-location"

echo "PROJECT_COPY=PASS"


echo
echo "=== 2. RUNTIME STATE — COMPLETE ==="

mkdir -p "$WORK/state/config-location"

tar \
    -C "$STATE" \
    --exclude='*.tmp' \
    --exclude='.*.tmp' \
    --exclude='*.lock' \
    --ignore-failed-read \
    -cf - . \
| tar \
    -C "$WORK/state/config-location" \
    -xf -

echo "STATE_COPY=PASS"
echo "STATE_COPY_MODE=LIVE_RACE_SAFE_TAR"
echo "TRANSIENT_TMP_EXCLUDED=YES"


echo
echo "=== 3. PROJECT LOGS — COMPLETE ==="

if [ -d "$LOGROOT" ]; then
    cp -a "$LOGROOT" "$WORK/logs/config-location"
fi

echo "LOG_COPY=PASS"


echo
echo "=== 4. ALL DEVELOPMENT / FIX SCRIPTS ==="

find /root \
    -maxdepth 1 \
    -type f \
    \( \
        -name 'FIX*.sh' \
        -o -name '*FIX*.sh' \
        -o -name 'install*.sh' \
        -o -name '*config-location*.sh' \
        -o -name '*snapshot*.sh' \
        -o -name '*SNAPSHOT*.sh' \
    \) \
    -print0 \
| while IFS= read -r -d '' f
do
    cp -a "$f" "$WORK/root-scripts/"
done

echo "ROOT_SCRIPTS_COPY=PASS"


echo
echo "=== 5. ROOT DEVELOPMENT ARTIFACT INDEX ==="

find /root \
    -maxdepth 2 \
    -printf '%M %u %g %s %TY-%Tm-%TdT%TH:%TM:%TS %p\n' \
    2>/dev/null \
    >"$WORK/reports/root-file-index.txt" || true

echo "ROOT_INDEX=PASS"


echo
echo "=== 6. SYSTEMD UNIT FILES ==="

systemctl list-unit-files \
    --no-pager \
    >"$WORK/systemd/all-unit-files.txt"

systemctl list-units \
    --all \
    --no-pager \
    >"$WORK/systemd/all-units.txt"

systemctl list-unit-files \
    --no-pager \
| grep -E \
'config-location|config-country' \
    >"$WORK/systemd/project-unit-files.txt" \
    || true

systemctl list-units \
    --all \
    --no-pager \
| grep -E \
'config-location|config-country' \
    >"$WORK/systemd/project-units.txt" \
    || true


mapfile -t SERVICES < <(
    systemctl list-unit-files \
        --no-legend \
        --no-pager \
    | awk '{print $1}' \
    | grep -E \
      'config-location|config-country' \
    | sort -u
)

for svc in "${SERVICES[@]}"
do
    SAFE=$(
        printf '%s' "$svc" \
        | tr '/@' '__'
    )

    {
        echo "===== SYSTEMCTL CAT ====="
        systemctl cat "$svc" || true

        echo
        echo "===== SYSTEMCTL STATUS ====="
        systemctl status \
            "$svc" \
            --no-pager -l || true

        echo
        echo "===== SYSTEMCTL SHOW ====="
        systemctl show "$svc" || true

    } >"$WORK/systemd/$SAFE.txt" 2>&1
done

echo "SYSTEMD_CAPTURE=PASS"


echo
echo "=== 7. JOURNAL — PROJECT SERVICES ==="

for svc in "${SERVICES[@]}"
do
    SAFE=$(
        printf '%s' "$svc" \
        | tr '/@' '__'
    )

    journalctl \
        -u "$svc" \
        --no-pager \
        -o short-precise \
        >"$WORK/logs/journal-$SAFE.log" \
        2>&1 || true
done

echo "JOURNAL_CAPTURE=PASS"


echo
echo "=== 8. PROCESS / RESOURCE SNAPSHOT ==="

ps auxww \
    >"$WORK/runtime/ps-auxww.txt"

ps -ef --forest \
    >"$WORK/runtime/process-tree.txt"

top -b -n1 \
    >"$WORK/runtime/top.txt" \
    2>&1 || true

free -h \
    >"$WORK/runtime/free.txt"

df -hT \
    >"$WORK/runtime/df.txt"

df -i \
    >"$WORK/runtime/df-inodes.txt"

uptime \
    >"$WORK/runtime/uptime.txt"

cat /proc/loadavg \
    >"$WORK/runtime/loadavg.txt"

echo "RUNTIME_CAPTURE=PASS"


echo
echo "=== 9. NETWORK / PORT STATE ==="

ss -lntup \
    >"$WORK/network/ss-lntup.txt" \
    2>&1 || true

ss -s \
    >"$WORK/network/ss-summary.txt" \
    2>&1 || true

ip addr show \
    >"$WORK/network/ip-addr.txt"

ip route show \
    >"$WORK/network/ip-route.txt"

ip rule show \
    >"$WORK/network/ip-rule.txt"

cat /etc/resolv.conf \
    >"$WORK/network/resolv.conf.txt" \
    2>/dev/null || true

echo "NETWORK_CAPTURE=PASS"


echo
echo "=== 10. NGINX PROJECT CONFIG ==="

nginx -T \
    >"$WORK/reports/nginx-T.txt" \
    2>&1 || true

nginx -t \
    >"$WORK/reports/nginx-test.txt" \
    2>&1 || true

echo "NGINX_CAPTURE=PASS"


echo
echo "=== 11. OS / KERNEL / PYTHON ==="

{
    echo "===== DATE ====="
    date -u --iso-8601=seconds

    echo
    echo "===== HOSTNAME ====="
    hostnamectl || true

    echo
    echo "===== OS ====="
    cat /etc/os-release

    echo
    echo "===== KERNEL ====="
    uname -a

    echo
    echo "===== CPU ====="
    lscpu

} >"$WORK/reports/system-info.txt" 2>&1


{
    python3 --version || true

    "$PROJECT/venv/bin/python" \
        --version || true

    "$PROJECT/venv/bin/pip" \
        freeze || true

} >"$WORK/packages/python-environment.txt" 2>&1


dpkg-query \
    -W \
    -f='${binary:Package}\t${Version}\n' \
    >"$WORK/packages/dpkg-packages.txt" \
    2>/dev/null || true

echo "SYSTEM_ENVIRONMENT=PASS"


echo
echo "=== 12. XRAY INFORMATION ==="

{
    echo "===== XRAY PATHS ====="

    command -v xray || true

    find \
        "$PROJECT" \
        /usr/local/bin \
        /usr/bin \
        -maxdepth 4 \
        -type f \
        -iname '*xray*' \
        -print \
        2>/dev/null || true

    echo
    echo "===== XRAY VERSION ====="

    xray version 2>&1 || true

} >"$WORK/reports/xray-info.txt"

echo "XRAY_CAPTURE=PASS"


echo
echo "=== 13. HEALTH FORENSIC SUMMARY ==="

python3 <<'PY' >"$WORK/reports/health-summary.txt"
from pathlib import Path
from collections import Counter
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

states=Counter()
types=Counter()
qualified=0
transfer_ok=0
corrupt=0
total=0

for p in H.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        corrupt+=1
        continue

    total+=1

    states[
        str(
            o.get(
                "state",
                "unknown",
            )
        )
    ]+=1

    types[
        str(
            o.get(
                "config_type",
                "unknown",
            )
        )
    ]+=1

    d=(
        (
            o.get("metadata")
            or {}
        ).get(
            "health_decision"
        )
        or {}
    )

    if (
        str(
            o.get(
                "state",
                "",
            )
        ).lower()=="healthy"
        and
        o.get(
            "xray_started"
        ) is True
        and
        o.get(
            "download_verified"
        ) is True
        and
        o.get(
            "upload_verified"
        ) is True
    ):
        transfer_ok+=1

    if (
        isinstance(d,dict)
        and d.get(
            "healthy"
        ) is True
        and d.get(
            "xray_ok"
        ) is True
        and d.get(
            "download_ok"
        ) is True
        and d.get(
            "upload_ok"
        ) is True
    ):
        qualified+=1


print("TOTAL=",total)
print("CORRUPT=",corrupt)
print("STATES=",dict(states))
print("TYPES=",dict(types))
print("REAL_TRANSFER_OK=",transfer_ok)
print("DECISION_QUALIFIED=",qualified)
PY

echo "HEALTH_SUMMARY=PASS"


echo
echo "=== 14. COUNTRY FORENSIC SUMMARY ==="

python3 <<'PY' >"$WORK/reports/country-summary.txt"
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

states=Counter()
countries=Counter()
reasons=Counter()

total=0
corrupt=0

for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        corrupt+=1
        continue

    total+=1

    states[
        str(
            o.get(
                "state",
                "unknown",
            )
        )
    ]+=1

    code=o.get(
        "country_code"
    )

    if code:
        countries[
            str(code)
        ]+=1

    reason=(
        o.get(
            "reason"
        )
        or
        o.get(
            "recovery_reason"
        )
    )

    if reason:
        reasons[
            str(reason)
        ]+=1


print("TOTAL=",total)
print("CORRUPT=",corrupt)
print("STATES=",dict(states))
print("COUNTRIES=",dict(countries))
print("REASONS=",dict(reasons))
PY

echo "COUNTRY_SUMMARY=PASS"


echo
echo "=== 15. EVENT BUS FORENSIC SUMMARY ==="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" <<'PY' \
>"$WORK/reports/event-bus-summary.txt" \
2>&1

from pathlib import Path
from collections import Counter
import json

from app.country.event_bus import (
    stats,
)

print(
    "QUEUE_STATS=",
    stats(),
)

M=Path(
    "/var/lib/config-location/country/"
    "event-bus/producer-metrics.jsonl"
)

c=Counter()

rows=0

if M.exists():

    for line in M.read_text().splitlines():

        try:
            o=json.loads(line)
        except Exception:
            continue

        rows+=1

        c[
            str(
                o.get(
                    "status",
                    "unknown",
                )
            )
        ]+=1


print(
    "PRODUCER_ROWS=",
    rows,
)

print(
    "PRODUCER_STATUS=",
    dict(c),
)
PY

echo "EVENT_BUS_SUMMARY=PASS"


echo
echo "=== 16. DEVELOPMENT STAGE INDEX ==="

if [ -d \
    /var/log/config-location/chatgpt/stages \
]; then

    find \
        /var/log/config-location/chatgpt/stages \
        -maxdepth 1 \
        -type f \
        -name '*.log' \
        -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %f\n' \
        | sort \
        >"$WORK/reports/stage-index.txt"

    grep -R \
        -h \
        -E \
        '^STAGE=|^EXIT_CODE=|^DEVLOG_RESULT=' \
        /var/log/config-location/chatgpt/stages \
        >"$WORK/reports/stage-results-raw.txt" \
        2>/dev/null || true
fi

echo "STAGE_INDEX=PASS"



echo
echo "=== 16.5 XRAY FULL FORENSICS ==="

XRAYF="$WORK/xray-forensics"
export XRAYF

mkdir -p \
    "$XRAYF/files" \
    "$XRAYF/sandboxes" \
    "$XRAYF/error-configs"

echo "=== XRAY FILE DISCOVERY ===" \
    >"$XRAYF/xray-file-index.txt"

find \
    "$PROJECT" \
    "$STATE" \
    "$LOGROOT" \
    /tmp \
    -xdev \
    -type f \
    \( \
        -iname '*xray*' \
        -o -iname '*stderr*' \
        -o -iname '*stdout*' \
        -o -iname '*warning*' \
        -o -iname '*error*.log' \
    \) \
    -print \
    2>/dev/null \
    >>"$XRAYF/xray-file-index.txt" || true


echo "=== HEALTH SANDBOX INDEX ===" \
    >"$XRAYF/sandbox-index.txt"

if [ -d /var/lib/config-location/health-sandboxes ]; then

    find \
        /var/lib/config-location/health-sandboxes \
        -printf '%M %u %g %s %TY-%Tm-%TdT%TH:%TM:%TS %p\n' \
        2>/dev/null \
        >>"$XRAYF/sandbox-index.txt" || true

    cp -a \
        /var/lib/config-location/health-sandboxes \
        "$XRAYF/sandboxes/" \
        2>/dev/null || true
fi


echo "=== XRAY WARNING / ERROR CORRELATION ==="

python3 <<'PYXRAY'
from pathlib import Path
from collections import Counter
import json
import shutil

root=Path("/var/lib/config-location")
import os
out=Path(os.environ["XRAYF"])

health=root/"health-results/latest"
sand=root/"health-sandboxes"

error_root=out/"error-configs"
error_root.mkdir(
    parents=True,
    exist_ok=True,
)

summary=[]
states=Counter()
error_codes=Counter()

for hp in health.glob("*.json"):

    try:
        h=json.loads(
            hp.read_text()
        )
    except Exception:
        continue

    cid=str(
        h.get("config_id")
        or hp.stem
    )

    state=str(
        h.get(
            "state",
            "unknown",
        )
    )

    states[state]+=1

    error_code=h.get(
        "error_code"
    )

    error_message=h.get(
        "error_message"
    )

    if error_code:
        error_codes[
            str(error_code)
        ]+=1

    # Preserve every non-healthy result plus any result
    # carrying an explicit error.
    interesting=(
        state!="healthy"
        or bool(error_code)
        or bool(error_message)
    )

    if not interesting:
        continue

    target=error_root/cid
    target.mkdir(
        parents=True,
        exist_ok=True,
    )

    shutil.copy2(
        hp,
        target/"health-result.json",
    )

    candidates=[]

    if sand.exists():

        for p in sand.glob(
            f"*{cid}*"
        ):
            candidates.append(p)

        for p in sand.glob(
            "country-*"
        ):
            if cid in p.name:
                candidates.append(p)

    copied=[]

    seen=set()

    for src in candidates:

        try:
            real=str(
                src.resolve()
            )
        except Exception:
            real=str(src)

        if real in seen:
            continue

        seen.add(real)

        dst=target/"sandbox"/src.name

        try:
            if src.is_dir():
                shutil.copytree(
                    src,
                    dst,
                    dirs_exist_ok=True,
                )
            elif src.is_file():
                dst.parent.mkdir(
                    parents=True,
                    exist_ok=True,
                )
                shutil.copy2(
                    src,
                    dst,
                )

            copied.append(
                str(src)
            )

        except Exception:
            pass

    summary.append({
        "config_id":cid,
        "state":state,
        "error_code":error_code,
        "error_message":error_message,
        "xray_started":
            h.get("xray_started"),
        "xray_exit_code":
            h.get("xray_exit_code"),
        "download_verified":
            h.get("download_verified"),
        "upload_verified":
            h.get("upload_verified"),
        "job_id":
            h.get("job_id"),
        "started_at":
            h.get("started_at"),
        "finished_at":
            h.get("finished_at"),
        "sandboxes":
            copied,
    })


(out/"error-config-index.json").write_text(
    json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )
)

(out/"error-config-summary.txt").write_text(
    "TOTAL_ERROR_OR_NONHEALTHY="
    +str(len(summary))
    +"\nSTATES="
    +repr(dict(states))
    +"\nERROR_CODES="
    +repr(dict(error_codes))
    +"\n"
)

print(
    "XRAY_ERROR_CONFIGS=",
    len(summary),
)

print(
    "XRAY_STATE_COUNTS=",
    dict(states),
)

print(
    "XRAY_ERROR_CODES=",
    dict(error_codes),
)
PYXRAY

echo "=== COPY DISCOVERED XRAY LOG FILES ==="

while IFS= read -r SRC
do
    [ -f "$SRC" ] || continue

    REL=$(
        printf '%s' "$SRC" \
        | sed 's#^/##'
    )

    DST="$XRAYF/files/$REL"

    mkdir -p "$(dirname "$DST")"

    cp -a \
        "$SRC" \
        "$DST" \
        2>/dev/null || true

done < <(
    find \
        "$PROJECT" \
        "$STATE" \
        "$LOGROOT" \
        /tmp \
        -xdev \
        -type f \
        \( \
            -iname '*xray*' \
            -o -iname '*stderr*' \
            -o -iname '*stdout*' \
            -o -iname '*warning*' \
            -o -iname '*error*.log' \
        \) \
        -print \
        2>/dev/null
)


echo "=== JOURNAL XRAY / WARNING / ERROR ==="

journalctl \
    --no-pager \
    -o short-precise \
    | grep -Ei \
      'config-location|xray|warning|warn|error|failed|timeout|sandbox' \
    >"$XRAYF/journal-xray-warning-error.log" \
    2>/dev/null || true


echo "=== PROJECT LOG XRAY SEARCH ==="

grep -RIn \
    -E \
    'xray|warning|warn|error|failed|timeout|stderr|exit.code|sandbox' \
    "$LOGROOT" \
    >"$XRAYF/project-xray-warning-error-index.txt" \
    2>/dev/null || true


echo "XRAY_FULL_FORENSICS=PASS"


echo
echo "=== 17. PROJECT FILE MANIFEST ==="

find "$WORK" \
    -type f \
    -printf '%P\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\n' \
    | sort \
    >"$WORK/manifests/files.tsv"

FILECOUNT=$(
    find "$WORK" \
        -type f \
        | wc -l
)

DIRCOUNT=$(
    find "$WORK" \
        -type d \
        | wc -l
)

BYTES=$(
    du -sb "$WORK" \
    | awk '{print $1}'
)

echo "FILES=$FILECOUNT" \
    >"$WORK/manifests/summary.txt"

echo "DIRECTORIES=$DIRCOUNT" \
    >>"$WORK/manifests/summary.txt"

echo "BYTES=$BYTES" \
    >>"$WORK/manifests/summary.txt"

echo "STAMP=$STAMP" \
    >>"$WORK/manifests/summary.txt"


echo
echo "=== 18. INTERNAL SHA256 MANIFEST ==="

(
    cd "$WORK"

    find . \
        -type f \
        ! -path './manifests/SHA256SUMS' \
        -print0 \
    | sort -z \
    | xargs -0 sha256sum
) >"$WORK/manifests/SHA256SUMS"

echo "INTERNAL_SHA256=PASS"


echo
echo "=== 19. ARCHIVE ==="

tar \
    -C "$OUTROOT" \
    -czf "$ARCHIVE" \
    "$NAME"

sha256sum "$ARCHIVE" \
    >"$SHA"

echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"


echo
echo "=== 20. ARCHIVE VERIFY ==="

tar -tzf "$ARCHIVE" \
    >/dev/null

(
    cd "$OUTROOT"
    sha256sum -c \
        "$(basename "$SHA")"
)

echo "ARCHIVE_VERIFY=PASS"


echo
echo "=== 21. FINAL SIZE ==="

ls -lh \
    "$ARCHIVE" \
    "$SHA"

echo
echo "=== 22. CORE SERVICES FINAL ==="

for svc in \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$svc" \
        2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active
done


echo
echo "======================================================"
echo "FULL_FORENSIC_SNAPSHOT=PASS"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"
echo "WORKDIR=$WORK"
echo "FILES=$FILECOUNT"
echo "DIRECTORIES=$DIRCOUNT"
echo "======================================================"
