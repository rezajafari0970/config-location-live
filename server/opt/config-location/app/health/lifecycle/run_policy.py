from __future__ import annotations

import json

from .policy import (
    build_policy_snapshot,
)


def main() -> int:

    result = (
        build_policy_snapshot()
    )

    print(
        json.dumps(
            {
                "mode":
                    result[
                        "mode"
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

                "quarantine_count":
                    result[
                        "quarantine_count"
                    ],

                "deep_quarantine_count":
                    result[
                        "deep_quarantine_count"
                    ],

                "delete_candidate_shadow_count":
                    result[
                        "delete_candidate_shadow_count"
                    ],

                "production_delete_allowed_count":
                    result[
                        "production_delete_allowed_count"
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
