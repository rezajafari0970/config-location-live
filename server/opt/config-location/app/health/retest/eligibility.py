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
