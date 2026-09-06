from __future__ import annotations

import json

from .engine import (
    build_lifecycle_snapshot,
)


def main() -> int:

    result = (
        build_lifecycle_snapshot()
    )

    print(
        json.dumps(
            {
                "mode":
                    result[
                        "mode"
                    ],

                "config_count":
                    result[
                        "config_count"
                    ],

                "health_result_count":
                    result[
                        "health_result_count"
                    ],

                "tracked_count":
                    result[
                        "tracked_count"
                    ],

                "counts":
                    result[
                        "counts"
                    ],

                "publish_eligible":
                    result[
                        "publish_eligible"
                    ],

                "retest_required":
                    result[
                        "retest_required"
                    ],

                "delete_eligible":
                    result[
                        "delete_eligible"
                    ],
            },
            ensure_ascii=False,
            indent=2,
        )
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
