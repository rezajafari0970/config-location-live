from __future__ import annotations

import json
import os
import time

from collections import Counter
from pathlib import Path


ROOT=Path(
    "/var/lib/config-location/country/"
    "rotating-exit-history"
)


def _path(
    config_id: str,
) -> Path:

    return (
        ROOT
        / f"{config_id}.json"
    )


def _read(
    config_id: str,
) -> dict:

    p=_path(
        config_id
    )

    if not p.exists():
        return {
            "config_id":
                config_id,

            "observations":
                [],
        }

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        return {
            "config_id":
                config_id,

            "observations":
                [],
        }

    if not isinstance(
        o,
        dict,
    ):
        return {
            "config_id":
                config_id,

            "observations":
                [],
        }

    if not isinstance(
        o.get(
            "observations"
        ),
        list,
    ):
        o[
            "observations"
        ]=[]

    return o


def _write(
    config_id: str,
    value: dict,
) -> None:

    ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    p=_path(
        config_id
    )

    tmp=p.with_suffix(
        ".tmp"
    )

    tmp.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
        )
    )

    os.replace(
        tmp,
        p,
    )


def observe(
    *,
    config_id: str,
    exit_ip: str,
    country_code: str | None,
    max_history: int = 12,
) -> dict:

    now=int(
        time.time()
    )

    state=_read(
        config_id
    )

    obs=state.get(
        "observations",
        [],
    )


    row={
        "ts":
            now,

        "exit_ip":
            str(
                exit_ip
            ),

        "country_code":
            (
                str(
                    country_code
                ).upper()
                if country_code
                else None
            ),
    }


    # Avoid duplicate consecutive observation.
    if (
        not obs
        or obs[-1].get(
            "exit_ip"
        )!=row[
            "exit_ip"
        ]
        or obs[-1].get(
            "country_code"
        )!=row[
            "country_code"
        ]
    ):
        obs.append(
            row
        )


    obs=obs[
        -max(
            3,
            int(
                max_history
            )
        ):
    ]


    state[
        "observations"
    ]=obs


    ips=[
        x.get(
            "exit_ip"
        )
        for x in obs
        if x.get(
            "exit_ip"
        )
    ]

    countries=[
        str(
            x.get(
                "country_code"
            )
        ).upper()
        for x in obs
        if x.get(
            "country_code"
        )
    ]


    unique_ips=set(
        ips
    )

    country_counts=Counter(
        countries
    )

    unique_countries=set(
        countries
    )


    verdict="pending_confirmation"

    reason="insufficient_history"


    # Need at least two real observations.
    if len(obs)>=2:

        if (
            len(unique_countries)==1
            and len(unique_ips)==1
        ):

            verdict="confirmed_stable"
            reason="same_ip_same_country"


        elif (
            len(unique_countries)==1
            and len(unique_ips)>=2
        ):

            verdict="confirmed_rotating_ip"
            reason="rotating_ip_same_country"


        elif len(
            unique_countries
        )>=2:

            verdict="pending_confirmation"
            reason="country_changed"


    dominant_country=None

    if country_counts:

        dominant_country=(
            country_counts
            .most_common(
                1
            )[0][0]
        )


    result={
        "state":
            verdict,

        "reason":
            reason,

        "observation_count":
            len(obs),

        "unique_ip_count":
            len(
                unique_ips
            ),

        "unique_country_count":
            len(
                unique_countries
            ),

        "dominant_country":
            dominant_country,

        "observations":
            obs,
    }


    state[
        "last_verdict"
    ]=result

    _write(
        config_id,
        state,
    )


    return result
