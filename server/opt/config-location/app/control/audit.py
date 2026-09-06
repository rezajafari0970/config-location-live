from __future__ import annotations

from pathlib import Path
from datetime import datetime


LOG_DIR = Path(
    "/var/log/config-location/control"
)


def audit(
    action,
    result,
    detail=""
):

    LOG_DIR.mkdir(
        parents=True,
        exist_ok=True
    )

    file = (
        LOG_DIR / (
        datetime.utcnow()
        .strftime("%Y-%m-%d")
        + ".log"
    )
    )

    with file.open(
        "a",
        encoding="utf-8"
    ) as f:

        f.write(
            "\n".join(
                [
                    "================",
                    datetime.utcnow()
                    .isoformat(),
                    f"ACTION={action}",
                    f"RESULT={result}",
                    f"DETAIL={detail}",
                    ""
                ]
            )
        )

