from __future__ import annotations

import hashlib
import inspect
import json
import os
import shutil
import tempfile

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT = Path(
    "/var/lib/config-location/health-results/latest"
)

LIFECYCLE_ROOT = Path(
    "/var/lib/config-location/health-lifecycle"
)

COUNTRY_ROOT = Path(
    "/var/lib/config-location/country"
)

WAIT_STATUS = Path(
    "/var/lib/config-location/removal-wait/status.json"
)

ROLLBACK_ROOT = Path(
    "/var/lib/config-location/removal-rollback"
)


PRODUCTION_DELETE = False


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def read_json(
    path: Path,
) -> Any:

    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )

    except Exception:
        return {}


def sha256_file(
    path: Path,
) -> str | None:

    if not path.is_file():
        return None

    h=hashlib.sha256()

    with path.open("rb") as fh:

        while True:

            chunk=fh.read(
                1024 * 1024
            )

            if not chunk:
                break

            h.update(chunk)

    return h.hexdigest()


def first_live_candidate() -> dict[str,Any] | None:

    status=read_json(
        WAIT_STATUS
    )

    sample=status.get(
        "live_candidate_sample",
        [],
    )

    if not isinstance(
        sample,
        list,
    ):
        return None

    for row in sample:

        if not isinstance(
            row,
            dict,
        ):
            continue

        if row.get(
            "live_safe_candidate"
        ) is True:

            return row

    return None


def locate_candidate_files(
    config_id: str,
) -> dict[str,Any]:

    direct={
        "config":
            CONFIG_ROOT
            / f"{config_id}.json",

        "health":
            HEALTH_ROOT
            / f"{config_id}.json",
    }


    country_matches=[]

    if COUNTRY_ROOT.exists():

        for path in COUNTRY_ROOT.rglob("*"):

            if not path.is_file():
                continue

            try:
                if (
                    config_id
                    in path.name
                ):
                    country_matches.append(
                        str(path)
                    )
                    continue

                if (
                    path.stat().st_size
                    <= 2_000_000
                ):

                    text=path.read_text(
                        encoding="utf-8",
                        errors="ignore",
                    )

                    if config_id in text:
                        country_matches.append(
                            str(path)
                        )

            except Exception:
                continue


    lifecycle_matches=[]

    if LIFECYCLE_ROOT.exists():

        for path in LIFECYCLE_ROOT.glob(
            "*.json"
        ):

            try:
                if (
                    path.stat().st_size
                    <= 50_000_000
                ):

                    text=path.read_text(
                        encoding="utf-8",
                        errors="ignore",
                    )

                    if config_id in text:
                        lifecycle_matches.append(
                            str(path)
                        )

            except Exception:
                continue


    return {
        "config":
            str(
                direct["config"]
            ),

        "config_exists":
            direct["config"].exists(),

        "health":
            str(
                direct["health"]
            ),

        "health_exists":
            direct["health"].exists(),

        "country_matches":
            sorted(
                set(
                    country_matches
                )
            ),

        "lifecycle_matches":
            sorted(
                set(
                    lifecycle_matches
                )
            ),
    }


def build_final_revalidation(
    candidate: dict[str,Any],
) -> dict[str,Any]:

    cid=str(
        candidate.get(
            "config_id",
            "",
        )
    ).strip()

    if not cid:
        return {
            "valid":
                False,

            "reason":
                "missing_config_id",
        }


    config_path=(
        CONFIG_ROOT
        / f"{cid}.json"
    )

    health_path=(
        HEALTH_ROOT
        / f"{cid}.json"
    )


    health=read_json(
        health_path
    )


    health_state=str(
        health.get(
            "state",
            "unknown",
        )
    ).lower()


    unhealthy_streak=int(
        candidate.get(
            "current_unhealthy_streak",
            0,
        )
        or 0
    )


    healthy_streak=int(
        candidate.get(
            "current_healthy_streak",
            0,
        )
        or 0
    )


    min_streak=int(
        candidate.get(
            "min_streak",
            8,
        )
        or 8
    )


    checks={
        "config_exists":
            config_path.exists(),

        "health_exists":
            health_path.exists(),

        "latest_health_unhealthy":
            health_state
            == "unhealthy",

        "policy_delete_shadow":
            bool(
                candidate.get(
                    "delete_candidate_shadow",
                    False,
                )
            ),

        "minimum_streak_met":
            unhealthy_streak
            >= min_streak,

        "healthy_streak_zero":
            healthy_streak
            == 0,

        "worker_marked_live_safe":
            candidate.get(
                "live_safe_candidate"
            )
            is True,
    }


    return {
        "valid":
            all(
                checks.values()
            ),

        "config_id":
            cid,

        "checks":
            checks,

        "latest_health_state":
            health_state,

        "unhealthy_streak":
            unhealthy_streak,

        "healthy_streak":
            healthy_streak,

        "minimum_streak":
            min_streak,
    }


def inspect_publish_state(
    config_id: str,
) -> dict[str,Any]:

    from app.publish.filter import (
        publishable_config_ids,
    )

    try:

        publishable=set(
            publishable_config_ids()
        )

    except Exception as exc:

        return {
            "check_ok":
                False,

            "error":
                repr(exc),

            "publishable":
                None,
        }


    return {
        "check_ok":
            True,

        "publishable":
            config_id in publishable,

        "expected_for_removal_candidate":
            False,
    }


def inspect_referential_guard() -> dict[str,Any]:

    import app.integrity.referential_guard as rg


    wanted=(
        "reconcile_one_orphan",
        "sweep_orphans",
    )

    result={}


    for name in wanted:

        fn=getattr(
            rg,
            name,
            None,
        )

        if fn is None:

            result[name]={
                "exists":
                    False,
            }

            continue


        try:

            sig=str(
                inspect.signature(
                    fn
                )
            )

        except Exception:

            sig="unknown"


        result[name]={
            "exists":
                True,

            "callable":
                callable(fn),

            "signature":
                sig,
        }


    return result


def build_backup_manifest(
    config_id: str,
    files: dict[str,Any],
) -> dict[str,Any]:

    paths=[]


    for key in (
        "config",
        "health",
    ):

        value=files.get(
            key
        )

        if value:

            p=Path(value)

            if p.is_file():
                paths.append(p)


    for key in (
        "country_matches",
        "lifecycle_matches",
    ):

        for value in files.get(
            key,
            [],
        ):

            p=Path(value)

            if p.is_file():
                paths.append(p)


    unique=[]

    seen=set()

    for path in paths:

        resolved=str(
            path.resolve()
        )

        if resolved in seen:
            continue

        seen.add(
            resolved
        )

        unique.append(
            path
        )


    return {
        "config_id":
            config_id,

        "generated_at":
            now_iso(),

        "files": [
            {
                "path":
                    str(path),

                "size":
                    path.stat().st_size,

                "mode":
                    oct(
                        path.stat().st_mode
                        & 0o777
                    ),

                "uid":
                    path.stat().st_uid,

                "gid":
                    path.stat().st_gid,

                "sha256":
                    sha256_file(
                        path
                    ),
            }
            for path in unique
        ],
    }


def build_rollback_contract(
    config_id: str,
    backup_manifest: dict[str,Any],
) -> dict[str,Any]:

    return {
        "version":
            1,

        "config_id":
            config_id,

        "rollback_order": [
            "restore config store record",
            "restore canonical health record",
            "restore lifecycle references if independently stored",
            "restore country references if independently stored",
            "regenerate lifecycle snapshots",
            "regenerate safety snapshot",
            "verify publish state",
            "run referential guard",
        ],

        "backup_manifest":
            backup_manifest,

        "preconditions": {
            "production_delete":
                False,

            "backup_complete_before_delete":
                True,

            "all_backup_hashes_verified":
                True,

            "exclusive_destructive_lock_required":
                True,
        },
    }


def build_removal_plan() -> dict[str,Any]:

    candidate=first_live_candidate()


    if candidate is None:

        return {
            "mode":
                "dry_run",

            "state":
                "WAITING_NO_CANDIDATE",

            "production_delete":
                False,

            "delete_performed":
                False,

            "candidate":
                None,

            "generated_at":
                now_iso(),
        }


    cid=str(
        candidate["config_id"]
    )


    revalidation=build_final_revalidation(
        candidate
    )


    files=locate_candidate_files(
        cid
    )


    publish=inspect_publish_state(
        cid
    )


    guard=inspect_referential_guard()


    backup_manifest=build_backup_manifest(
        cid,
        files,
    )


    rollback=build_rollback_contract(
        cid,
        backup_manifest,
    )


    gates={
        "final_revalidation":
            revalidation.get(
                "valid"
            )
            is True,

        "publish_already_excluded":
            (
                publish.get(
                    "check_ok"
                )
                is True
                and publish.get(
                    "publishable"
                )
                is False
            ),

        "config_file_exists":
            files[
                "config_exists"
            ],

        "health_file_exists":
            files[
                "health_exists"
            ],

        "backup_manifest_nonempty":
            len(
                backup_manifest[
                    "files"
                ]
            )
            >= 2,

        "referential_guard_available":
            (
                guard.get(
                    "reconcile_one_orphan",
                    {}
                ).get(
                    "exists"
                )
                is True
            ),
    }


    would_be_removal_ready=(
        all(
            gates.values()
        )
    )


    return {
        "mode":
            "dry_run",

        "state":
            (
                "REMOVAL_READY_SHADOW"
                if would_be_removal_ready
                else "REMOVAL_BLOCKED"
            ),

        "generated_at":
            now_iso(),

        "production_delete":
            False,

        "delete_performed":
            False,

        "delete_api_called":
            False,

        "config_id":
            cid,

        "candidate":
            candidate,

        "final_revalidation":
            revalidation,

        "publish":
            publish,

        "referential_guard":
            guard,

        "files":
            files,

        "backup_manifest":
            backup_manifest,

        "rollback_contract":
            rollback,

        "safety_gates":
            gates,

        "would_be_removal_ready":
            would_be_removal_ready,

        "execution_contract": {
            "step_1":
                "final live revalidation",

            "step_2":
                "acquire exclusive destructive lock",

            "step_3":
                "create immutable backup bundle",

            "step_4":
                "verify backup hashes",

            "step_5":
                "remove canonical config record",

            "step_6":
                "remove canonical health record",

            "step_7":
                "reconcile lifecycle state",

            "step_8":
                "reconcile country references",

            "step_9":
                "run referential guard",

            "step_10":
                "regenerate lifecycle/policy/safety",

            "step_11":
                "verify config absent from publish",

            "step_12":
                "commit removal journal",

            "rollback":
                "restore backup bundle in reverse dependency order",
        },
    }


# IMPORTANT:
#
# This module intentionally contains no destructive
# execution implementation.
#
# There is no:
#   unlink()
#   os.remove()
#   shutil.rmtree()
#   delete config API invocation
#
# Pass 5 defines the architecture only.
