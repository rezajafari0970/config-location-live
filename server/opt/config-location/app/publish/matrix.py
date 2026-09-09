from __future__ import annotations

import json
import os
import tempfile

from pathlib import Path

from aiohttp import web
from filelock import FileLock

from .filter import build_publish_snapshot

from app.country.production_publish_projection import (
    get_country_projection,
)


CURSOR_DIR = Path(
    "/var/lib/config-location/publish-cursors"
)

CURSOR_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


# ============================================================
# Query helpers
# ============================================================

def ed_enabled(
    request: web.Request,
) -> bool:

    return str(
        request.query.get(
            "ed",
            "",
        )
    ).strip().lower() in {
        "1",
        "true",
        "yes",
    }


# ============================================================
# Country
# ============================================================

def country_matches(
    record: dict,
    projection: dict,
    wanted: str | None,
) -> bool:

    if not wanted:
        return True

    wanted = str(
        wanted
    ).strip().upper()

    row = (
        projection
        .get(
            "records",
            {},
        )
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
        state = "unknown"
        code = None

    else:
        state = str(
            row.get(
                "state",
                "unknown",
            )
        ).lower()

        code = row.get(
            "country_code"
        )

        if isinstance(
            code,
            str,
        ):
            code = (
                code
                .strip()
                .upper()
            )

    if wanted == "UNKNOWN":
        return state == "unknown"

    if wanted == "CONFLICT":
        return state == "conflict"

    return (
        state == "resolved"
        and code == wanted
    )


# ============================================================
# CDN metadata
# ============================================================

def cdn_metadata(
    record: dict,
) -> dict:

    classification = record.get(
        "classification",
        {},
    )

    if not isinstance(
        classification,
        dict,
    ):
        return {}

    cdn = classification.get(
        "cdn",
        {},
    )

    return (
        cdn
        if isinstance(
            cdn,
            dict,
        )
        else {}
    )


def cdn_class(
    record: dict,
) -> str:

    return str(
        cdn_metadata(
            record
        ).get(
            "cdn_class",
            "unknown",
        )
        or "unknown"
    ).strip().lower()


def cdn_provider(
    record: dict,
) -> str:

    return str(
        cdn_metadata(
            record
        ).get(
            "cdn_provider",
            "unknown",
        )
        or "unknown"
    ).strip().lower()


def cdn_matches(
    record: dict,
    wanted: str | None,
) -> bool:

    if not wanted:
        return True

    wanted = str(
        wanted
    ).strip().lower()

    klass = cdn_class(
        record
    )

    provider = cdn_provider(
        record
    )

    if wanted == "cdn":
        return klass in {
            "cloudflare_worker",
            "cloudflare_cdn",
            "other_cdn",
        }

    if wanted == "non-cdn":
        return klass == "non_cdn"

    if wanted == "cloudflare-worker":
        return (
            klass
            == "cloudflare_worker"
        )

    if wanted == "cloudflare":
        return (
            klass
            == "cloudflare_cdn"
            or provider
            == "cloudflare"
        )

    if wanted == "other":
        return klass == "other_cdn"

    if wanted == "unknown":
        return klass == "unknown"

    return False


# ============================================================
# Selection
# ============================================================

def select_records(
    *,
    country: str | None = None,
    cdn: str | None = None,
) -> tuple[list[dict], object]:

    snapshot = (
        build_publish_snapshot()
    )

    projection = (
        get_country_projection()
    )

    result = []

    for record in snapshot.configs:

        if not isinstance(
            record,
            dict,
        ):
            continue

        raw = record.get(
            "raw"
        )

        # RAW preservation.
        if (
            not isinstance(
                raw,
                str,
            )
            or raw == ""
        ):
            continue

        if not country_matches(
            record,
            projection,
            country,
        ):
            continue

        if not cdn_matches(
            record,
            cdn,
        ):
            continue

        result.append(
            record
        )

    return (
        result,
        snapshot,
    )


# ============================================================
# Fair ED rotation
# ============================================================

def cursor_key(
    country: str | None,
    cdn: str | None,
) -> str:

    country_part = (
        country or "ALL"
    ).upper()

    cdn_part = (
        cdn or "ALL"
    ).lower()

    safe = (
        country_part
        + "__"
        + cdn_part
    )

    return "".join(
        c
        if c.isalnum()
        or c in "-_"
        else "_"
        for c in safe
    )


def fair_pick(
    records: list[dict],
    *,
    country: str | None,
    cdn: str | None,
):

    if not records:
        return None

    key = cursor_key(
        country,
        cdn,
    )

    cursor = (
        CURSOR_DIR
        / f"{key}.txt"
    )

    lock = FileLock(
        str(
            CURSOR_DIR
            / f"{key}.lock"
        ),
        timeout=10,
    )

    with lock:

        current = -1

        try:
            current = int(
                cursor
                .read_text(
                    encoding="utf-8"
                )
                .strip()
            )
        except Exception:
            pass

        index = (
            current + 1
        ) % len(records)

        fd, tmp = tempfile.mkstemp(
            dir=str(
                CURSOR_DIR
            ),
            prefix=".cursor.",
        )

        try:
            with os.fdopen(
                fd,
                "w",
                encoding="utf-8",
            ) as handle:

                handle.write(
                    str(index)
                )

                handle.flush()

                os.fsync(
                    handle.fileno()
                )

            os.replace(
                tmp,
                cursor,
            )

        finally:
            if os.path.exists(
                tmp
            ):
                os.unlink(
                    tmp
                )

        return records[
            index
        ]


# ============================================================
# HTTP response
# ============================================================

async def matrix_subscription_response(
    request: web.Request,
    *,
    country: str | None = None,
    cdn: str | None = None,
):

    records, snapshot = (
        select_records(
            country=country,
            cdn=cdn,
        )
    )

    if ed_enabled(
        request
    ):

        chosen = fair_pick(
            records,
            country=country,
            cdn=cdn,
        )

        records = (
            [chosen]
            if chosen is not None
            else []
        )

    raws = [
        record["raw"]
        for record in records
    ]

    # No conversion.
    # No strip.
    # No JSON -> URI.
    text = "\n".join(
        raws
    )

    if text:
        text += "\n"

    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Count":
                str(
                    len(raws)
                ),

            "X-Config-ED":
                (
                    "1"
                    if ed_enabled(
                        request
                    )
                    else "0"
                ),

            "X-Config-CDN":
                str(
                    cdn or "ALL"
                ),

            "X-Config-Country":
                str(
                    country or "ALL"
                ),

            "X-Config-Publishable":
                str(
                    snapshot.publishable
                ),
        },
    )


# ============================================================
# Dedicated handlers
# ============================================================

async def sub_cdn(
    request,
):
    return await matrix_subscription_response(
        request,
        cdn="cdn",
    )


async def sub_non_cdn(
    request,
):
    return await matrix_subscription_response(
        request,
        cdn="non-cdn",
    )


async def sub_cf_worker(
    request,
):
    return await matrix_subscription_response(
        request,
        cdn="cloudflare-worker",
    )


async def sub_cf(
    request,
):
    return await matrix_subscription_response(
        request,
        cdn="cloudflare",
    )


async def sub_other(
    request,
):
    return await matrix_subscription_response(
        request,
        cdn="other",
    )


async def sub_unknown(
    request,
):
    return await matrix_subscription_response(
        request,
        cdn="unknown",
    )


async def country_cdn(
    request,
):
    return await matrix_subscription_response(
        request,
        country=request.match_info[
            "country_code"
        ],
        cdn="cdn",
    )


async def country_non_cdn(
    request,
):
    return await matrix_subscription_response(
        request,
        country=request.match_info[
            "country_code"
        ],
        cdn="non-cdn",
    )


async def country_cf_worker(
    request,
):
    return await matrix_subscription_response(
        request,
        country=request.match_info[
            "country_code"
        ],
        cdn="cloudflare-worker",
    )


async def country_cf(
    request,
):
    return await matrix_subscription_response(
        request,
        country=request.match_info[
            "country_code"
        ],
        cdn="cloudflare",
    )


async def country_other(
    request,
):
    return await matrix_subscription_response(
        request,
        country=request.match_info[
            "country_code"
        ],
        cdn="other",
    )


async def country_unknown(
    request,
):
    return await matrix_subscription_response(
        request,
        country=request.match_info[
            "country_code"
        ],
        cdn="unknown",
    )


# ============================================================
# Route installation
# ============================================================

def install_publish_matrix_routes(
    app: web.Application,
):

    app.router.add_get(
        "/sub/cdn/cloudflare-worker",
        sub_cf_worker,
    )

    app.router.add_get(
        "/sub/cdn/cloudflare",
        sub_cf,
    )

    app.router.add_get(
        "/sub/cdn/other",
        sub_other,
    )

    app.router.add_get(
        "/sub/cdn/unknown",
        sub_unknown,
    )

    app.router.add_get(
        "/sub/cdn",
        sub_cdn,
    )

    app.router.add_get(
        "/sub/non-cdn",
        sub_non_cdn,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn/cloudflare-worker",
        country_cf_worker,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn/cloudflare",
        country_cf,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn/other",
        country_other,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn/unknown",
        country_unknown,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn",
        country_cdn,
    )

    app.router.add_get(
        "/sub/country/{country_code}/non-cdn",
        country_non_cdn,
    )
