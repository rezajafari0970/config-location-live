from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class XrayValidationClassification:
    code: str
    source_invalid: bool
    retryable: bool


def classify_xray_validation_output(
    stdout: str | None,
    stderr: str | None,
) -> XrayValidationClassification:

    text = (
        (stdout or "")
        + "\n"
        + (stderr or "")
    ).lower()

    # Confirmed by real HT15 diagnostic.
    if (
        "failed to build reality config" in text
        and 'invalid "password"' in text
    ):
        return XrayValidationClassification(
            code="invalid_reality_password",
            source_invalid=True,
            retryable=False,
        )

    if (
        "reality" in text
        and "public key" in text
        and "invalid" in text
    ):
        return XrayValidationClassification(
            code="invalid_reality_public_key",
            source_invalid=True,
            retryable=False,
        )

    if (
        "reality" in text
        and "short" in text
        and "id" in text
        and "invalid" in text
    ):
        return XrayValidationClassification(
            code="invalid_reality_short_id",
            source_invalid=True,
            retryable=False,
        )

    if (
        "uuid" in text
        and "invalid" in text
    ):
        return XrayValidationClassification(
            code="invalid_uuid",
            source_invalid=True,
            retryable=False,
        )

    if (
        "flow" in text
        and (
            "unsupported" in text
            or "invalid" in text
        )
    ):
        return XrayValidationClassification(
            code="invalid_flow",
            source_invalid=True,
            retryable=False,
        )

    if (
        "address already in use" in text
        or "port allocation" in text
    ):
        return XrayValidationClassification(
            code="runtime_port_conflict",
            source_invalid=False,
            retryable=True,
        )

    return XrayValidationClassification(
        code="xray_validation_failed",
        source_invalid=False,
        retryable=False,
    )
