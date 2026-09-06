from __future__ import annotations

import hashlib
import json
import os

from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATE = Path(
    "/var/lib/config-location/health-lifecycle"
)

CONFIGS = Path(
    "/var/lib/config-location/configs"
)

SAFETY = STATE / "safety-latest.json"

OUTPUT = STATE / "enforcement-latest.json"

JOURNAL = STATE / "enforcement-journal"

MAX_CANARY = 1


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def load(path: Path) -> dict[str, Any]:
    obj = json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    if not isinstance(obj, dict):
        raise ValueError(
            f"object expected: {path}"
        )

    return obj


def sha256(path: Path) -> str:
    h = hashlib.sha256()

    with path.open("rb") as f:
        while True:
            block = f.read(1024 * 1024)

            if not block:
                break

            h.update(block)

    return h.hexdigest()


def atomic_write(
    path: Path,
    obj: dict[str, Any],
) -> None:

    tmp = path.with_name(
        "." + path.name + ".tmp"
    )

    tmp.write_text(
        json.dumps(
            obj,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ) + "\n",
        encoding="utf-8",
    )

    os.chown(
        tmp,
        -1,
        path.parent.stat().st_gid,
    )

    os.chmod(tmp, 0o640)

    os.replace(tmp, path)


def build() -> dict[str, Any]:

    safety = load(SAFETY)

    failed = list(
        safety.get(
            "failed_gates",
            []
        )
    )

    global_freeze = bool(
        safety.get(
            "global_freeze",
            True
        )
    )

    delete_allowed = bool(
        safety.get(
            "production_delete_allowed",
            False
        )
    )

    sample = safety.get(
        "future_enforcement_candidate_sample",
        []
    )

    if not isinstance(sample, list):
        sample = []


    candidates = []

    for item in sample:

        if not isinstance(item, dict):
            continue

        cid = str(
            item.get(
                "config_id",
                ""
            )
        )

        if not cid:
            continue

        path = CONFIGS / f"{cid}.json"

        if not path.is_file():
            continue

        candidates.append({
            "config_id": cid,

            "consecutive_unhealthy":
                int(
                    item.get(
                        "consecutive_unhealthy",
                        0
                    )
                ),

            "path":
                str(path),

            "sha256":
                sha256(path),
        })


    canary = candidates[:MAX_CANARY]


    # HT18.10A hard boundary:
    # even with healthy gates, mutation is forbidden.
    mutation_allowed = False


    if global_freeze:
        state = "hold"
        reason = "global_freeze"

    elif failed:
        state = "hold"
        reason = "failed_safety_gate"

    elif not canary:
        state = "hold"
        reason = "no_valid_canary"

    else:
        state = "canary_ready"
        reason = "all_gates_passed"


    return {
        "schema_version": 1,

        "generated_at":
            now_iso(),

        "stage":
            "HT18.10A",

        "mode":
            "controlled-canary",

        "state":
            state,

        "reason":
            reason,

        "global_freeze":
            global_freeze,

        "failed_gates":
            failed,

        "safety_production_delete_allowed":
            delete_allowed,

        "mutation_allowed":
            mutation_allowed,

        "max_canary":
            MAX_CANARY,

        "valid_candidate_count":
            len(candidates),

        "selected_canary_count":
            len(canary),

        "selected_canary":
            canary,

        "rollback_required":
            True,

        "hard_boundary":
            "NO_CONFIG_MUTATION_HT18_10A",
    }


def backup_canary(
    result: dict[str, Any],
) -> list[dict[str, Any]]:

    JOURNAL.mkdir(
        parents=True,
        exist_ok=True,
    )

    saved = []

    for item in result.get(
        "selected_canary",
        []
    ):

        source = Path(
            item["path"]
        )

        target = (
            JOURNAL
            / (
                item["config_id"]
                + ".json"
            )
        )

        data = source.read_bytes()

        if not target.exists():
            target.write_bytes(data)
            os.chmod(target, 0o600)

        saved.append({
            "config_id":
                item["config_id"],

            "backup":
                str(target),

            "backup_sha256":
                sha256(target),

            "source_sha256":
                item["sha256"],
        })

    return saved


def main() -> int:

    result = build()

    result["rollback_backups"] = (
        backup_canary(result)
    )

    atomic_write(
        OUTPUT,
        result
    )

    print(
        json.dumps(
            result,
            ensure_ascii=False,
            indent=2,
        )
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
