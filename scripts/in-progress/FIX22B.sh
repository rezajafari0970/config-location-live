#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"
D=/var/lib/config-location/country

mkdir -p \
"$M" \
"$D/results/latest" \
"$D/results/history"

cat >"$M/__init__.py" <<'PY'
"""
Independent Country Detection Engine.
"""
PY

cat >"$M/models.py" <<'PY'
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from enum import Enum
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class CountryState(str, Enum):
    PENDING = "pending"
    OBSERVING = "observing"
    CONFIRMED = "confirmed"
    UNKNOWN = "unknown"
    AMBIGUOUS = "ambiguous"
    ROTATING = "rotating"
    UNSTABLE_EXIT = "unstable_exit"
    INELIGIBLE = "ineligible"
    ERROR = "error"


class EvidenceKind(str, Enum):
    EXIT_IP = "exit_ip"
    GEO_COUNTRY = "geo_country"
    ASN = "asn"
    NETWORK = "network"
    TEMPORAL = "temporal"
    FALLBACK = "fallback"
    HINT = "hint"


@dataclass(frozen=True)
class CountryEvidence:
    provider: str
    kind: EvidenceKind
    success: bool
    observed_at: str = field(default_factory=utc_now)
    exit_ip: str | None = None
    country_code: str | None = None
    country_name: str | None = None
    asn: str | None = None
    network_name: str | None = None
    confidence: float = 0.0
    error: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        o = asdict(self)
        o["kind"] = self.kind.value
        return o


@dataclass(frozen=True)
class CountryResult:
    config_id: str
    state: CountryState
    country_code: str | None = None
    country_name: str | None = None
    flag: str | None = None
    exit_ip: str | None = None
    confidence: float = 0.0
    method: str | None = None
    providers_agreed: int = 0
    providers_total: int = 0
    asn: str | None = None
    network_name: str | None = None
    observed_at: str = field(default_factory=utc_now)
    reason: str | None = None
    evidence: tuple[CountryEvidence, ...] = ()
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "config_id": self.config_id,
            "state": self.state.value,
            "country_code": self.country_code,
            "country_name": self.country_name,
            "flag": self.flag,
            "exit_ip": self.exit_ip,
            "confidence": round(float(self.confidence), 4),
            "method": self.method,
            "providers_agreed": self.providers_agreed,
            "providers_total": self.providers_total,
            "asn": self.asn,
            "network_name": self.network_name,
            "observed_at": self.observed_at,
            "reason": self.reason,
            "evidence": [e.to_dict() for e in self.evidence],
            "metadata": dict(self.metadata),
        }
PY

cat >"$M/normalize.py" <<'PY'
from __future__ import annotations


def normalize_country_code(value: str | None) -> str | None:
    if value is None:
        return None

    code = str(value).strip().upper()

    if len(code) != 2:
        return None

    if not code.isalpha():
        return None

    return code


def normalize_country_name(value: str | None) -> str | None:
    if value is None:
        return None

    name = " ".join(str(value).strip().split())

    return name or None


def country_flag(code: str | None) -> str | None:
    code = normalize_country_code(code)

    if code is None:
        return None

    return "".join(
        chr(0x1F1E6 + ord(ch) - ord("A"))
        for ch in code
    )
PY

cat >"$M/eligibility.py" <<'PY'
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
PY

cat >"$M/consensus.py" <<'PY'
from __future__ import annotations

from collections import Counter

from .models import (
    CountryEvidence,
    CountryResult,
    CountryState,
)

from .normalize import (
    country_flag,
    normalize_country_code,
    normalize_country_name,
)


def decide_country_consensus(
    *,
    config_id: str,
    evidence: list[CountryEvidence],
    minimum_agreement: int = 2,
) -> CountryResult:

    usable = [
        item
        for item in evidence
        if (
            item.success
            and normalize_country_code(
                item.country_code
            ) is not None
        )
    ]

    if not usable:
        return CountryResult(
            config_id=config_id,
            state=CountryState.UNKNOWN,
            confidence=0.0,
            method="geo_consensus",
            providers_total=len(evidence),
            reason="no_usable_country_evidence",
            evidence=tuple(evidence),
        )

    counts = Counter(
        normalize_country_code(item.country_code)
        for item in usable
    )

    code, agreed = counts.most_common(1)[0]

    total = len(usable)

    confidence = agreed / total

    names = [
        normalize_country_name(item.country_name)
        for item in usable
        if normalize_country_code(item.country_code) == code
    ]

    names = [x for x in names if x]

    country_name = (
        Counter(names).most_common(1)[0][0]
        if names
        else None
    )

    ips = {
        item.exit_ip
        for item in usable
        if item.exit_ip
    }

    exit_ip = (
        next(iter(ips))
        if len(ips) == 1
        else None
    )

    if agreed >= minimum_agreement and confidence >= 0.67:
        state = CountryState.CONFIRMED
        reason = "country_consensus"
    else:
        state = CountryState.AMBIGUOUS
        reason = "country_provider_disagreement"

    return CountryResult(
        config_id=config_id,
        state=state,
        country_code=code if state == CountryState.CONFIRMED else None,
        country_name=country_name if state == CountryState.CONFIRMED else None,
        flag=country_flag(code) if state == CountryState.CONFIRMED else None,
        exit_ip=exit_ip,
        confidence=confidence,
        method="geo_consensus",
        providers_agreed=agreed,
        providers_total=total,
        reason=reason,
        evidence=tuple(evidence),
    )
PY

cat >"$M/storage.py" <<'PY'
from __future__ import annotations

import json
import os
import tempfile

from datetime import datetime, timezone
from pathlib import Path

from .models import CountryResult


ROOT = Path(
    "/var/lib/config-location/"
    "country/results"
)

LATEST = ROOT / "latest"
HISTORY = ROOT / "history"


def _atomic_json(
    path: Path,
    value: dict,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix="." + path.name + ".",
        suffix=".tmp",
    )

    try:
        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                value,
                f,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            f.write("\n")
            f.flush()
            os.fsync(f.fileno())

        os.replace(tmp, path)

    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

        raise


def save_country_result(
    result: CountryResult,
) -> tuple[Path, Path]:

    o = result.to_dict()

    stamp = datetime.now(
        timezone.utc
    ).strftime("%Y%m%dT%H%M%S.%fZ")

    latest = (
        LATEST
        / f"{result.config_id}.json"
    )

    history_dir = (
        HISTORY
        / result.config_id
    )

    history = (
        history_dir
        / f"{stamp}.json"
    )

    _atomic_json(history, o)
    _atomic_json(latest, o)

    return latest, history
PY

cat >"$M/selftest.py" <<'PY'
from __future__ import annotations

from .eligibility import (
    decide_country_eligibility,
)

from .models import (
    CountryEvidence,
    CountryState,
    EvidenceKind,
)

from .consensus import (
    decide_country_consensus,
)

from .normalize import (
    country_flag,
    normalize_country_code,
)


def main() -> int:

    assert normalize_country_code("de") == "DE"
    assert country_flag("DE") == "🇩🇪"

    print("[PASS] normalize")

    assert decide_country_eligibility(
        {"state": "healthy"}
    ).eligible is True

    assert decide_country_eligibility(
        {"state": "unhealthy"}
    ).eligible is False

    assert decide_country_eligibility(
        {"state": "error"}
    ).eligible is False

    print("[PASS] eligibility")

    evidence = [
        CountryEvidence(
            provider="geo-a",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            exit_ip="1.2.3.4",
            country_code="DE",
            country_name="Germany",
        ),
        CountryEvidence(
            provider="geo-b",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            exit_ip="1.2.3.4",
            country_code="DE",
            country_name="Germany",
        ),
        CountryEvidence(
            provider="geo-c",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            exit_ip="1.2.3.4",
            country_code="DE",
            country_name="Germany",
        ),
    ]

    r = decide_country_consensus(
        config_id="test",
        evidence=evidence,
    )

    assert r.state == CountryState.CONFIRMED
    assert r.country_code == "DE"
    assert r.country_name == "Germany"
    assert r.flag == "🇩🇪"
    assert r.exit_ip == "1.2.3.4"

    print("[PASS] unanimous consensus")

    conflict = [
        CountryEvidence(
            provider="a",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            country_code="DE",
        ),
        CountryEvidence(
            provider="b",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            country_code="US",
        ),
    ]

    r = decide_country_consensus(
        config_id="conflict",
        evidence=conflict,
    )

    assert r.state == CountryState.AMBIGUOUS

    print("[PASS] ambiguous")

    print("[PASS] FIX22B")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

echo "=== COMPILE ==="

"$PY" -m py_compile \
"$M/__init__.py" \
"$M/models.py" \
"$M/normalize.py" \
"$M/eligibility.py" \
"$M/consensus.py" \
"$M/storage.py" \
"$M/selftest.py"

echo "COMPILE=PASS"

echo "=== SELFTEST ==="

PYTHONPATH="$R" \
"$PY" -m app.country.selftest

echo "=== STORAGE TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.models import (
    CountryResult,
    CountryState,
)

from app.country.storage import (
    save_country_result,
)

r = CountryResult(
    config_id="FIX22B-SELFTEST",
    state=CountryState.CONFIRMED,
    country_code="DE",
    country_name="Germany",
    flag="🇩🇪",
    exit_ip="203.0.113.1",
    confidence=1.0,
    method="selftest",
)

latest, history = save_country_result(r)

assert latest.exists()
assert history.exists()

print("LATEST=", latest)
print("HISTORY=", history)

latest.unlink()

for p in history.parent.glob("*.json"):
    p.unlink()

try:
    history.parent.rmdir()
except OSError:
    pass

print("STORAGE=PASS")
PY

echo "=== SERVICES ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo "========================================"
echo "FIX22B=PASS"
echo "COUNTRY_CORE_FOUNDATION=COMPLETE"
echo "CONFIDENCE_MODEL=READY"
echo "EVIDENCE_MODEL=READY"
echo "CONSENSUS_ENGINE=READY"
echo "COUNTRY_STORAGE=READY"
echo "SERVICES=ACTIVE"
echo "========================================"
