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

sys.path.insert(0, "/opt/config-location")

from app.core.source_manager import list_sources
from app.parser.detector import extract_configs


REPORT = Path(
    "/var/lib/config-location/audit/unique-latest.json"
)

MAX_RESPONSE = 10 * 1024 * 1024

MAX_REQUESTS = 80
DUPLICATE_STOP = 15
EMPTY_STOP = 5

CONCURRENCY = 5


def now_iso():
    return datetime.now(
        timezone.utc
    ).isoformat()


def body_hash(text: str):
    return hashlib.sha256(
        text.encode(
            "utf-8",
            errors="ignore"
        )
    ).hexdigest()


def preview(text: str, limit=1200):
    text = (
        str(text)
        .replace("\x00", "")
        .strip()
    )

    if len(text) > limit:
        return text[:limit] + "..."

    return text


async def fetch_body(client, url):
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
            text = raw.decode(
                encoding,
                errors="replace"
            )
        except Exception:
            text = raw.decode(
                "utf-8",
                errors="replace"
            )

        return {
            "body": text,
            "status_code": response.status_code,
            "content_type": response.headers.get(
                "content-type",
                ""
            ),
        }


async def audit_source(
    sem,
    client,
    source
):
    async with sem:

        source_id = source["id"]
        url = source["url"]

        seen_configs = {}
        seen_responses = set()

        rejected_samples = []
        error_samples = []

        duplicate_streak = 0
        empty_streak = 0

        requests = 0
        rejected = 0
        errors = 0

        mode = "auto"

        for request_no in range(
            1,
            MAX_REQUESTS + 1
        ):
            requests += 1

            try:
                response = await fetch_body(
                    client,
                    url
                )

            except Exception as e:
                errors += 1

                if len(error_samples) < 5:
                    error_samples.append({
                        "request": request_no,
                        "error": str(e)[:500],
                    })

                if errors >= 5:
                    break

                await asyncio.sleep(0.25)
                continue


            body = response["body"]

            current_hash = body_hash(
                body
            )

            repeated_response = (
                current_hash
                in seen_responses
            )

            seen_responses.add(
                current_hash
            )

            items = extract_configs(
                body
            )


            # ------------------------------------------------
            # detect source behavior
            # ------------------------------------------------

            if request_no == 1:

                if len(items) > 1:
                    mode = "bulk"

                elif len(items) == 1:
                    mode = "rotating"

                else:
                    mode = "unknown"


            # ------------------------------------------------
            # keep UNIQUE by fingerprint
            # ------------------------------------------------

            new_count = 0

            if items:

                empty_streak = 0

                for item in items:

                    fp = item.get(
                        "fingerprint"
                    )

                    if not fp:
                        continue

                    if fp not in seen_configs:

                        seen_configs[
                            fp
                        ] = {
                            "fingerprint": fp,
                            "type": item.get(
                                "type",
                                "unknown"
                            ),
                            "raw": item.get(
                                "raw",
                                ""
                            ),
                            "confidence":
                                item.get(
                                    "confidence"
                                ),
                        }

                        new_count += 1


                if new_count:
                    duplicate_streak = 0
                else:
                    duplicate_streak += 1


            else:

                rejected += 1
                empty_streak += 1
                duplicate_streak += 1

                if len(
                    rejected_samples
                ) < 10:
                    rejected_samples.append({
                        "request": request_no,
                        "status_code":
                            response[
                                "status_code"
                            ],
                        "content_type":
                            response[
                                "content_type"
                            ],
                        "response_hash":
                            current_hash,
                        "preview":
                            preview(body),
                    })


            # ------------------------------------------------
            # stop rules
            # ------------------------------------------------

            if mode == "bulk":

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


            if repeated_response:
                await asyncio.sleep(0.05)
            else:
                await asyncio.sleep(0.08)


        type_counter = Counter()

        for item in seen_configs.values():
            type_counter[
                item["type"]
            ] += 1


        unique_count = len(
            seen_configs
        )

        type_sum = sum(
            type_counter.values()
        )


        # ----------------------------------------------------
        # consistency check
        # ----------------------------------------------------

        consistent = (
            unique_count
            == type_sum
        )


        # ----------------------------------------------------
        # state
        # ----------------------------------------------------

        if (
            unique_count > 0
            and rejected == 0
            and errors == 0
            and consistent
        ):
            status = "CLEAN"

        elif (
            unique_count > 0
            and consistent
        ):
            status = "MIXED"

        elif unique_count == 0 and errors:
            status = "ERROR"

        elif unique_count == 0:
            status = "NO_CONFIG"

        else:
            status = "INCONSISTENT"


        return {
            "source_id":
                source_id,

            "name":
                source.get(
                    "name",
                    ""
                ),

            "url":
                url,

            "mode":
                mode,

            "requests":
                requests,

            "unique_configs":
                unique_count,

            "unique_type_sum":
                type_sum,

            "classification_consistent":
                consistent,

            "types":
                dict(
                    sorted(
                        type_counter.items()
                    )
                ),

            "rejected_responses":
                rejected,

            "http_errors":
                errors,

            "rejected_samples":
                rejected_samples,

            "error_samples":
                error_samples,

            "configs":
                list(
                    seen_configs.values()
                ),

            "status":
                status,
        }


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
        "======================================"
    )
    print(
        " UNIQUE CLASSIFICATION AUDIT"
    )
    print(
        "======================================"
    )
    print(
        "Sources:",
        len(sources)
    )


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
            "ConfigLocationUniqueAudit/1.0",

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

        results = await asyncio.gather(
            *[
                audit_source(
                    sem,
                    client,
                    source
                )
                for source in sources
            ]
        )


    # ========================================================
    # GLOBAL UNIQUE SET
    # ========================================================

    global_unique = {}

    global_sources = {}

    for result in results:

        source_id = result[
            "source_id"
        ]

        for item in result[
            "configs"
        ]:

            fp = item[
                "fingerprint"
            ]

            if fp not in global_unique:
                global_unique[
                    fp
                ] = {
                    "fingerprint":
                        fp,

                    "type":
                        item[
                            "type"
                        ],

                    "confidence":
                        item.get(
                            "confidence"
                        ),
                }

            global_sources.setdefault(
                fp,
                set()
            ).add(
                source_id
            )


    global_types = Counter()

    for item in global_unique.values():

        global_types[
            item[
                "type"
            ]
        ] += 1


    global_count = len(
        global_unique
    )

    global_type_sum = sum(
        global_types.values()
    )


    summary = {
        "sources":
            len(results),

        "clean":
            sum(
                1
                for x in results
                if x["status"]
                == "CLEAN"
            ),

        "mixed":
            sum(
                1
                for x in results
                if x["status"]
                == "MIXED"
            ),

        "no_config":
            sum(
                1
                for x in results
                if x["status"]
                == "NO_CONFIG"
            ),

        "error":
            sum(
                1
                for x in results
                if x["status"]
                == "ERROR"
            ),

        "inconsistent":
            sum(
                1
                for x in results
                if x["status"]
                == "INCONSISTENT"
            ),

        "global_unique_configs":
            global_count,

        "global_unique_type_sum":
            global_type_sum,

        "global_classification_consistent":
            global_count
            == global_type_sum,

        "types":
            dict(
                sorted(
                    global_types.items()
                )
            ),
    }


    report = {
        "generated_at":
            now_iso(),

        "summary":
            summary,

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
            indent=2
        ),
        encoding="utf-8"
    )


    # ========================================================
    # OUTPUT
    # ========================================================

    print()
    print(
        "======================================"
    )
    print(
        " SOURCE RESULTS"
    )
    print(
        "======================================"
    )


    for result in results:

        print()
        print(
            result[
                "status"
            ],
            "|",
            result.get(
                "name"
            )
            or "-"
        )

        print(
            result["url"]
        )

        print(
            "Mode:",
            result[
                "mode"
            ]
        )

        print(
            "Requests:",
            result[
                "requests"
            ]
        )

        print(
            "Unique:",
            result[
                "unique_configs"
            ]
        )

        print(
            "Type sum:",
            result[
                "unique_type_sum"
            ]
        )

        print(
            "Consistent:",
            result[
                "classification_consistent"
            ]
        )

        print(
            "Types:",
            json.dumps(
                result[
                    "types"
                ],
                ensure_ascii=False
            )
        )

        print(
            "Rejected:",
            result[
                "rejected_responses"
            ]
        )

        print(
            "HTTP errors:",
            result[
                "http_errors"
            ]
        )


    print()
    print(
        "======================================"
    )
    print(
        " GLOBAL UNIQUE"
    )
    print(
        "======================================"
    )

    print(
        json.dumps(
            summary,
            ensure_ascii=False,
            indent=2
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
