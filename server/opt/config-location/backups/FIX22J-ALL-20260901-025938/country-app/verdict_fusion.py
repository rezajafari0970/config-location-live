from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .normalize import (
    normalize_country_code,
)


@dataclass(frozen=True)
class FusedVerdict:
    state: str
    country_code: str | None
    country_name: str | None
    flag: str | None
    confidence: float
    source: str
    reason: str
    primary_state: str
    recovery_state: str | None
    conflict: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "state":self.state,
            "country_code":
                self.country_code,
            "country_name":
                self.country_name,
            "flag":
                self.flag,
            "confidence":
                round(
                    float(
                        self.confidence
                    ),
                    4,
                ),
            "source":
                self.source,
            "reason":
                self.reason,
            "primary_state":
                self.primary_state,
            "recovery_state":
                self.recovery_state,
            "conflict":
                self.conflict,
        }


PRIMARY_STRONG={
    "confirmed",
    "confirmed_stable",
    "confirmed_rotating_ip",
}


def fuse_country_verdict(
    *,
    primary: dict[str, Any],
    recovery: dict[str, Any] | None,
) -> FusedVerdict:

    p_state=str(
        primary.get(
            "state",
            "unknown",
        )
    ).strip().lower()

    p_code=normalize_country_code(
        primary.get(
            "country_code"
        )
    )

    p_conf=float(
        primary.get(
            "country_confidence",
            primary.get(
                "confidence",
                0.0,
            ),
        )
        or 0.0
    )

    p_name=primary.get(
        "country_name"
    )

    p_flag=primary.get(
        "flag"
    )


    r_state=None
    r_code=None
    r_conf=0.0
    r_name=None
    r_flag=None

    if recovery:

        r_state=str(
            recovery.get(
                "state",
                "unknown",
            )
        ).strip().lower()

        r_code=normalize_country_code(
            recovery.get(
                "country_code"
            )
        )

        r_conf=float(
            recovery.get(
                "confidence",
                0.0,
            )
            or 0.0
        )

        r_name=recovery.get(
            "country_name"
        )

        r_flag=recovery.get(
            "flag"
        )


    # Strong primary is authoritative because it
    # already represents multi-provider runtime-exit
    # evidence. Recovery cannot overwrite it.
    if (
        p_state in PRIMARY_STRONG
        and p_code
        and p_conf >= 0.67
    ):

        if (
            r_state=="confirmed"
            and r_code
            and r_code != p_code
        ):
            return FusedVerdict(
                state="ambiguous",
                country_code=None,
                country_name=None,
                flag=None,
                confidence=0.0,
                source="primary_recovery_conflict",
                reason=(
                    "strong_primary_conflicts_"
                    "with_secondary_consensus"
                ),
                primary_state=p_state,
                recovery_state=r_state,
                conflict=True,
            )

        return FusedVerdict(
            state=p_state,
            country_code=p_code,
            country_name=(
                str(p_name)
                if p_name
                else None
            ),
            flag=(
                str(p_flag)
                if p_flag
                else None
            ),
            confidence=p_conf,
            source="primary",
            reason="strong_primary_retained",
            primary_state=p_state,
            recovery_state=r_state,
            conflict=False,
        )


    # Weak primary can be recovered only by a
    # confirmed secondary consensus.
    if (
        r_state=="confirmed"
        and r_code
        and r_conf >= 0.67
    ):

        # If primary still has a usable but different
        # country signal, never silently overwrite it.
        if (
            p_code
            and p_code != r_code
        ):
            return FusedVerdict(
                state="ambiguous",
                country_code=None,
                country_name=None,
                flag=None,
                confidence=0.0,
                source="primary_recovery_conflict",
                reason=(
                    "weak_primary_country_conflicts_"
                    "with_secondary_consensus"
                ),
                primary_state=p_state,
                recovery_state=r_state,
                conflict=True,
            )

        return FusedVerdict(
            state="confirmed",
            country_code=r_code,
            country_name=(
                str(r_name)
                if r_name
                else None
            ),
            flag=(
                str(r_flag)
                if r_flag
                else None
            ),
            confidence=r_conf,
            source="recovery",
            reason=(
                "secondary_consensus_recovered_country"
            ),
            primary_state=p_state,
            recovery_state=r_state,
            conflict=False,
        )


    # No layer can prove a country.
    if (
        p_state=="rotating"
    ):
        state="rotating"
        reason="temporal_country_rotation"

    elif (
        p_state=="ambiguous"
        or r_state=="ambiguous"
    ):
        state="ambiguous"
        reason="country_evidence_ambiguous"

    else:
        state="unknown"
        reason="country_not_proven"

    return FusedVerdict(
        state=state,
        country_code=None,
        country_name=None,
        flag=None,
        confidence=0.0,
        source="none",
        reason=reason,
        primary_state=p_state,
        recovery_state=r_state,
        conflict=False,
    )
