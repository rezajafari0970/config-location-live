from __future__ import annotations

import json
import os
import tempfile

from datetime import datetime, timezone
from pathlib import Path

from .models import CountryResult


ROOT = Path(
    "/var/lib/config-location/"
    "country/results"
)

LATEST = ROOT / "latest"
HISTORY = ROOT / "history"


def _atomic_json(
    path: Path,
    value: dict,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix="." + path.name + ".",
        suffix=".tmp",
    )

    try:
        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                value,
                f,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            f.write("\n")
            f.flush()
            os.fsync(f.fileno())

        os.replace(tmp, path)

    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

        raise


def save_country_result(
    result: CountryResult,
) -> tuple[Path, Path]:

    o = result.to_dict()

    stamp = datetime.now(
        timezone.utc
    ).strftime("%Y%m%dT%H%M%S.%fZ")

    latest = (
        LATEST
        / f"{result.config_id}.json"
    )

    history_dir = (
        HISTORY
        / result.config_id
    )

    history = (
        history_dir
        / f"{stamp}.json"
    )

    _atomic_json(history, o)
    _atomic_json(latest, o)

    return latest, history
