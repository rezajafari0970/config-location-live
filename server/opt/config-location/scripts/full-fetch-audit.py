#!/opt/config-location/venv/bin/python

from __future__ import annotations

import asyncio
import hashlib
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import httpx


sys.path.insert(
    0,
    "/opt/config-location"
)

from app.core.source_manager import list_sources
from app.parser.detector import extract_configs


REPORT = Path(
    "/var/lib/config-location/audit/latest.json"
)

MAX_RESPONSE = 10 * 1024 * 1024

MAX_REQUESTS = 60
DUPLICATE_STOP = 15
EMPTY_STOP = 5

CONCURRENCY = 5


def now_iso():
    return datetime.now(
        timezone.utc
    ).isoformat()


def safe_preview(
    text: str,
    limit: int = 1500,
):
    text = (
        text
        .replace("\x00", "")
        .strip()
    )

    if len(text) > limit:
        return text[:limit] + "..."

    return text


def response_hash(
    text: str
):
    return hashlib.sha256(
        text.encode(
            "utf-8",
            errors="ignore"
        )
    ).hexdigest()


async def fetch_response(
    client,
    url,
):
    async with client.stream(
        "GET",
        url
    ) as response:

        response.raise_for_status()

        chunks = []
        size = 0

        async for chunk in response.aiter_bytes():

            size += len(chunk)

            if size > MAX_RESPONSE:
                raise RuntimeError(
                    "response_too_large"
                )

            chunks.append(chunk)

        raw = b"".join(chunks)

        encoding = (
            response.encoding
            or "utf-8"
        )

        try:
            body = raw.decode(
                encoding,
                errors="replace"
            )
        except Exception:
            body = raw.decode(
                "utf-8",
                errors="replace"
            )

        return {
            "body": body,
            "status_code":
                response.status_code,

            "content_type":
                response.headers.get(
                    "content-type",
                    ""
                ),
        }


async def audit_source(
    sem,
    client,
    source,
):
    async with sem:

        source_id = source["id"]
        url = source["url"]

        result = {
            "source_id": source_id,
            "name": source.get(
                "name",
                ""
            ),
            "url": url,
            "started_at": now_iso(),

            "requests": 0,
            "successful_http": 0,
            "http_errors": 0,

            "unique_configs": 0,

            "types": {},

            "rejected_responses": 0,
            "duplicate_responses": 0,

            "rejected_samples": [],
            "error_samples": [],

            "status": "UNKNOWN",
        }

        seen_configs = set()
        seen_responses = set()

        type_counter = Counter()

        duplicate_streak = 0
        empty_streak = 0

        mode = "auto"

        for request_no in range(
            1,
            MAX_REQUESTS + 1
        ):

            result["requests"] += 1

            try:
                response = await fetch_response(
                    client,
                    url
                )

            except Exception as e:

                result[
                    "http_errors"
                ] += 1

                if len(
                    result["error_samples"]
                ) < 5:

                    result[
                        "error_samples"
                    ].append({
                        "request":
                            request_no,

                        "error":
                            str(e)[:500],
                    })

                if (
                    result["http_errors"]
                    >= 5
                ):
                    break

                await asyncio.sleep(
                    0.3
                )

                continue


            result[
                "successful_http"
            ] += 1

            body = response["body"]

            body_hash = response_hash(
                body
            )

            if (
                body_hash
                in seen_responses
            ):
                result[
                    "duplicate_responses"
                ] += 1
            else:
                seen_responses.add(
                    body_hash
                )


            configs = extract_configs(
                body
            )


            # ------------------------------------------------
            # MODE DETECTION
            # ------------------------------------------------

            if request_no == 1:

                if len(configs) > 1:
                    mode = "bulk"

                elif len(configs) == 1:
                    mode = "rotating"

                else:
                    mode = "unknown"


            # ------------------------------------------------
            # ACCEPTED
            # ------------------------------------------------

            new_this_response = 0

            if configs:

                empty_streak = 0

                for item in configs:

                    fp = item.get(
                        "fingerprint"
                    )

                    if not fp:
                        continue

                    type_counter[
                        item.get(
                            "type",
                            "unknown"
                        )
                    ] += 1

                    if fp not in seen_configs:

                        seen_configs.add(
                            fp
                        )

                        new_this_response += 1


                if new_this_response:
                    duplicate_streak = 0

                else:
                    duplicate_streak += 1


            # ------------------------------------------------
            # REJECTED
            # ------------------------------------------------

            else:

                empty_streak += 1
                duplicate_streak += 1

                result[
                    "rejected_responses"
                ] += 1

                if len(
                    result[
                        "rejected_samples"
                    ]
                ) < 10:

                    result[
                        "rejected_samples"
                    ].append({
                        "request":
                            request_no,

                        "status_code":
                            response[
                                "status_code"
                            ],

                        "content_type":
                            response[
                                "content_type"
                            ],

                        "hash":
                            body_hash,

                        "preview":
                            safe_preview(
                                body
                            ),
                    })


            # ------------------------------------------------
            # STOP RULES
            # ------------------------------------------------

            if mode == "bulk":

                # برای Bulk چند بار دوباره بررسی می‌کنیم
                # چون ممکن است پاسخ آن نیز تغییر کند.
                if (
                    request_no >= 5
                    and duplicate_streak >= 3
                ):
                    break


            elif mode == "rotating":

                if (
                    duplicate_streak
                    >= DUPLICATE_STOP
                ):
                    break


            elif mode == "unknown":

                if (
                    empty_streak
                    >= EMPTY_STOP
                ):
                    break


            await asyncio.sleep(
                0.08
            )


        result[
            "unique_configs"
        ] = len(
            seen_configs
        )

        result[
            "types"
        ] = dict(
            sorted(
                type_counter.items()
            )
        )

        result[
            "mode"
        ] = mode

        result[
            "finished_at"
        ] = now_iso()


        # ----------------------------------------------------
        # STATUS
        # ----------------------------------------------------

        configs_count = result[
            "unique_configs"
        ]

        rejected = result[
            "rejected_responses"
        ]

        errors = result[
            "http_errors"
        ]


        if (
            configs_count > 0
            and rejected == 0
            and errors == 0
        ):

            result[
                "status"
            ] = "CLEAN"


        elif (
            configs_count > 0
            and (
                rejected > 0
                or errors > 0
            )
        ):

            result[
                "status"
            ] = "MIXED"


        elif (
            configs_count == 0
            and errors > 0
        ):

            result[
                "status"
            ] = "ERROR"


        else:

            result[
                "status"
            ] = "NO_CONFIG"


        return result


async def main():

    sources = [
        source
        for source in list_sources()
        if source.get(
            "enabled",
            True
        )
    ]

    print()
    print(
        "================================"
    )

    print(
        " FULL FETCH AUDIT"
    )

    print(
        "================================"
    )

    print(
        "Sources:",
        len(sources)
    )

    print()


    timeout = httpx.Timeout(
        30.0,
        connect=8.0,
        read=15.0,
    )

    limits = httpx.Limits(
        max_connections=10,
        max_keepalive_connections=5,
    )

    headers = {
        "User-Agent":
            "ConfigLocationAudit/1.0",

        "Accept":
            "text/plain,application/json,*/*",

        "Cache-Control":
            "no-cache",
    }

    sem = asyncio.Semaphore(
        CONCURRENCY
    )


    async with httpx.AsyncClient(
        timeout=timeout,
        limits=limits,
        headers=headers,
        follow_redirects=True,
        max_redirects=5,
    ) as client:

        tasks = [
            audit_source(
                sem,
                client,
                source
            )
            for source in sources
        ]

        results = await asyncio.gather(
            *tasks
        )


    # ========================================================
    # GLOBAL SUMMARY
    # ========================================================

    global_types = Counter()

    total_unique_sum = 0

    clean = 0
    mixed = 0
    no_config = 0
    error = 0

    total_rejected = 0


    for result in results:

        total_unique_sum += result[
            "unique_configs"
        ]

        total_rejected += result[
            "rejected_responses"
        ]

        global_types.update(
            result["types"]
        )

        status = result[
            "status"
        ]

        if status == "CLEAN":
            clean += 1

        elif status == "MIXED":
            mixed += 1

        elif status == "NO_CONFIG":
            no_config += 1

        elif status == "ERROR":
            error += 1


    report = {
        "generated_at": now_iso(),

        "summary": {
            "sources":
                len(results),

            "clean":
                clean,

            "mixed":
                mixed,

            "no_config":
                no_config,

            "error":
                error,

            "sum_unique_per_source":
                total_unique_sum,

            "rejected_responses":
                total_rejected,

            "types":
                dict(
                    sorted(
                        global_types.items()
                    )
                ),
        },

        "sources":
            results,
    }


    REPORT.parent.mkdir(
        parents=True,
        exist_ok=True
    )

    REPORT.write_text(
        json.dumps(
            report,
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8"
    )


    # ========================================================
    # TERMINAL REPORT
    # ========================================================

    print()
    print(
        "================================"
    )

    print(
        " AUDIT RESULTS"
    )

    print(
        "================================"
    )


    for result in results:

        print()

        print(
            result["status"],
            "|",
            result.get(
                "name"
            )
            or "-",
        )

        print(
            result["url"]
        )

        print(
            "Mode:",
            result["mode"]
        )

        print(
            "Requests:",
            result["requests"]
        )

        print(
            "Unique:",
            result["unique_configs"]
        )

        print(
            "Rejected:",
            result["rejected_responses"]
        )

        print(
            "HTTP errors:",
            result["http_errors"]
        )

        print(
            "Types:",
            json.dumps(
                result["types"],
                ensure_ascii=False
            )
        )


    print()
    print(
        "================================"
    )

    print(
        " GLOBAL"
    )

    print(
        "================================"
    )

    print(
        json.dumps(
            report["summary"],
            ensure_ascii=False,
            indent=2,
        )
    )

    print()
    print(
        "Saved:"
    )

    print(
        REPORT
    )


if __name__ == "__main__":

    asyncio.run(
        main()
    )
