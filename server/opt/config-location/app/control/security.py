from __future__ import annotations

import json
from pathlib import Path


POLICY = Path(
    "/etc/config-location/control-policy.json"
)

TOKEN = Path(
    "/etc/config-location/control-token"
)


def get_policy():

    if not POLICY.exists():
        return {}

    return json.loads(
        POLICY.read_text()
    )


def check_action(action):

    policy=get_policy()

    return (
        action
        in
        policy.get(
            "allowed_actions",
            []
        )
    )


def check_token(value):

    if not TOKEN.exists():
        return False

    return (
        value.strip()
        ==
        TOKEN.read_text()
        .strip()
    )

