from __future__ import annotations

from collections import defaultdict
from typing import Any

from app.publish.filter import build_publish_snapshot
from app.country.production_publish_projection import (
    get_country_projection,
)


def _normalize_code(value: Any) -> str | None:
    if not isinstance(value, str):
        return None

    value = value.strip().upper()

    if len(value) != 2 or not value.isalpha():
        return None

    return value


def build_country_catalog() -> dict[str, Any]:
    snapshot = build_publish_snapshot()
    projection = get_country_projection()

    records = projection.get("records", {})

    if not isinstance(records, dict):
        records = {}

    counts: dict[str, int] = defaultdict(int)
    metadata: dict[str, dict[str, Any]] = {}

    resolved = 0
    unknown = 0
    conflict = 0

    for config in snapshot.configs:
        if not isinstance(config, dict):
            continue

        config_id = config.get("id")

        if not config_id:
            unknown += 1
            continue

        row = records.get(str(config_id))

        if not isinstance(row, dict):
            unknown += 1
            continue

        state = str(
            row.get("state", "unknown")
        ).strip().lower()

        if state == "conflict":
            conflict += 1
            continue

        if state != "resolved":
            unknown += 1
            continue

        code = _normalize_code(
            row.get("country_code")
        )

        if code is None:
            unknown += 1
            continue

        resolved += 1
        counts[code] += 1

        item = metadata.setdefault(
            code,
            {
                "country_name": None,
                "flag": None,
            },
        )

        name = row.get("country_name")

        if (
            item["country_name"] is None
            and isinstance(name, str)
            and name.strip()
        ):
            item["country_name"] = name.strip()

        flag = row.get("flag")

        if (
            item["flag"] is None
            and isinstance(flag, str)
            and flag.strip()
        ):
            item["flag"] = flag.strip()

    countries = []

    for code in sorted(counts):
        meta = metadata.get(code, {})

        countries.append(
            {
                "code": code,
                "country_code": code,
                "country_name": meta.get("country_name"),
                "flag": meta.get("flag"),
                "count": counts[code],
                "subscription": f"/sub/country/{code}",
            }
        )

    return {
        "schema": 1,
        "source": "canonical-projection-v2",
        "mode": "production",
        "publishable": snapshot.publishable,
        "resolved": resolved,
        "unknown": unknown,
        "conflict": conflict,
        "country_count": len(countries),
        "countries": countries,
        "special_routes": {
            "unknown": "/sub/country/UNKNOWN",
            "conflict": "/sub/country/CONFLICT",
        },
    }
