from __future__ import annotations

from .models import HealthState


_ALLOWED = {
    HealthState.NEW: {
        HealthState.QUEUED,
        HealthState.ERROR,
    },

    HealthState.QUEUED: {
        HealthState.RUNNING,
        HealthState.ERROR,
    },

    HealthState.RUNNING: {
        HealthState.HEALTHY,
        HealthState.UNHEALTHY,
        HealthState.ERROR,
        HealthState.RUNTIME_FAILED,
        HealthState.UNSUPPORTED_BY_XRAY,
        HealthState.UNSUPPORTED_BY_XRAY_VERSION,
        HealthState.INVALID,
        HealthState.NOT_TESTED,
    },

    HealthState.HEALTHY: {
        HealthState.QUEUED,
    },

    HealthState.UNHEALTHY: {
        HealthState.QUEUED,
    },

    HealthState.ERROR: {
        HealthState.QUEUED,
    },

    HealthState.RUNTIME_FAILED: {
        HealthState.QUEUED,
    },

    HealthState.UNSUPPORTED_BY_XRAY: {
        HealthState.QUEUED,
    },

    HealthState.UNSUPPORTED_BY_XRAY_VERSION: {
        HealthState.QUEUED,
    },

    HealthState.INVALID: {
        HealthState.QUEUED,
    },

    HealthState.NOT_TESTED: {
        HealthState.QUEUED,
    },
}


class InvalidHealthTransition(RuntimeError):
    pass


def validate_transition(
    current: HealthState,
    target: HealthState,
) -> None:

    allowed = _ALLOWED.get(current, set())

    if target not in allowed:
        raise InvalidHealthTransition(
            f"invalid health transition: "
            f"{current.value} -> {target.value}"
        )
