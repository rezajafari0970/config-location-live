from __future__ import annotations

import json
import os
import tempfile
import time
import urllib.error
import urllib.request

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any

from app.publish.filter import (
    PublishSnapshot,
    build_publish_snapshot,
)

from app.country.projection import (
    build_projection,
)


BASE = "http://127.0.0.1:4040"

STATE_ROOT = Path(
    "/var/lib/config-location/"
    "country/publish-contract"
)

STATUS = (
    STATE_ROOT
    / "status.json"
)

TIMEOUT = 10.0

COUNTRY_SAMPLE_SIZE = 5


def now_iso() -> str:

    return datetime.now(
        timezone.utc
    ).isoformat()


def atomic_json(
    path: Path,
    data: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )


    fd, tmp = tempfile.mkstemp(
        dir=str(
            path.parent
        ),
        prefix=(
            "."
            + path.name
            + "."
        ),
        suffix=".tmp",
    )


    configloc_gid = (
        __import__("grp")
        .getgrnam("configloc")
        .gr_gid
    )


    os.fchown(
        fd,
        -1,
        configloc_gid,
    )

    os.fchmod(
        fd,
        0o640,
    )


    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as fh:

            json.dump(
                data,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()

            os.fsync(
                fh.fileno()
            )


        os.replace(
            tmp,
            path,
        )


    finally:

        if os.path.exists(
            tmp
        ):

            os.unlink(
                tmp
            )


def http_get(
    path: str,
) -> dict[str, Any]:

    started = (
        time.monotonic()
    )


    request = (
        urllib.request.Request(
            BASE + path,
            method="GET",
            headers={
                "User-Agent":
                    "config-location-country-contract/2",
            },
        )
    )


    try:

        with urllib.request.urlopen(
            request,
            timeout=TIMEOUT,
        ) as response:

            body = (
                response.read()
            )

            status = int(
                response.status
            )

            headers = {
                key.lower():
                    value

                for key, value
                in response.headers.items()
            }


    except urllib.error.HTTPError as exc:

        body = exc.read()

        status = int(
            exc.code
        )

        headers = {
            key.lower():
                value

            for key, value
            in exc.headers.items()
        }


    return {
        "path":
            path,

        "status":
            status,

        "body":
            body,

        "headers":
            headers,

        "elapsed_seconds":
            round(
                time.monotonic()
                - started,
                4,
            ),
    }


def nonempty_lines(
    body: bytes,
) -> int:

    text = body.decode(
        "utf-8",
        errors="replace",
    )


    return sum(
        1
        for line in text.splitlines()
        if line.strip()
    )


def _country_counts(
    snapshot: PublishSnapshot,
    projection: dict[str, Any],
) -> dict[str, int]:

    publish_ids = {
        str(record["id"])

        for record
        in snapshot.configs

        if (
            isinstance(
                record,
                dict,
            )
            and record.get(
                "id"
            )
        )
    }


    counts: dict[
        str,
        int,
    ] = {}


    for cid, row in (
        projection
        .get(
            "records",
            {},
        )
        .items()
    ):

        if (
            str(cid)
            not in publish_ids
        ):
            continue


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
            code
            .strip()
            .upper()
        )


        if (
            len(code) != 2
            or not code.isalpha()
        ):
            continue


        counts[code] = (
            counts.get(
                code,
                0,
            )
            + 1
        )


    return counts


def _select_guard_countries(
    country_counts: dict[str, int],
    limit: int = COUNTRY_SAMPLE_SIZE,
) -> list[str]:

    codes = sorted(
        code
        for code, count
        in country_counts.items()
        if count > 0
    )


    if not codes:
        return []


    limit = max(
        1,
        min(
            int(limit),
            len(codes),
        ),
    )


    # Timer runs every minute.
    # Advancing the starting position every minute
    # guarantees coverage rotates over all countries.
    bucket = int(
        time.time()
        // 60
    )


    start = (
        bucket
        % len(codes)
    )


    result = []


    for offset in range(
        len(codes)
    ):

        code = codes[
            (
                start
                + offset
            )
            % len(codes)
        ]


        result.append(
            code
        )


        if (
            len(result)
            >= limit
        ):

            break


    return result


def _select_config_type(
    snapshot: PublishSnapshot,
) -> str:

    counts: dict[
        str,
        int,
    ] = {}


    for record in (
        snapshot.configs
    ):

        if not isinstance(
            record,
            dict,
        ):
            continue


        config_type = (
            record.get(
                "type"
            )
        )


        if not isinstance(
            config_type,
            str,
        ):
            continue


        config_type = (
            config_type
            .strip()
            .lower()
        )


        if not config_type:
            continue


        counts[
            config_type
        ] = (
            counts.get(
                config_type,
                0,
            )
            + 1
        )


    if not counts:

        raise RuntimeError(
            "no publishable config type"
        )


    return max(
        counts,
        key=counts.get,
    )


def _country_present_now(
    code: str,
) -> bool:

    try:

        snapshot = (
            build_publish_snapshot()
        )

        projection = (
            build_projection()
        )

        return (
            _country_counts(
                snapshot,
                projection,
            ).get(
                code,
                0,
            )
            > 0
        )

    except Exception:

        return True


def run_contract(
) -> dict[str, Any]:

    started = (
        time.monotonic()
    )


    gates: dict[
        str,
        bool,
    ] = {}


    errors: list[str] = []


    try:

        snapshot = (
            build_publish_snapshot()
        )


        gates[
            "snapshot_type"
        ] = isinstance(
            snapshot,
            PublishSnapshot,
        )


        gates[
            "snapshot_configs_tuple"
        ] = isinstance(
            snapshot.configs,
            tuple,
        )


        gates[
            "snapshot_count_match"
        ] = (
            len(
                snapshot.configs
            )
            == snapshot.publishable
        )


        gates[
            "corruption_metric_valid"
        ] = (
            isinstance(
                snapshot.corrupt_configs,
                int,
            )
            and snapshot.corrupt_configs
            >= 0
        )


    except Exception as exc:

        snapshot = None

        errors.append(
            "snapshot:"
            + repr(exc)
        )


        gates[
            "snapshot_type"
        ] = False

        gates[
            "snapshot_configs_tuple"
        ] = False

        gates[
            "snapshot_count_match"
        ] = False

        gates[
            "corruption_metric_valid"
        ] = False


    try:

        projection = (
            build_projection()
        )


        gates[
            "projection_mapping"
        ] = isinstance(
            projection,
            dict,
        )


        gates[
            "projection_records"
        ] = isinstance(
            projection.get(
                "records"
            ),
            dict,
        )


        gates[
            "projection_mode_production"
        ] = (
            projection.get(
                "mode"
            )
            == "production"
        )


    except Exception as exc:

        projection = None

        errors.append(
            "projection:"
            + repr(exc)
        )


        gates[
            "projection_mapping"
        ] = False

        gates[
            "projection_records"
        ] = False

        gates[
            "projection_mode_production"
        ] = False


    selected_countries = []
    config_type = None


    if (
        snapshot is not None
        and projection is not None
    ):

        try:

            counts = (
                _country_counts(
                    snapshot,
                    projection,
                )
            )


            selected_countries = (
                _select_guard_countries(
                    counts
                )
            )


            config_type = (
                _select_config_type(
                    snapshot
                )
            )


            gates[
                "target_selection"
            ] = bool(
                selected_countries
                and config_type
            )


        except Exception as exc:

            errors.append(
                "targets:"
                + repr(exc)
            )


            gates[
                "target_selection"
            ] = False


    else:

        gates[
            "target_selection"
        ] = False


    results: dict[
        str,
        Any,
    ] = {}


    def capture(
        key: str,
        path: str,
    ) -> None:

        try:

            results[key] = (
                http_get(
                    path
                )
            )


        except Exception as exc:

            errors.append(
                key
                + ":"
                + repr(exc)
            )


            results[key] = {
                "path":
                    path,

                "status":
                    0,

                "body":
                    b"",

                "headers":
                    {},

                "elapsed_seconds":
                    999.0,
            }


    capture(
        "all",
        "/sub/all",
    )


    if config_type:

        capture(
            "type",
            "/sub/"
            + config_type,
        )


    for index, code in enumerate(
        selected_countries
    ):

        capture(
            f"country_{index}",
            "/sub/country/"
            + code,
        )


    capture(
        "unknown",
        "/sub/country/UNKNOWN",
    )


    capture(
        "conflict",
        "/sub/country/CONFLICT",
    )


    capture(
        "invalid",
        "/sub/country/INVALID",
    )


    capture(
        "missing",
        "/sub/country/ZZ",
    )


    gates[
        "sub_all_http_200"
    ] = (
        results[
            "all"
        ][
            "status"
        ] == 200
    )


    gates[
        "sub_all_nonempty"
    ] = bool(
        results[
            "all"
        ][
            "body"
        ]
    )


    if "type" in results:

        gates[
            "sub_type_http_200"
        ] = (
            results[
                "type"
            ][
                "status"
            ]
            == 200
        )

    else:

        gates[
            "sub_type_http_200"
        ] = False


    for index, code in enumerate(
        selected_countries
    ):

        key = (
            f"country_{index}"
        )

        result = (
            results[key]
        )


        if result[
            "status"
        ] == 200:

            try:

                header_count = int(
                    result[
                        "headers"
                    ].get(
                        "x-config-country-count",
                        "-1",
                    )
                )

            except Exception:

                header_count = -1


            ok = (
                header_count
                == nonempty_lines(
                    result[
                        "body"
                    ]
                )
                and result[
                    "headers"
                ].get(
                    "x-country-source"
                )
                == "canonical-projection-v2"
                and result[
                    "headers"
                ].get(
                    "x-country-contract"
                )
                == "healthy"
            )


        elif (
            result[
                "status"
            ] == 404
            and not _country_present_now(
                code
            )
        ):

            # Country disappeared during this guard
            # cycle due to normal live churn.
            ok = True


        else:

            ok = False


        gates[
            f"country_{index}_contract"
        ] = ok


    for name in (
        "unknown",
        "conflict",
    ):

        result = (
            results[name]
        )


        try:

            header_count = int(
                result[
                    "headers"
                ].get(
                    "x-config-country-count",
                    "-1",
                )
            )

        except Exception:

            header_count = -1


        gates[
            name
            + "_contract"
        ] = (
            result[
                "status"
            ] == 200
            and header_count
            == nonempty_lines(
                result[
                    "body"
                ]
            )
            and result[
                "headers"
            ].get(
                "x-country-source"
            )
            == "canonical-projection-v2"
        )


    gates[
        "invalid_http_404"
    ] = (
        results[
            "invalid"
        ][
            "status"
        ]
        == 404
    )


    # ZZ is expected to be absent. If it somehow
    # becomes a real discovered country, this gate
    # will be corrected by the full regression.
    gates[
        "missing_http_404"
    ] = (
        results[
            "missing"
        ][
            "status"
        ]
        == 404
    )


    latency_values = [
        float(
            result[
                "elapsed_seconds"
            ]
        )

        for result
        in results.values()
    ]


    max_latency = (
        max(
            latency_values
        )
        if latency_values
        else 999.0
    )


    gates[
        "max_latency_le_10s"
    ] = (
        max_latency <= 10.0
    )


    healthy = all(
        gates.values()
    )


    clean_results = {}


    for key, value in (
        results.items()
    ):

        clean_results[key] = {
            "path":
                value["path"],

            "status":
                value["status"],

            "elapsed_seconds":
                value[
                    "elapsed_seconds"
                ],

            "size":
                len(
                    value[
                        "body"
                    ]
                ),
        }


    data = {
        "component":
            "country-publish-contract-guard",

        "schema":
            2,

        "updated_at":
            now_iso(),

        "healthy":
            healthy,

        "state":
            (
                "healthy"
                if healthy
                else "contract_failed"
            ),

        "country_source":
            "CANONICAL_PROJECTION_V2",

        "selected_country":
            (
                selected_countries[0]
                if selected_countries
                else None
            ),

        "selected_countries":
            selected_countries,

        "country_sample_size":
            len(
                selected_countries
            ),

        "selected_config_type":
            config_type,

        "publishable":
            (
                snapshot.publishable
                if snapshot is not None
                else None
            ),

        "corrupt_configs":
            (
                snapshot.corrupt_configs
                if snapshot is not None
                else None
            ),

        "gates":
            gates,

        "results":
            clean_results,

        "max_latency_seconds":
            round(
                max_latency,
                4,
            ),

        "errors":
            errors,

        "production_mutation":
            False,

        "service_restart":
            False,

        "fail_closed_contract":
            {
                "invalid_country_404":
                    True,

                "missing_country_404":
                    True,

                "unknown_conflict_separated":
                    True,
            },

        "elapsed_seconds":
            round(
                time.monotonic()
                - started,
                4,
            ),
    }


    atomic_json(
        STATUS,
        data,
    )


    return data


def main() -> int:

    data = run_contract()


    print(
        json.dumps(
            data,
            ensure_ascii=False,
            indent=2,
        )
    )


    return (
        0
        if data[
            "healthy"
        ]
        else 2
    )


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
