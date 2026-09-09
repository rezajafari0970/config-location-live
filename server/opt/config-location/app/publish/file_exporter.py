from __future__ import annotations

import json
import os
import shutil
import tempfile
import time

from pathlib import Path

from filelock import FileLock

from app.publish.filter import (
    build_publish_snapshot,
)

from app.publish.matrix import (
    cdn_class,
)

from app.country.production_publish_projection import (
    get_country_projection,
)


ROOT = Path(
    "/var/lib/config-location/file-publish"
)

PUBLIC = Path(
    "/var/www/config-location-sub"
)

# FILE_PUBLISHER_V2
# Public releases must live under /var/www so nginx never
# needs traversal access to /var/lib/config-location.
RELEASES = PUBLIC / "releases"

CURRENT = PUBLIC / "current"

LOCK = FileLock(
    str(ROOT / "export.lock"),
    timeout=30,
)


BASE_KEYS = {
    "all",
    "unknown",

    "cdn",
    "non-cdn",

    "cloudflare",
    "cloudflare-worker",
    "other-cdn",
    "unknown-cdn",
}


def _country_key(
    record: dict,
    projection: dict,
) -> str:

    row = (
        projection
        .get("records", {})
        .get(
            str(
                record.get("id")
            )
        )
    )

    if not isinstance(
        row,
        dict,
    ):
        return "unknown"

    if (
        str(
            row.get("state", "")
        ).lower()
        != "resolved"
    ):
        return "unknown"

    code = row.get(
        "country_code"
    )

    if (
        not isinstance(code, str)
        or len(code.strip()) != 2
        or not code.strip().isalpha()
    ):
        return "unknown"

    return code.strip().lower()


def _cdn_keys(
    record: dict,
) -> list[str]:

    klass = cdn_class(
        record
    )

    if klass == "cloudflare_worker":
        return [
            "cdn",
            "cloudflare-worker",
        ]

    if klass == "cloudflare_cdn":
        return [
            "cdn",
            "cloudflare",
        ]

    if klass == "other_cdn":
        return [
            "cdn",
            "other-cdn",
        ]

    if klass == "non_cdn":
        return [
            "non-cdn",
        ]

    return [
        "unknown-cdn",
    ]


def _write_atomic(
    path: Path,
    data: bytes,
):

    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix="." + path.name + ".",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "wb",
        ) as f:

            f.write(data)
            f.flush()
            os.fsync(
                f.fileno()
            )

        os.replace(
            tmp,
            path,
        )

    finally:

        if os.path.exists(tmp):
            os.unlink(tmp)


def _text_payload(
    items: list[str],
) -> bytes:

    chunks = []

    for raw in items:

        # Never strip or normalize Raw.
        chunks.append(raw)

        # Delimiter only if the Raw itself
        # did not already finish with newline.
        if not raw.endswith("\n"):
            chunks.append("\n")

    return "".join(
        chunks
    ).encode(
        "utf-8"
    )


def export() -> dict:

    with LOCK:

        snapshot = (
            build_publish_snapshot()
        )

        projection = (
            get_country_projection()
        )

        buckets: dict[
            str,
            list[str],
        ] = {
            key: []
            for key in BASE_KEYS
        }

        for record in snapshot.configs:

            if not isinstance(
                record,
                dict,
            ):
                continue

            raw = record.get(
                "raw"
            )

            if (
                not isinstance(raw, str)
                or raw == ""
            ):
                continue

            country = _country_key(
                record,
                projection,
            )

            buckets.setdefault(
                "all",
                [],
            ).append(raw)

            buckets.setdefault(
                country,
                [],
            ).append(raw)

            ckeys = _cdn_keys(
                record
            )

            for key in ckeys:

                buckets.setdefault(
                    key,
                    [],
                ).append(raw)

                buckets.setdefault(
                    f"{country}-{key}",
                    [],
                ).append(raw)

        # Always expose UNKNOWN combinations.
        for suffix in (
            "cdn",
            "non-cdn",
            "cloudflare",
            "cloudflare-worker",
            "other-cdn",
            "unknown-cdn",
        ):
            buckets.setdefault(
                f"unknown-{suffix}",
                [],
            )

        RELEASES.mkdir(
            parents=True,
            exist_ok=True,
        )

        PUBLIC.mkdir(
            parents=True,
            exist_ok=True,
        )

        stamp = (
            time.strftime(
                "%Y%m%dT%H%M%SZ",
                time.gmtime(),
            )
            + "-"
            + str(os.getpid())
        )

        stage = (
            RELEASES
            / (".tmp-" + stamp)
        )

        final = (
            RELEASES
            / stamp
        )

        stage.mkdir(
            parents=True,
            exist_ok=False,
        )

        try:

            for key in sorted(
                buckets
            ):

                items = buckets[
                    key
                ]

                _write_atomic(
                    stage
                    / f"{key}.txt",

                    _text_payload(
                        items
                    ),
                )

                # Companion index is for ED=1.
                # It preserves the complete Raw string,
                # even if a JSON config itself contains
                # internal newlines.
                index = {
                    "version": 1,
                    "key": key,
                    "count": len(items),
                    "items": items,
                }

                _write_atomic(
                    stage
                    / f"{key}.index.json",

                    json.dumps(
                        index,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ).encode(
                        "utf-8"
                    ),
                )

            summary = {
                "version": 1,
                "generated_at":
                    time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ",
                        time.gmtime(),
                    ),

                "publishable":
                    snapshot.publishable,

                "files": {
                    key: len(value)
                    for key, value
                    in sorted(
                        buckets.items()
                    )
                },
            }

            _write_atomic(
                stage / "_status.json",

                json.dumps(
                    summary,
                    ensure_ascii=False,
                    indent=2,
                ).encode(
                    "utf-8"
                ),
            )

            os.replace(
                stage,
                final,
            )

        except Exception:

            shutil.rmtree(
                stage,
                ignore_errors=True,
            )

            raise

        # Atomic symlink switch.
        temp_link = (
            PUBLIC
            / (
                ".current-"
                + str(os.getpid())
            )
        )

        try:
            temp_link.unlink()
        except FileNotFoundError:
            pass

        os.symlink(
            str(final),
            str(temp_link),
        )

        os.replace(
            temp_link,
            CURRENT,
        )

        # Keep only the newest few releases.
        releases = sorted(
            [
                p
                for p in RELEASES.iterdir()
                if (
                    p.is_dir()
                    and not p.name.startswith(".tmp-")
                )
            ],
            key=lambda p: p.name,
            reverse=True,
        )

        current_target = (
            CURRENT.resolve()
            if CURRENT.exists()
            else None
        )

        for old in releases[4:]:

            try:
                if (
                    current_target is not None
                    and old.resolve()
                    == current_target
                ):
                    continue

                shutil.rmtree(
                    old,
                    ignore_errors=True,
                )

            except Exception:
                pass

        return summary


if __name__ == "__main__":

    value = export()

    print(
        json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )
