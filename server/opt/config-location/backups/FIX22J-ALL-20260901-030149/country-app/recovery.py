from __future__ import annotations

from .fallback_consensus import (
    decide_fallback_country,
)

from .fallback_geo import (
    lookup_fallback_all,
)


RECOVERABLE_STATES={
    "unknown",
    "ambiguous",
    "unstable_exit",
    "pending_confirmation",
}


def should_run_recovery(
    state: str,
) -> bool:

    return (
        str(state)
        .strip()
        .lower()
        in RECOVERABLE_STATES
    )


def recover_country(
    *,
    ip: str,
    previous_state: str,
) -> dict:

    if not should_run_recovery(
        previous_state
    ):

        return {
            "executed":False,
            "state":previous_state,
            "reason":
                "recovery_not_required",
        }

    rows=lookup_fallback_all(
        ip,
        timeout=8.0,
    )

    consensus=(
        decide_fallback_country(
            rows,
            minimum_agreement=2,
        )
    )

    return {
        "executed":True,
        **consensus,

        "providers":[
            {
                "provider":
                    row.provider,

                "success":
                    row.success,

                "country_code":
                    row.country_code,

                "country_name":
                    row.country_name,

                "asn":
                    row.asn,

                "network_name":
                    row.network_name,

                "duration_ms":
                    row.duration_ms,

                "error":
                    row.error,
            }
            for row in rows
        ],
    }
