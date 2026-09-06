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


MIN_REPEAT_SECONDS=30
MAX_HISTORY=12


def _path(
    config_id: str,
) -> Path:

    return ROOT / f"{config_id}.json"


def _empty(
    config_id: str,
) -> dict:

    return {
        "config_id":config_id,
        "observations":[],
    }


def _read(
    config_id: str,
) -> dict:

    p=_path(config_id)

    if not p.exists():
        return _empty(config_id)

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        return _empty(config_id)

    if not isinstance(o,dict):
        return _empty(config_id)

    if not isinstance(
        o.get("observations"),
        list,
    ):
        o["observations"]=[]

    return o


def _write(
    config_id: str,
    value: dict,
) -> None:

    ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    p=_path(config_id)
    tmp=p.with_suffix(".tmp")

    tmp.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
        )
    )

    os.replace(tmp,p)


def observe(
    *,
    config_id: str,
    exit_ip: str,
    country_code: str | None,
    observed_epoch: int | None = None,
    minimum_repeat_seconds: int = MIN_REPEAT_SECONDS,
    max_history: int = MAX_HISTORY,
) -> dict:

    now=int(
        observed_epoch
        if observed_epoch is not None
        else time.time()
    )

    state=_read(config_id)

    obs=list(
        state.get(
            "observations",
            []
        )
    )

    code=(
        str(country_code)
        .strip()
        .upper()
        if country_code
        else None
    )

    row={
        "ts":now,
        "exit_ip":str(exit_ip),
        "country_code":code,
    }


    append=True

    if obs:

        last=obs[-1]

        same=(
            last.get("exit_ip")
            ==row["exit_ip"]
            and last.get("country_code")
            ==row["country_code"]
        )

        age=(
            now
            -int(
                last.get("ts",0)
            )
        )

        # Same observation in the same immediate
        # execution is noise, but the same IP/country
        # observed again in a later Health generation
        # is real temporal evidence.
        if (
            same
            and age
            <max(
                1,
                int(
                    minimum_repeat_seconds
                )
            )
        ):
            append=False


    if append:
        obs.append(row)


    obs=obs[
        -max(
            3,
            int(max_history),
        ):
    ]

    state["observations"]=obs


    ips=[
        x.get("exit_ip")
        for x in obs
        if x.get("exit_ip")
    ]

    countries=[
        str(
            x.get("country_code")
        ).upper()
        for x in obs
        if x.get("country_code")
    ]

    unique_ips=set(ips)
    unique_countries=set(countries)

    counts=Counter(countries)

    dominant_country=None
    dominant_count=0

    if counts:

        dominant_country,dominant_count=(
            counts.most_common(1)[0]
        )


    verdict="pending_confirmation"
    reason="insufficient_history"


    if len(obs)>=2:

        # Stable endpoint:
        # same country and same IP observed in
        # separate temporal observations.
        if (
            len(unique_countries)==1
            and len(unique_ips)==1
        ):

            verdict="confirmed_stable"
            reason="same_ip_same_country_temporal"


        # Rotating endpoint but geo-stable.
        elif (
            len(unique_countries)==1
            and len(unique_ips)>=2
        ):

            verdict="confirmed_rotating_ip"
            reason="rotating_ip_same_country"


        elif len(unique_countries)>=2:

            # Do not flip the final country because
            # one provider/exit observation disagrees.
            #
            # A dominant 2/3+ majority keeps the
            # dominant country but requests recovery.
            if (
                len(countries)>=3
                and dominant_count>=2
                and (
                    dominant_count
                    /len(countries)
                )>=0.66
            ):

                verdict="pending_confirmation"
                reason="country_change_majority_recovery"

            else:

                verdict="pending_confirmation"
                reason="country_change_ambiguous"


    result={
        "state":verdict,
        "reason":reason,

        "observation_count":
            len(obs),

        "unique_ip_count":
            len(unique_ips),

        "unique_country_count":
            len(unique_countries),

        "dominant_country":
            dominant_country,

        "dominant_country_count":
            dominant_count,

        "observation_appended":
            append,

        "observations":
            obs,
    }


    state["last_verdict"]=result

    _write(
        config_id,
        state,
    )

    return result
