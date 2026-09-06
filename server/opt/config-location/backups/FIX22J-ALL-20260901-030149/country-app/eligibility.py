from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class EligibilityDecision:
    eligible: bool
    reason: str


def decide_country_eligibility(
    health: dict[str, Any] | None,
) -> EligibilityDecision:

    if not health:
        return EligibilityDecision(
            eligible=False,
            reason="missing_health",
        )

    state = str(
        health.get("state", "")
    ).strip().lower()

    if state == "healthy":
        return EligibilityDecision(
            eligible=True,
            reason="health_state_healthy",
        )

    return EligibilityDecision(
        eligible=False,
        reason="health_state_" + (state or "missing"),
    )
