#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

cat >"$M/exit_observer.py" <<'PY'
from __future__ import annotations

import ipaddress
import subprocess
import time

from collections import Counter
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class ExitProbe:
    provider: str
    url: str
    success: bool
    ip: str | None
    duration_ms: int
    error: str | None = None


@dataclass(frozen=True)
class ExitObservation:
    state: str
    exit_ip: str | None
    agreed: int
    successful: int
    total: int
    probes: tuple[ExitProbe, ...]
    reason: str


DEFAULT_ENDPOINTS = (
    (
        "ipify",
        "https://api.ipify.org",
    ),
    (
        "icanhazip",
        "https://icanhazip.com",
    ),
    (
        "ifconfig_me",
        "https://ifconfig.me/ip",
    ),
)


def normalize_ip(
    value: str,
) -> str | None:

    value = (
        value
        .strip()
        .splitlines()[0]
        .strip()
        if value.strip()
        else ""
    )

    if not value:
        return None

    try:
        ip = ipaddress.ip_address(
            value
        )
    except ValueError:
        return None

    if not ip.is_global:
        return None

    return ip.compressed


def probe_exit_ip(
    *,
    provider: str,
    url: str,
    proxy_url: str | None,
    timeout: float = 8.0,
) -> ExitProbe:

    cmd = [
        "curl",
        "-4",
        "-fsS",
        "--connect-timeout",
        str(
            min(
                timeout,
                5.0,
            )
        ),
        "--max-time",
        str(timeout),
    ]

    if proxy_url:
        cmd += [
            "--proxy",
            proxy_url,
        ]

    cmd.append(url)

    started = time.monotonic()

    try:
        result = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout + 2.0,
        )

        duration_ms = int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        if result.returncode != 0:
            return ExitProbe(
                provider=provider,
                url=url,
                success=False,
                ip=None,
                duration_ms=duration_ms,
                error=(
                    result.stderr.strip()
                    or
                    f"curl_exit_{result.returncode}"
                )[:500],
            )

        ip = normalize_ip(
            result.stdout
        )

        if ip is None:
            return ExitProbe(
                provider=provider,
                url=url,
                success=False,
                ip=None,
                duration_ms=duration_ms,
                error="invalid_ip_response",
            )

        return ExitProbe(
            provider=provider,
            url=url,
            success=True,
            ip=ip,
            duration_ms=duration_ms,
        )

    except subprocess.TimeoutExpired:

        duration_ms = int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        return ExitProbe(
            provider=provider,
            url=url,
            success=False,
            ip=None,
            duration_ms=duration_ms,
            error="timeout",
        )


def observe_exit_ip(
    *,
    proxy_url: str | None,
    endpoints: Iterable[
        tuple[str, str]
    ] = DEFAULT_ENDPOINTS,
    timeout: float = 8.0,
    minimum_agreement: int = 2,
) -> ExitObservation:

    probes = tuple(
        probe_exit_ip(
            provider=provider,
            url=url,
            proxy_url=proxy_url,
            timeout=timeout,
        )
        for provider, url
        in endpoints
    )

    successful = [
        p
        for p in probes
        if (
            p.success
            and p.ip
        )
    ]

    if not successful:
        return ExitObservation(
            state="error",
            exit_ip=None,
            agreed=0,
            successful=0,
            total=len(probes),
            probes=probes,
            reason="no_exit_probe_succeeded",
        )

    counts = Counter(
        p.ip
        for p in successful
    )

    exit_ip, agreed = (
        counts.most_common(1)[0]
    )

    if agreed >= minimum_agreement:

        return ExitObservation(
            state="confirmed",
            exit_ip=exit_ip,
            agreed=agreed,
            successful=len(
                successful
            ),
            total=len(probes),
            probes=probes,
            reason="exit_ip_consensus",
        )

    return ExitObservation(
        state="unstable_exit",
        exit_ip=None,
        agreed=agreed,
        successful=len(successful),
        total=len(probes),
        probes=probes,
        reason="exit_ip_disagreement",
    )
PY


cat >"$M/selftest_exit_observer.py" <<'PY'
from __future__ import annotations

from .exit_observer import (
    ExitProbe,
    normalize_ip,
    observe_exit_ip,
)


def main() -> int:

    assert (
        normalize_ip(
            "8.8.8.8\n"
        )
        == "8.8.8.8"
    )

    assert (
        normalize_ip(
            "not-an-ip"
        )
        is None
    )

    assert (
        normalize_ip(
            "127.0.0.1"
        )
        is None
    )

    print(
        "[PASS] IP validation"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
PY


echo "=== 1. COMPILE ==="

"$PY" -m py_compile \
"$M/exit_observer.py" \
"$M/selftest_exit_observer.py"

echo "COMPILE=PASS"


echo "=== 2. STATIC SELFTEST ==="

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_exit_observer

echo "STATIC_SELFTEST=PASS"


echo "=== 3. DIRECT NETWORK OBSERVER TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.exit_observer import (
    observe_exit_ip,
)

r = observe_exit_ip(
    proxy_url=None,
    timeout=8.0,
)

print("STATE=",r.state)
print("EXIT_IP=",r.exit_ip)
print("AGREED=",r.agreed)
print("SUCCESSFUL=",r.successful)
print("TOTAL=",r.total)
print("REASON=",r.reason)

for p in r.probes:
    print(
        "PROBE",
        p.provider,
        p.success,
        p.ip,
        p.duration_ms,
        p.error,
    )

assert r.state == "confirmed"
assert r.exit_ip is not None
assert r.agreed >= 2

print(
    "DIRECT_EXIT_CONSENSUS=PASS"
)
PY


echo "=== 4. DISAGREEMENT UNIT TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from unittest.mock import patch

from app.country.exit_observer import (
    ExitProbe,
    observe_exit_ip,
)

fake = [
    ExitProbe(
        provider="a",
        url="a",
        success=True,
        ip="8.8.8.8",
        duration_ms=1,
    ),
    ExitProbe(
        provider="b",
        url="b",
        success=True,
        ip="1.1.1.1",
        duration_ms=1,
    ),
    ExitProbe(
        provider="c",
        url="c",
        success=False,
        ip=None,
        duration_ms=1,
        error="fail",
    ),
]

with patch(
    "app.country.exit_observer.probe_exit_ip",
    side_effect=fake,
):
    r=observe_exit_ip(
        proxy_url=None,
        endpoints=(
            ("a","a"),
            ("b","b"),
            ("c","c"),
        ),
        minimum_agreement=2,
    )

assert r.state=="unstable_exit"
assert r.exit_ip is None

print(
    "DISAGREEMENT_DETECTION=PASS"
)
PY


echo "=== 5. SERVICES ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"
    test "$X" = active
done


echo "========================================"
echo "FIX22C2=PASS"
echo "EXIT_OBSERVER=READY"
echo "MULTI_ENDPOINT=YES"
echo "MINIMUM_EXIT_AGREEMENT=2"
echo "INVALID_IP_REJECTED=YES"
echo "PRIVATE_IP_REJECTED=YES"
echo "UNSTABLE_EXIT_DETECTED=YES"
echo "SERVICES=ACTIVE"
echo "========================================"
