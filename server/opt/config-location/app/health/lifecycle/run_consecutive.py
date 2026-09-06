from __future__ import annotations

import json

from .consecutive import (
    update_tracker,
)


def main() -> int:

    state = update_tracker()

    records = state[
        "records"
    ]


    healthy_streaks = sum(
        1
        for value in records.values()
        if int(
            value.get(
                "consecutive_healthy",
                0,
            )
        ) > 0
    )


    unhealthy_streaks = sum(
        1
        for value in records.values()
        if int(
            value.get(
                "consecutive_unhealthy",
                0,
            )
        ) > 0
    )


    error_streaks = sum(
        1
        for value in records.values()
        if int(
            value.get(
                "consecutive_error",
                0,
            )
        ) > 0
    )


    summary = {
        "mode":
            state[
                "mode"
            ],

        "tracked_count":
            state[
                "tracked_count"
            ],

        "latest_result_count":
            state[
                "latest_result_count"
            ],

        "processed_new_results":
            state[
                "processed_new_results"
            ],

        "unchanged_results":
            state[
                "unchanged_results"
            ],

        "healthy_streak_records":
            healthy_streaks,

        "unhealthy_streak_records":
            unhealthy_streaks,

        "error_streak_records":
            error_streaks,
    }


    print(
        json.dumps(
            summary,
            ensure_ascii=False,
            indent=2,
        )
    )

    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
