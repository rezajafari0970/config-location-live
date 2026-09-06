#!/opt/config-location/venv/bin/python

import asyncio
import json
import sys

sys.path.insert(
    0,
    "/opt/config-location"
)

from app.fetcher.engine import one_cycle
from app.core.config_store import config_stats


async def main():
    print(
        "Running forced fetch cycle..."
    )

    results = await one_cycle(
        force=True
    )

    print()
    print(
        json.dumps(
            results,
            ensure_ascii=False,
            indent=2,
        )
    )

    print()
    print(
        "CONFIG STATS:"
    )

    print(
        json.dumps(
            config_stats(),
            ensure_ascii=False,
            indent=2,
        )
    )


asyncio.run(
    main()
)
