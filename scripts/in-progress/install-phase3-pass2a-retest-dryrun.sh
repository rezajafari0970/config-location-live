#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass2a-retest-eligibility-dryrun"
PROJECT="/opt/config-location"
REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
DRYRUN="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p "$RUN_DIR" "$REPORT_DIR" "$DISCOVERY_DIR" "$BACKUP_DIR"

RESULT="SUCCESS"
ERRORS=""

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
  RESULT="FAILED"
  ERRORS="${ERRORS}\n$1"
  echo "ERROR: $1"
}

finish() {
  CODE=$?

  if [ "$CODE" -ne 0 ]; then
    RESULT="FAILED"
    ERRORS="${ERRORS}\nscript exit code $CODE"
  fi

  cat > "$REPORT" <<REPORT
CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Mode:
DRY RUN ONLY

Production execution:
DISABLED

Health mutation:
NONE

Dryrun:
$DRYRUN

Backup:
$BACKUP_DIR

Log:
$LOG

Errors:
$ERRORS
REPORT

  exec 1>&-
  exec 2>&-
  exec 3>&-

  sleep 1

  cd "$REPO" || exit 1

  git add "$LOG" "$REPORT" "$DRYRUN" >/dev/null 2>&1 || true

  if ! git diff --cached --quiet; then
    git commit -m "Phase execution $PHASE $TS" >/dev/null 2>&1 || true
  fi

  git push origin main >/dev/null 2>&1 || true

  [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT

echo "================================================"
echo " PHASE 3 PASS 2A"
echo " RETEST ELIGIBILITY DRY RUN"
echo "================================================"

echo "START=$START"
echo "HOST=$(hostname)"

test -x "$PROJECT/venv/bin/python" || {
  fail "venv python missing"
  exit 1
}

test -f "$PROJECT/app/settings/engine.py" || {
  fail "settings engine missing"
  exit 1
}

test -f "$PROJECT/app/health/core/models.py" || {
  fail "health models missing"
  exit 1
}

echo
echo "========== BACKUP =========="

if [ -d "$PROJECT/app/health/retest" ]; then
  cp -a "$PROJECT/app/health/retest" "$BACKUP_DIR/retest.before"
fi

mkdir -p "$PROJECT/app/health/retest"

cat > "$PROJECT/app/health/retest/__init__.py" <<'PY'
from .eligibility import build_retest_plan
__all__ = ["build_retest_plan"]
PY

cat > "$PROJECT/app/health/retest/eligibility.py" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path

from app.settings.engine import get_settings


ROOTS = (
    Path("/var/lib/config-location/health-results"),
    Path("/var/lib/config-location/health"),
    Path("/var/lib/config-location/health-scheduler"),
    Path("/opt/config-location/health-results"),
)


def _parse_time(value):
    if not isinstance(value, str) or not value.strip():
        return None

    try:
        dt = datetime.fromisoformat(
            value.strip().replace("Z", "+00:00")
        )
    except ValueError:
        return None

    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)

    return dt.astimezone(timezone.utc)


def _state(record):
    return str(
        record.get("state")
        or record.get("health_state")
        or ""
    ).strip().lower()


def _cid(record):
    value = record.get("config_id")
    if value is None:
        return None
    value = str(value).strip()
    return value or None


def _ctype(record):
    return str(
        record.get("config_type")
        or record.get("type")
        or record.get("protocol")
        or "unknown"
    ).strip().lower()


def _finished(record):
    for key in (
        "finished_at",
        "last_health_at",
        "checked_at",
        "updated_at",
        "timestamp",
    ):
        value = record.get(key)
        if _parse_time(value) is not None:
            return value
    return None


def _iter_records():
    seen_paths = set()

    for root in ROOTS:
        if not root.exists():
            continue

        for path in root.rglob("*.json"):
            spath = str(path)

            if spath in seen_paths:
                continue

            seen_paths.add(spath)

            try:
                if path.stat().st_size > 8_000_000:
                    continue

                data = json.loads(
                    path.read_text(
                        encoding="utf-8",
                        errors="replace",
                    )
                )
            except Exception:
                continue

            if isinstance(data, dict):
                yield path, data

                for key in ("results", "records", "items", "health"):
                    value = data.get(key)

                    if isinstance(value, list):
                        for item in value:
                            if isinstance(item, dict):
                                yield path, item

            elif isinstance(data, list):
                for item in data:
                    if isinstance(item, dict):
                        yield path, item


def _inflight():
    ids = set()

    for path in (
        Path("/var/lib/config-location/health-scheduler/state.json"),
        Path("/var/lib/config-location/health-scheduler/cursor.json"),
    ):
        if not path.exists():
            continue

        try:
            data = json.loads(path.read_text())
        except Exception:
            continue

        def walk(value):
            if isinstance(value, dict):
                state = str(value.get("state", "")).lower()
                cid = value.get("config_id")

                if cid and state in {
                    "queued",
                    "running",
                    "leased",
                    "in_flight",
                }:
                    ids.add(str(cid))

                for child in value.values():
                    walk(child)

            elif isinstance(value, list):
                for child in value:
                    walk(child)

        walk(data)

    return ids


def build_retest_plan(limit=100):
    settings = get_settings()

    section = settings.get("health_retest", {})
    minutes = int(section.get("retest_minutes", 5))
    minutes = max(1, min(minutes, 1440))

    interval = minutes * 60
    now = datetime.now(timezone.utc)
    inflight = _inflight()

    latest = {}

    scanned = 0
    healthy = 0
    invalid = 0
    duplicates = 0

    for path, record in _iter_records():
        scanned += 1

        if _state(record) != "healthy":
            continue

        healthy += 1

        cid = _cid(record)
        finished_raw = _finished(record)

        if not cid or not finished_raw:
            invalid += 1
            continue

        finished = _parse_time(finished_raw)

        if finished is None:
            invalid += 1
            continue

        old = latest.get(cid)

        if old is not None:
            duplicates += 1

        if old is None or finished > old["finished"]:
            latest[cid] = {
                "finished": finished,
                "record": record,
                "path": path,
            }

    due = []

    for cid, item in latest.items():
        if cid in inflight:
            continue

        age = (now - item["finished"]).total_seconds()

        if age < interval:
            continue

        due.append(
            {
                "config_id": cid,
                "config_type": _ctype(item["record"]),
                "state": "healthy",
                "last_finished_at":
                    item["finished"].isoformat(),
                "age_seconds": int(age),
                "interval_seconds": interval,
                "record_path": str(item["path"]),
            }
        )

    due.sort(
        key=lambda x: (
            -x["age_seconds"],
            x["config_id"],
        )
    )

    return {
        "mode": "dry_run",
        "generated_at": now.isoformat(),
        "retest_minutes": minutes,
        "interval_seconds": interval,
        "scanned_records": scanned,
        "healthy_records": healthy,
        "unique_healthy": len(latest),
        "duplicate_records": duplicates,
        "invalid_records": invalid,
        "inflight_ids": len(inflight),
        "due_total": len(due),
        "candidate_count": min(len(due), limit),
        "candidates": due[:limit],
        "production_execution": False,
        "health_state_mutation": False,
    }
PY

echo "RETEST_MODULE_INSTALLED"

echo
echo "========== COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/retest/__init__.py \
  app/health/retest/eligibility.py

echo "COMPILE_OK"

echo
echo "========== DRY RUN =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<PY > "$DRYRUN"
import json
from app.health.retest import build_retest_plan

plan = build_retest_plan(limit=100)

print(
    json.dumps(
        plan,
        ensure_ascii=False,
        indent=2,
    )
)
PY

test -s "$DRYRUN" || {
  fail "dryrun file empty"
  exit 1
}

"$PROJECT/venv/bin/python" - "$DRYRUN" <<'PY'
import json
import sys

p = sys.argv[1]

data = json.load(open(p))

assert data["mode"] == "dry_run"
assert data["production_execution"] is False
assert data["health_state_mutation"] is False
assert data["retest_minutes"] >= 1

print("DRYRUN_VALID")
print("RETEST_MINUTES=", data["retest_minutes"])
print("SCANNED=", data["scanned_records"])
print("HEALTHY=", data["healthy_records"])
print("UNIQUE_HEALTHY=", data["unique_healthy"])
print("DUE_TOTAL=", data["due_total"])
print("CANDIDATES=", data["candidate_count"])
PY

echo
echo "========== SAMPLE =========="

"$PROJECT/venv/bin/python" - "$DRYRUN" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))

for row in data["candidates"][:15]:
    print(
        row["config_id"],
        row["config_type"],
        row["age_seconds"],
        row["last_finished_at"],
    )
PY

echo
echo "========== SAFETY =========="

echo "PRODUCTION_EXECUTION=DISABLED"
echo "HEALTH_STATE_MUTATION=NONE"
echo "SERVICE_RESTART=NONE"

echo
echo "PHASE3_PASS2A_SUCCESS"

RESULT="SUCCESS"
