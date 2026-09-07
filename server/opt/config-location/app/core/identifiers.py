from __future__ import annotations

import re


_FINGERPRINT_RE = re.compile(
    r"^[0-9A-Fa-f]{64}$"
)

_SOURCE_ID_RE = re.compile(
    r"^[A-Za-z0-9]"
    r"[A-Za-z0-9._:-]{0,127}$"
)


def validate_fingerprint(
    fingerprint,
) -> str:
    """
    Validate and canonicalize a Config SHA-256 identity.

    The canonical representation is always lowercase.
    """

    value = str(
        fingerprint
        or ""
    ).strip()

    if not _FINGERPRINT_RE.fullmatch(
        value
    ):
        raise ValueError(
            "invalid_fingerprint"
        )

    return value.lower()


def validate_source_id(
    source_id,
) -> str:
    """
    Path-safe Source identity contract.

    Existing UUIDs and safe legacy IDs are preserved.
    """

    value = str(
        source_id
        or ""
    ).strip()

    if not _SOURCE_ID_RE.fullmatch(
        value
    ):
        raise ValueError(
            "invalid_source_id"
        )

    return value


def validate_fingerprint_set(
    values,
) -> set[str]:
    return {
        validate_fingerprint(
            value
        )
        for value in values
    }
