from __future__ import annotations

import json

from pathlib import Path

from app.health.runtime.launcher import (
    RuntimeLauncher,
)

from .pipeline import (
    extract_config_type,
    extract_runtime_source,
    save_pipeline_result,
)

from .strong_exit_recovery import (
    observe_strong_exit,
)

from .ultimate_geo import (
    ultimate_country,
)


def hard_recover(
    *,
    config_id: str,
    record: dict,
) -> dict:

    runtime=None

    try:

        config_type=(
            extract_config_type(
                record
            )
        )

        source=(
            extract_runtime_source(
                record
            )
        )


        runtime=RuntimeLauncher().launch(
            config_id=(
                "country-hard-"
                + config_id
            ),
            config_type=
                config_type,
            source=source,
            startup_timeout=8.0,
        )


        exit_result=(
            observe_strong_exit(
                proxy_url=
                    runtime.proxy_url,
                rounds=3,
            )
        )


        if (
            exit_result.state
            != "confirmed"
            or not exit_result.exit_ip
        ):

            return {
                "schema_version":2,
                "config_id":
                    config_id,
                "config_type":
                    config_type,
                "state":
                    exit_result.state,
                "country_code":None,
                "country_name":None,
                "flag":None,
                "exit_ip":None,
                "reason":
                    exit_result.reason,
                "recovery_layer":
                    "hard_exit",
            }


        geo=ultimate_country(
            exit_result.exit_ip
        )


        if (
            geo["state"]
            != "confirmed"
            or not geo[
                "country_code"
            ]
        ):

            return {
                "schema_version":2,
                "config_id":
                    config_id,
                "config_type":
                    config_type,
                "state":
                    geo["state"],
                "country_code":None,
                "country_name":None,
                "flag":None,
                "exit_ip":
                    exit_result.exit_ip,
                "confidence":
                    geo["confidence"],
                "reason":
                    "hard_geo_unresolved",
                "recovery_layer":
                    "ultimate_geo",
                "recovery_evidence":
                    geo["evidence"],
            }


        # Hard recovery is allowed to finish Country
        # in one job because Exit evidence already used
        # 15 probes across 3 rounds.
        result={
            "schema_version":2,

            "config_id":
                config_id,

            "config_type":
                config_type,

            "state":
                "confirmed_stable",

            "country_code":
                geo[
                    "country_code"
                ],

            "country_name":
                None,

            "flag":
                geo["flag"],

            "exit_ip":
                exit_result.exit_ip,

            "confidence":
                geo["confidence"],

            "reason":
                "hard_recovery_consensus",

            "recovery_layer":
                "ultimate",

            "exit_consensus":{
                "agreed":
                    exit_result.agreed,

                "successful":
                    exit_result.successful,

                "attempts":
                    exit_result.attempts,
            },

            "recovery_evidence":
                geo["evidence"],
        }


        save_pipeline_result(
            config_id=config_id,
            value=result,
        )

        return result


    except Exception as e:

        return {
            "schema_version":2,
            "config_id":
                config_id,
            "state":"error",
            "country_code":None,
            "reason":
                "hard_recovery_exception",
            "error":
                f"{type(e).__name__}: {e}"[
                    :1000
                ],
        }


    finally:

        if runtime is not None:

            try:
                runtime.stop()
            except Exception:
                pass
