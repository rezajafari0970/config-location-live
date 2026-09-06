from __future__ import annotations

import json
import subprocess

from dataclasses import dataclass


@dataclass(frozen=True)
class RdapEvidence:

    success: bool

    country_code: str | None

    name: str | None

    handle: str | None

    error: str | None


def lookup_rdap(
    ip: str,
    timeout: float=10.0,
) -> RdapEvidence:

    try:

        p=subprocess.run(
            [
                "curl",
                "-fsS",
                "--connect-timeout",
                "5",
                "--max-time",
                str(timeout),
                "-H",
                "Accept: application/rdap+json, application/json",
                f"https://rdap.org/ip/{ip}",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout+2,
        )

    except Exception as e:

        return RdapEvidence(
            success=False,
            country_code=None,
            name=None,
            handle=None,
            error=type(e).__name__,
        )


    if p.returncode!=0:

        return RdapEvidence(
            success=False,
            country_code=None,
            name=None,
            handle=None,
            error=(
                p.stderr.strip()
                or
                f"curl_{p.returncode}"
            )[:300],
        )


    try:

        o=json.loads(
            p.stdout
        )

    except Exception:

        return RdapEvidence(
            success=False,
            country_code=None,
            name=None,
            handle=None,
            error="invalid_json",
        )


    code=o.get(
        "country"
    )

    name=o.get(
        "name"
    )

    handle=o.get(
        "handle"
    )


    if not code:

        return RdapEvidence(
            success=False,
            country_code=None,
            name=(
                str(name)
                if name
                else None
            ),
            handle=(
                str(handle)
                if handle
                else None
            ),
            error=
                "rdap_missing_country",
        )


    return RdapEvidence(
        success=True,
        country_code=
            str(code).upper(),

        name=(
            str(name)
            if name
            else None
        ),

        handle=(
            str(handle)
            if handle
            else None
        ),

        error=None,
    )
