from __future__ import annotations

import argparse
import json

from pathlib import Path

from .store_health import (
    DEFAULT_CONFIG_DIR,
    DEFAULT_HEALTH_LATEST_DIR,
    DEFAULT_REPORT_PATH,
    write_store_health_integrity,
)


def main() -> int:

    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--config-dir",
        type=Path,
        default=DEFAULT_CONFIG_DIR,
    )

    parser.add_argument(
        "--health-latest-dir",
        type=Path,
        default=DEFAULT_HEALTH_LATEST_DIR,
    )

    parser.add_argument(
        "--report",
        type=Path,
        default=DEFAULT_REPORT_PATH,
    )

    args = parser.parse_args()


    report = write_store_health_integrity(
        report_path=args.report,
        config_dir=args.config_dir,
        health_latest_dir=(
            args.health_latest_dir
        ),
    )


    print(
        json.dumps(
            report,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
    )


    # In FIX20.1 we do not make inconsistency a process
    # failure because production is known to contain
    # historical orphan records that FIX20.2 will reconcile.
    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
