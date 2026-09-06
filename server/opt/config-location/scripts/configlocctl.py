#!/opt/config-location/venv/bin/python

from __future__ import annotations

import sys
import json

sys.path.insert(
    0,
    "/opt/config-location"
)

from app.core.source_manager import (
    list_sources,
    add_source,
    delete_source,
    set_enabled,
    stats,
)


def usage():
    print("""
Usage:

configlocctl status

configlocctl list

configlocctl add URL [INTERVAL] [NAME]

configlocctl delete SOURCE_ID

configlocctl enable SOURCE_ID

configlocctl disable SOURCE_ID
""".strip())


args = sys.argv[1:]

if not args:
    usage()
    raise SystemExit(1)


cmd = args[0]


if cmd == "status":

    print(
        json.dumps(
            stats(),
            indent=2,
            ensure_ascii=False
        )
    )


elif cmd == "list":

    print(
        json.dumps(
            list_sources(),
            indent=2,
            ensure_ascii=False
        )
    )


elif cmd == "add":

    if len(args) < 2:
        usage()
        raise SystemExit(1)

    url = args[1]

    interval = (
        int(args[2])
        if len(args) > 2
        else 60
    )

    name = (
        args[3]
        if len(args) > 3
        else ""
    )

    src, duplicate = add_source(
        url,
        name,
        interval
    )

    print(
        json.dumps(
            {
                "duplicate_merged": duplicate,
                "source": src,
            },
            indent=2,
            ensure_ascii=False
        )
    )


elif cmd == "delete":

    if len(args) != 2:
        usage()
        raise SystemExit(1)

    print(
        "deleted"
        if delete_source(args[1])
        else "not found"
    )


elif cmd in (
    "enable",
    "disable"
):

    if len(args) != 2:
        usage()
        raise SystemExit(1)

    src = set_enabled(
        args[1],
        cmd == "enable"
    )

    print(
        json.dumps(
            src,
            indent=2,
            ensure_ascii=False
        )
    )


else:
    usage()
    raise SystemExit(1)
