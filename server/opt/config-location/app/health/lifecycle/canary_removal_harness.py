from __future__ import annotations

import fcntl
import hashlib
import json
import os
import tempfile
import time

from pathlib import Path
from typing import Any

from app.health.lifecycle.removal_executor import (
    build_removal_plan,
)


WAIT_STATUS = Path(
    "/var/lib/config-location/removal-wait/status.json"
)

LOCK_PATH = Path(
    "/run/config-location-removal-canary/canary.lock"
)

PRODUCTION_DELETE = False


def read_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return {}


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None

    h=hashlib.sha256()

    with path.open("rb") as fh:
        while True:
            chunk=fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)

    return h.hexdigest()


def current_candidate_signature() -> dict[str, Any] | None:
    status=read_json(
        WAIT_STATUS
    )

    sample=status.get(
        "live_candidate_sample",
        [],
    )

    if not isinstance(sample,list):
        return None

    for row in sample:
        if not isinstance(row,dict):
            continue

        if row.get(
            "live_safe_candidate"
        ) is not True:
            continue

        return {
            "config_id":
                row.get("config_id"),

            "unhealthy_streak":
                row.get(
                    "current_unhealthy_streak"
                ),

            "healthy_streak":
                row.get(
                    "current_healthy_streak"
                ),

            "min_streak":
                row.get(
                    "min_streak"
                ),

            "health_state":
                row.get(
                    "health_state"
                ),

            "policy_state":
                row.get(
                    "policy_state"
                ),
        }

    return None


def semantic_candidate_match(
    before: dict[str,Any] | None,
    after: dict[str,Any] | None,
) -> bool:

    if before is None and after is None:
        return True

    if before is None or after is None:
        return False

    return before == after


def verify_backup_manifest(
    plan: dict[str,Any],
) -> dict[str,Any]:

    manifest=plan.get(
        "backup_manifest",
        {},
    )

    rows=manifest.get(
        "files",
        [],
    )

    if not isinstance(rows,list):
        return {
            "ok":False,
            "reason":"invalid_manifest",
        }

    if len(rows) < 2:
        return {
            "ok":False,
            "reason":"too_few_files",
        }

    mismatches=[]

    for row in rows:

        if not isinstance(row,dict):
            mismatches.append(
                "invalid_row"
            )
            continue

        path=Path(
            str(
                row.get(
                    "path",
                    ""
                )
            )
        )

        expected=row.get(
            "sha256"
        )

        actual=sha256_file(
            path
        )

        if actual != expected:
            mismatches.append(
                str(path)
            )

    return {
        "ok":
            not mismatches,

        "mismatches":
            mismatches,

        "file_count":
            len(rows),
    }


def run_failclosed_harness() -> dict[str,Any]:

    LOCK_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd=os.open(
        LOCK_PATH,
        os.O_CREAT | os.O_RDWR,
        0o600,
    )

    try:

        try:
            fcntl.flock(
                fd,
                fcntl.LOCK_EX
                | fcntl.LOCK_NB,
            )

        except BlockingIOError:

            return {
                "state":
                    "BLOCKED",

                "reason":
                    "exclusive_lock_busy",

                "production_delete":
                    False,

                "delete_performed":
                    False,
            }


        before=current_candidate_signature()

        time.sleep(0.25)

        middle=current_candidate_signature()


        freshness_ok=semantic_candidate_match(
            before,
            middle,
        )


        plan=build_removal_plan()


        after=current_candidate_signature()


        post_plan_freshness_ok=semantic_candidate_match(
            middle,
            after,
        )


        # No candidate is a valid waiting state.
        if (
            before is None
            and plan.get("state")
            == "WAITING_NO_CANDIDATE"
        ):

            return {
                "state":
                    "WAITING_NO_CANDIDATE",

                "production_delete":
                    False,

                "delete_performed":
                    False,

                "gates": {
                    "exclusive_lock":
                        True,

                    "candidate_freshness":
                        freshness_ok,

                    "post_plan_freshness":
                        post_plan_freshness_ok,
                },
            }


        if before is None:

            return {
                "state":
                    "BLOCKED",

                "reason":
                    "candidate_missing",

                "production_delete":
                    False,

                "delete_performed":
                    False,
            }


        backup_verify=verify_backup_manifest(
            plan
        )


        gates={
            "exclusive_lock":
                True,

            "candidate_freshness":
                freshness_ok,

            "post_plan_freshness":
                post_plan_freshness_ok,

            "plan_removal_ready_shadow":
                plan.get("state")
                == "REMOVAL_READY_SHADOW",

            "final_revalidation":
                bool(
                    plan.get(
                        "final_revalidation",
                        {},
                    ).get(
                        "valid",
                        False,
                    )
                ),

            "publish_already_excluded":
                (
                    plan.get(
                        "publish",
                        {}
                    ).get(
                        "publishable"
                    )
                    is False
                ),

            "backup_manifest_verified":
                backup_verify.get(
                    "ok"
                )
                is True,

            "rollback_contract_present":
                isinstance(
                    plan.get(
                        "rollback_contract"
                    ),
                    dict,
                ),

            "referential_guard_ready":
                bool(
                    plan.get(
                        "safety_gates",
                        {},
                    ).get(
                        "referential_guard_available",
                        False,
                    )
                ),

            "production_delete_disabled":
                plan.get(
                    "production_delete"
                )
                is False,

            "delete_not_performed":
                plan.get(
                    "delete_performed"
                )
                is False,
        }


        ready=all(
            gates.values()
        )


        return {
            "state":
                (
                    "CANARY_READY"
                    if ready
                    else "BLOCKED"
                ),

            "production_delete":
                False,

            "delete_performed":
                False,

            "candidate":
                before,

            "gates":
                gates,

            "backup_verification":
                backup_verify,

            "plan_state":
                plan.get(
                    "state"
                ),

            "fail_closed":
                True,
        }


    finally:
        os.close(fd)
