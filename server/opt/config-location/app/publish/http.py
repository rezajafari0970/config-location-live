from __future__ import annotations

import hashlib
import json
import os
import tempfile

from pathlib import Path

from filelock import FileLock
from aiohttp import web

from .filter import (
    build_publish_snapshot,
)

from app.country.production_publish_projection import (
    get_country_projection,
)

from app.country.catalog import (
    build_country_catalog,
)


def _subscription_text(
    config_type: str | None = None,
) -> tuple[str, dict]:

    snapshot = build_publish_snapshot(
        config_type=config_type
    )

    lines = []

    for record in snapshot.configs:

        raw = record.get(
            "raw"
        )

        if not isinstance(
            raw,
            str,
        ):
            continue

        lines.append(
            raw
        )


    text = "\n".join(
        lines
    )


    if text:
        text += "\n"


    metadata = {
        "policy_available":
            snapshot.policy_available,

        "total_configs":
            snapshot.total_configs,

        "publishable":
            snapshot.publishable,

        "suppressed":
            snapshot.suppressed,

        "missing_policy_record":
            snapshot.missing_policy_record,

        "corrupt_configs":
            snapshot.corrupt_configs,

        "config_type":
            config_type,
    }


    return (
        text,
        metadata,
    )



# ============================================================
# PUBLISH MATRIX V1
# ============================================================

PUBLISH_CURSOR_DIR = Path(
    "/var/lib/config-location/publish-cursors"
)

PUBLISH_CURSOR_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


def _classification_for(record: dict) -> dict:
    value = record.get(
        "classification",
        {}
    )

    return (
        value
        if isinstance(value, dict)
        else {}
    )


def _cdn_for(record: dict) -> dict:
    value = _classification_for(
        record
    ).get(
        "cdn",
        {}
    )

    return (
        value
        if isinstance(value, dict)
        else {}
    )


def _cdn_class(record: dict) -> str:
    return str(
        _cdn_for(record).get(
            "cdn_class",
            "unknown",
        )
        or "unknown"
    ).strip().lower()


def _cdn_provider(record: dict) -> str:
    return str(
        _cdn_for(record).get(
            "cdn_provider",
            "unknown",
        )
        or "unknown"
    ).strip().lower()


def _country_match(
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

    if not isinstance(row, dict):
        state = "unknown"
        code = None
    else:
        state = str(
            row.get(
                "state",
                "unknown",
            )
        )

        code = row.get(
            "country_code"
        )

        if isinstance(code, str):
            code = (
                code.strip().upper()
            )

    if wanted == "UNKNOWN":
        return state == "unknown"

    if wanted == "CONFLICT":
        return state == "conflict"

    return (
        state == "resolved"
        and code == wanted
    )


def _cdn_match(
    record: dict,
    wanted: str | None,
) -> bool:

    if not wanted:
        return True

    wanted = str(
        wanted
    ).strip().lower()

    klass = _cdn_class(record)
    provider = _cdn_provider(record)

    if wanted == "cdn":
        return klass in {
            "cloudflare_worker",
            "cloudflare_cdn",
            "other_cdn",
        }

    if wanted == "non-cdn":
        return klass == "non_cdn"

    if wanted == "cloudflare-worker":
        return klass == "cloudflare_worker"

    if wanted == "cloudflare":
        return (
            klass == "cloudflare_cdn"
            or provider == "cloudflare"
        )

    if wanted == "other":
        return klass == "other_cdn"

    if wanted == "unknown":
        return klass == "unknown"

    return False


def _filter_configs(
    *,
    country: str | None = None,
    cdn: str | None = None,
):
    snapshot = (
        build_publish_snapshot()
    )

    projection = (
        get_country_projection()
    )

    selected = []

    for record in snapshot.configs:

        if not isinstance(
            record,
            dict,
        ):
            continue

        if not _country_match(
            record,
            projection,
            country,
        ):
            continue

        if not _cdn_match(
            record,
            cdn,
        ):
            continue

        raw = record.get(
            "raw"
        )

        if not isinstance(
            raw,
            str,
        ):
            continue

        # RAW preservation:
        # do not strip, normalize or transform.
        if raw == "":
            continue

        selected.append(
            record
        )

    return (
        selected,
        snapshot,
    )


def _cursor_name(
    *,
    country: str | None,
    cdn: str | None,
) -> str:

    key = json.dumps(
        {
            "country": country,
            "cdn": cdn,
        },
        sort_keys=True,
        separators=(",", ":"),
    )

    return hashlib.sha256(
        key.encode()
    ).hexdigest()


def _fair_pick(
    records: list[dict],
    *,
    country: str | None,
    cdn: str | None,
):

    if not records:
        return None

    key = _cursor_name(
        country=country,
        cdn=cdn,
    )

    cursor = (
        PUBLISH_CURSOR_DIR
        / f"{key}.cursor"
    )

    lock = FileLock(
        str(
            PUBLISH_CURSOR_DIR
            / f"{key}.lock"
        ),
        timeout=10,
    )

    with lock:

        current = -1

        try:
            current = int(
                cursor.read_text(
                    encoding="utf-8"
                ).strip()
            )
        except Exception:
            current = -1

        next_index = (
            current + 1
        ) % len(records)

        fd, tmp = tempfile.mkstemp(
            dir=str(
                PUBLISH_CURSOR_DIR
            ),
            prefix=".cursor.",
            suffix=".tmp",
        )

        try:
            with os.fdopen(
                fd,
                "w",
                encoding="utf-8",
            ) as f:

                f.write(
                    str(next_index)
                )

                f.flush()
                os.fsync(
                    f.fileno()
                )

            os.replace(
                tmp,
                cursor,
            )

        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

        return records[
            next_index
        ]


def _matrix_text(
    request: web.Request,
    *,
    country: str | None = None,
    cdn: str | None = None,
):

    records, snapshot = (
        _filter_configs(
            country=country,
            cdn=cdn,
        )
    )

    ed = str(
        request.query.get(
            "ed",
            "",
        )
    ).strip().lower()

    one = ed in {
        "1",
        "true",
        "yes",
    }

    if one:

        selected = _fair_pick(
            records,
            country=country,
            cdn=cdn,
        )

        records = (
            [selected]
            if selected is not None
            else []
        )

    lines = []

    for record in records:

        raw = record.get(
            "raw"
        )

        if isinstance(
            raw,
            str,
        ) and raw != "":
            lines.append(raw)

    text = "\n".join(
        lines
    )

    if text:
        text += "\n"

    return (
        text,
        snapshot,
        len(lines),
        one,
    )


async def subscription_matrix(
    request: web.Request,
):

    country = (
        request.match_info.get(
            "country_code"
        )
    )

    cdn = (
        request.match_info.get(
            "cdn_mode"
        )
    )

    if country:
        country = str(
            country
        ).strip().upper()

        if (
            country
            not in {
                "UNKNOWN",
                "CONFLICT",
            }
            and (
                len(country) != 2
                or not country.isalpha()
            )
        ):
            raise web.HTTPNotFound()

    if cdn:
        cdn = str(
            cdn
        ).strip().lower()

        allowed = {
            "cdn",
            "non-cdn",
            "cloudflare-worker",
            "cloudflare",
            "other",
            "unknown",
        }

        if cdn not in allowed:
            raise web.HTTPNotFound()

    try:

        (
            text,
            snapshot,
            count,
            ed,
        ) = _matrix_text(
            request,
            country=country,
            cdn=cdn,
        )

    except Exception:

        raise web.HTTPServiceUnavailable(
            headers={
                "Cache-Control":
                    "no-store",
                "Retry-After":
                    "5",
            }
        )

    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Country":
                str(
                    country or "ALL"
                ),

            "X-Config-CDN":
                str(
                    cdn or "ALL"
                ),

            "X-Config-ED":
                (
                    "1"
                    if ed
                    else "0"
                ),

            "X-Config-Count":
                str(count),

            "X-Config-Publishable":
                str(
                    snapshot.publishable
                ),

            "X-Config-Corrupt":
                str(
                    snapshot.corrupt_configs
                ),
        },
    )



async def subscription_all(
    request: web.Request,
):

    if str(
        request.query.get("ed", "")
    ).strip().lower() in {
        "1", "true", "yes"
    }:
        return await _matrix_handler(
            request
        )

    text, metadata = (
        _subscription_text()
    )


    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Publishable":
                str(
                    metadata[
                        "publishable"
                    ]
                ),

            "X-Config-Suppressed":
                str(
                    metadata[
                        "suppressed"
                    ]
                ),

            "X-Config-Corrupt":
                str(
                    metadata[
                        "corrupt_configs"
                    ]
                ),
        },
    )


async def subscription_type(
    request: web.Request,
):

    config_type = str(
        request.match_info.get(
            "config_type",
            "",
        )
    ).strip().lower()


    if not config_type:
        raise web.HTTPNotFound()


    text, metadata = (
        _subscription_text(
            config_type
        )
    )


    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Type":
                config_type,

            "X-Config-Publishable":
                str(
                    metadata[
                        "publishable"
                    ]
                ),

            "X-Config-Corrupt":
                str(
                    metadata[
                        "corrupt_configs"
                    ]
                ),
        },
    )


async def country_catalog(
    request: web.Request,
):

    try:

        catalog = (
            build_country_catalog()
        )

    except Exception:

        raise web.HTTPServiceUnavailable(
            headers={
                "Cache-Control":
                    "no-store",

                "Retry-After":
                    "5",

                "X-Country-Source":
                    "canonical-projection-v2",

                "X-Country-Catalog-Contract":
                    "unavailable",
            }
        )


    return web.json_response(
        catalog,
        headers={
            "Cache-Control":
                "no-store",

            "X-Country-Source":
                "canonical-projection-v2",

            "X-Country-Catalog-Contract":
                "healthy",

            "X-Country-Count":
                str(
                    catalog[
                        "country_count"
                    ]
                ),
        },
    )


async def publish_status(
    request: web.Request,
):

    snapshot = (
        build_publish_snapshot()
    )


    return web.json_response(
        {
            "mode":
                "production-output-filter",

            "policy_available":
                snapshot.policy_available,

            "total_configs":
                snapshot.total_configs,

            "policy_tracked":
                snapshot.policy_tracked,

            "publishable":
                snapshot.publishable,

            "suppressed":
                snapshot.suppressed,

            "missing_policy_record":
                snapshot.missing_policy_record,

            "corrupt_configs":
                snapshot.corrupt_configs,

            "allowed_states": [
                "healthy",
                "recovered",
            ],

            "production_delete":
                False,
        }
    )


def _available_country_codes(
    projection: dict,
) -> set[str]:

    codes = set()


    for row in (
        projection
        .get(
            "records",
            {},
        )
        .values()
    ):

        if not isinstance(
            row,
            dict,
        ):
            continue


        if row.get(
            "state"
        ) != "resolved":
            continue


        code = row.get(
            "country_code"
        )


        if not isinstance(
            code,
            str,
        ):
            continue


        code = (
            code.strip().upper()
        )


        if (
            len(code) == 2
            and code.isalpha()
        ):

            codes.add(
                code
            )


    return codes


def _country_subscription_text(
    country_code: str,
) -> tuple[
    str,
    object,
    int,
]:

    wanted = str(
        country_code
        or ""
    ).strip().upper()


    if wanted == "UNKNOWN":

        wanted_mode = "UNKNOWN"

    elif wanted == "CONFLICT":

        wanted_mode = "CONFLICT"

    elif (
        len(wanted) == 2
        and wanted.isalpha()
    ):

        wanted_mode = "COUNTRY"

    else:

        raise KeyError(
            "invalid_country"
        )


    projection = (
        get_country_projection()
    )


    snapshot = (
        build_publish_snapshot()
    )


    if wanted_mode == "COUNTRY":

        if (
            wanted
            not in _available_country_codes(
                projection
            )
        ):

            raise KeyError(
                "country_not_present"
            )


    selected = []


    for record in snapshot.configs:

        if not isinstance(
            record,
            dict,
        ):
            continue


        cid = record.get(
            "id"
        )


        if not cid:
            continue


        row = (
            projection
            .get(
                "records",
                {},
            )
            .get(
                str(cid)
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
            )


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


        if wanted_mode == "UNKNOWN":

            match = (
                state == "unknown"
            )

        elif wanted_mode == "CONFLICT":

            match = (
                state == "conflict"
            )

        else:

            match = (
                state == "resolved"
                and code == wanted
            )


        if not match:
            continue


        raw = record.get(
            "raw"
        )


        if not isinstance(
            raw,
            str,
        ):
            continue


        # Raw preservation contract:
        # never call strip() on config payload.
        if raw == "":
            continue


        selected.append(
            raw
        )


    return (
        "\n".join(
            selected
        ),
        snapshot,
        len(selected),
    )


async def subscription_country(
    request: web.Request,
):

    if str(
        request.query.get("ed", "")
    ).strip().lower() in {
        "1", "true", "yes"
    }:
        return await _matrix_handler(
            request
        )

    country_code = str(
        request.match_info.get(
            "country_code",
            "",
        )
    ).strip().upper()


    if (
        country_code
        not in {
            "UNKNOWN",
            "CONFLICT",
        }
        and (
            len(country_code) != 2
            or not country_code.isalpha()
        )
    ):

        raise web.HTTPNotFound()


    try:

        (
            text,
            snapshot,
            count,
        ) = _country_subscription_text(
            country_code
        )


    except KeyError:

        raise web.HTTPNotFound()


    except Exception:

        raise web.HTTPServiceUnavailable(
            headers={
                "Cache-Control":
                    "no-store",

                "Retry-After":
                    "5",

                "X-Country-Source":
                    "canonical-projection-v2",

                "X-Country-Contract":
                    "unavailable",
            }
        )


    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Country":
                country_code,

            "X-Config-Publishable":
                str(
                    snapshot.publishable
                ),

            "X-Config-Country-Count":
                str(
                    count
                ),

            "X-Config-Corrupt":
                str(
                    snapshot.corrupt_configs
                ),

            "X-Country-Source":
                "canonical-projection-v2",

            "X-Country-Contract":
                "healthy",
        },
    )


def install_publish_routes(
    app: web.Application,
) -> None:

    if app.get(
        "_ht18_publish_installed"
    ):
        return


    app[
        "_ht18_publish_installed"
    ] = True


    # PUBLISH_MATRIX_V1

    app.router.add_get(
        "/sub/all",
        subscription_all,
    )

    app.router.add_get(
        "/sub/cdn",
        subscription_cdn_all,
    )

    app.router.add_get(
        "/sub/non-cdn",
        subscription_non_cdn,
    )

    app.router.add_get(
        "/sub/cdn/cloudflare-worker",
        subscription_cloudflare_worker,
    )

    app.router.add_get(
        "/sub/cdn/cloudflare",
        subscription_cloudflare,
    )

    app.router.add_get(
        "/sub/cdn/other",
        subscription_other_cdn,
    )

    app.router.add_get(
        "/sub/cdn/unknown",
        subscription_unknown_cdn,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn",
        subscription_country_cdn,
    )

    app.router.add_get(
        "/sub/country/{country_code}/non-cdn",
        subscription_country_non_cdn,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn/cloudflare-worker",
        subscription_country_cloudflare_worker,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn/cloudflare",
        subscription_country_cloudflare,
    )

    app.router.add_get(
        "/sub/country/{country_code}/cdn/other",
        subscription_country_other_cdn,
    )

    app.router.add_get(
        "/sub/country/{country_code}",
        subscription_country,
    )

    app.router.add_get(
        "/sub/{config_type}",
        subscription_type,
    )

    app.router.add_get(
        "/api/countries",
        country_catalog,
    )

    app.router.add_get(
        "/api/publish/status",
        publish_status,
    )
