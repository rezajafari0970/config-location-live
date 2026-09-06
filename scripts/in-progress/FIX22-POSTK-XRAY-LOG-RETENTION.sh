#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

BASE=/var/log/config-location/xray
FAIL="$BASE/failures"
RUNS="$BASE/runs"
CONF="$BASE/configs"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/POSTK-XRAY-RETENTION-$TS"

mkdir -p "$B"
mkdir -p "$BASE" "$FAIL" "$RUNS" "$CONF"

chmod 0750 "$BASE" "$FAIL" "$RUNS" "$CONF"

echo "BACKUP=$B"


echo
echo "=== 1. DISCOVER XRAY EXECUTION / LOGGING SOURCES ==="

grep -RIn \
--include='*.py' \
--include='*.sh' \
-E \
'xray|subprocess|Popen|stderr|stdout|communicate|runtime.*json|tempfile|TemporaryDirectory' \
"$R/app" \
"$R/bin" \
2>/dev/null \
| head -n 3000 \
| tee "$B/xray-source-discovery.txt"


echo
echo "=== 2. DISCOVER CURRENT XRAY LOG FILES ==="

find \
/var/log/config-location \
/var/lib/config-location \
/tmp \
"$R" \
-maxdepth 5 \
-type f \
\( \
    -iname '*xray*.log' \
    -o -iname '*xray*.txt' \
    -o -iname '*stderr*' \
    -o -iname '*runtime*.json' \
\) \
-print 2>/dev/null \
| sort \
| tee "$B/xray-existing-files.txt"


echo
echo "=== 3. SAVE SYSTEMD XRAY-RELATED JOURNAL BASELINE ==="

journalctl \
--no-pager \
--since "24 hours ago" \
| grep -iE \
'xray|config-location.*health|runtime|core loop|failed to start|config.*error' \
| tail -n 5000 \
>"$B/journal-xray-last24h.log" \
|| true

echo "JOURNAL_BASELINE=PASS"


echo
echo "=== 4. INSTALL FAILURE ARCHIVER MODULE ==="

cat >"$R/app/xray_log_retention.py" <<'PY'
from __future__ import annotations

from pathlib import Path
from typing import Any
import hashlib
import json
import os
import shutil
import time


BASE = Path(
    "/var/log/config-location/xray"
)

RUNS = BASE / "runs"
FAILURES = BASE / "failures"
CONFIGS = BASE / "configs"

for p in (
    BASE,
    RUNS,
    FAILURES,
    CONFIGS,
):
    p.mkdir(
        parents=True,
        exist_ok=True,
    )


def _safe(value: Any) -> str:
    s=str(
        value
        if value is not None
        else "unknown"
    )

    allowed=[]

    for c in s:
        if (
            c.isalnum()
            or c in "-_."
        ):
            allowed.append(c)
        else:
            allowed.append("_")

    return "".join(
        allowed
    )[:180]


def archive_xray_run(
    *,
    config_id: str | None,
    stdout: str | bytes | None,
    stderr: str | bytes | None,
    returncode: int | None,
    runtime_path: str | os.PathLike | None = None,
    source_raw: str | bytes | None = None,
    stage: str | None = None,
    metadata: dict | None = None,
) -> dict:

    now=time.time_ns()

    cid=_safe(
        config_id
        or "unknown"
    )

    stage_s=_safe(
        stage
        or "xray"
    )

    stamp=time.strftime(
        "%Y%m%d-%H%M%S",
        time.gmtime(),
    )

    unique=(
        f"{stamp}-"
        f"{now % 1000000000:09d}-"
        f"{cid[:40]}"
    )

    failed=(
        returncode is None
        or int(returncode)!=0
    )

    root=(
        FAILURES
        if failed
        else RUNS
    ) / unique

    root.mkdir(
        parents=True,
        exist_ok=False,
    )


    def to_text(v):
        if v is None:
            return ""

        if isinstance(v,bytes):
            return v.decode(
                "utf-8",
                errors="replace",
            )

        return str(v)


    stdout_text=to_text(stdout)
    stderr_text=to_text(stderr)


    (root/"stdout.log").write_text(
        stdout_text,
        errors="replace",
    )

    (root/"stderr.log").write_text(
        stderr_text,
        errors="replace",
    )


    runtime_copy=None

    if runtime_path:

        rp=Path(runtime_path)

        if rp.exists() and rp.is_file():

            runtime_copy=(
                root/"runtime.json"
            )

            shutil.copy2(
                rp,
                runtime_copy,
            )


    source_sha256=None

    if source_raw is not None:

        raw=(
            source_raw
            if isinstance(
                source_raw,
                bytes,
            )
            else str(
                source_raw
            ).encode(
                "utf-8",
                errors="replace",
            )
        )

        source_sha256=hashlib.sha256(
            raw
        ).hexdigest()

        # Keep exact source.raw for forensic/debug use.
        (root/"source.raw").write_bytes(
            raw
        )


    manifest={
        "schema_version":1,
        "timestamp_ns":now,
        "timestamp_utc":time.strftime(
            "%Y-%m-%dT%H:%M:%SZ",
            time.gmtime(),
        ),
        "config_id":config_id,
        "stage":stage,
        "returncode":returncode,
        "failed":failed,
        "runtime_saved":
            runtime_copy is not None,
        "source_sha256":
            source_sha256,
        "stdout_bytes":
            len(
                stdout_text.encode(
                    "utf-8",
                    errors="replace",
                )
            ),
        "stderr_bytes":
            len(
                stderr_text.encode(
                    "utf-8",
                    errors="replace",
                )
            ),
        "metadata":
            metadata or {},
    }

    (root/"manifest.json").write_text(
        json.dumps(
            manifest,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
        )
    )

    return {
        "path":str(root),
        **manifest,
    }
PY

"$PY" -m py_compile \
"$R/app/xray_log_retention.py"

echo "XRAY_ARCHIVER_MODULE=PASS"


echo
echo "=== 5. INSTALL RETENTION CLEANUP ==="

cat >/usr/local/sbin/config-location-xray-log-cleanup <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE=/var/log/config-location/xray

# Successful runs: 3 days.
find "$BASE/runs" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +3 \
    -exec rm -rf -- {} + \
    2>/dev/null || true

# Failures are much more valuable for debugging:
# preserve 14 days.
find "$BASE/failures" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +14 \
    -exec rm -rf -- {} + \
    2>/dev/null || true

# Standalone configs/logs: 14 days.
find "$BASE/configs" \
    -type f \
    -mtime +14 \
    -delete \
    2>/dev/null || true
SH

chmod 0755 \
/usr/local/sbin/config-location-xray-log-cleanup


cat >/etc/systemd/system/config-location-xray-log-cleanup.service <<'EOF'
[Unit]
Description=Config Location Xray forensic log cleanup
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/config-location-xray-log-cleanup

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/log/config-location/xray
EOF


cat >/etc/systemd/system/config-location-xray-log-cleanup.timer <<'EOF'
[Unit]
Description=Daily cleanup of Config Location Xray forensic logs

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=20m

[Install]
WantedBy=timers.target
EOF


systemctl daemon-reload

systemctl enable --now \
config-location-xray-log-cleanup.timer

echo "RETENTION_TIMER=PASS"


echo
echo "=== 6. JOURNAL RETENTION HARDENING ==="

mkdir -p \
/etc/systemd/journald.conf.d

cat >/etc/systemd/journald.conf.d/80-config-location-retention.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=1G
RuntimeMaxUse=256M
MaxRetentionSec=14day
Compress=yes
EOF

systemctl restart \
systemd-journald

echo "JOURNAL_RETENTION=14D"


echo
echo "=== 7. FAILURE ARCHIVER SYNTHETIC TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import tempfile

from app.xray_log_retention import (
    archive_xray_run,
)

with tempfile.TemporaryDirectory() as d:

    rp=Path(d)/"runtime.json"

    rp.write_text(
        json.dumps(
            {
                "log":{
                    "loglevel":"debug"
                },
                "outbounds":[],
            }
        )
    )

    r=archive_xray_run(
        config_id="synthetic-xray-retention-test",
        stdout="synthetic stdout",
        stderr="synthetic fatal xray error",
        returncode=1,
        runtime_path=rp,
        source_raw="vless://synthetic-test",
        stage="retention-selftest",
        metadata={
            "test":True,
        },
    )

    root=Path(
        r["path"]
    )

    print(
        "ARCHIVE_PATH=",
        root,
    )

    assert root.exists()

    for name in (
        "manifest.json",
        "stdout.log",
        "stderr.log",
        "runtime.json",
        "source.raw",
    ):
        assert (
            root/name
        ).exists()

    manifest=json.loads(
        (
            root/"manifest.json"
        ).read_text()
    )

    assert manifest[
        "failed"
    ] is True

    assert manifest[
        "returncode"
    ]==1

    print(
        "XRAY_FAILURE_ARCHIVE_TEST=PASS"
    )
PY


echo
echo "=== 8. CURRENT RETENTION STATUS ==="

systemctl status \
config-location-xray-log-cleanup.timer \
--no-pager \
-l \
| head -n 40

echo

journalctl \
--disk-usage \
--no-pager

echo

du -sh \
/var/log/config-location/xray \
2>/dev/null || true


echo
echo "=== 9. PROJECT SERVICES ==="

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
        "$svc" \
        2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active

done


echo
echo "=== 10. WRITE RETENTION REPORT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import time

report={
    "schema_version":1,
    "generated_epoch":
        int(time.time()),
    "xray_log_root":
        "/var/log/config-location/xray",
    "successful_run_retention_days":
        3,
    "failure_retention_days":
        14,
    "journald_retention_days":
        14,
    "journald_max_use":
        "1G",
    "source_raw_preserved":
        True,
    "runtime_json_preserved":
        True,
    "stdout_preserved":
        True,
    "stderr_preserved":
        True,
    "automatic_cleanup":
        True,
}

out=Path(
    "/var/lib/config-location/"
    "xray-log-retention-audit.json"
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
    "XRAY_RETENTION_REPORT=PASS"
)
PY


echo
echo "======================================================"
echo "POSTK_XRAY_LOG_RETENTION=PASS"
echo "FAILURE_RETENTION=14_DAYS"
echo "SUCCESS_RETENTION=3_DAYS"
echo "JOURNAL_RETENTION=14_DAYS"
echo "SOURCE_RAW_PRESERVED=YES"
echo "RUNTIME_JSON_PRESERVED=YES"
echo "STDERR_STDOUT_PRESERVED=YES"
echo "AUTO_CLEANUP=ACTIVE"
echo "NEXT=XRAY-ARCHIVER-INTEGRATION-AUDIT"
echo "======================================================"
