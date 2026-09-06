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
