from __future__ import annotations

import copy
from typing import Any


# Health-testing policy:
#
# source.raw is NEVER modified.
#
# Any insecure TLS option supplied by the source
# is disabled in the generated health runtime.
#
# Xray 26.x removed allowInsecure itself. Therefore
# secure false-equivalent behavior is represented by
# removing that deprecated field and allowing Xray's
# normal certificate verification to remain enabled.


INSECURE_KEYS = {
    "allowInsecure",
    "allow_insecure",
    "insecure",
    "skipCertVerify",
    "skip_cert_verify",
}


def secure_tls_runtime(
    value: Any,
) -> Any:
    """
    Return a deep-copied runtime tree with known
    insecure TLS bypass fields removed.

    This function never mutates its input.
    """

    if isinstance(value, dict):
        result = {}

        for key, child in value.items():

            if key in INSECURE_KEYS:
                continue

            result[key] = secure_tls_runtime(
                child
            )

        return result

    if isinstance(value, list):
        return [
            secure_tls_runtime(child)
            for child in value
        ]

    return copy.deepcopy(value)


def insecure_key_paths(
    value: Any,
    prefix: str = "$",
) -> list[str]:

    found: list[str] = []

    if isinstance(value, dict):

        for key, child in value.items():

            path = f"{prefix}.{key}"

            if key in INSECURE_KEYS:
                found.append(path)

            found.extend(
                insecure_key_paths(
                    child,
                    path,
                )
            )

    elif isinstance(value, list):

        for index, child in enumerate(value):

            found.extend(
                insecure_key_paths(
                    child,
                    f"{prefix}[{index}]",
                )
            )

    return found
