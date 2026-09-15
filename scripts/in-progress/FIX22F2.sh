#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

cat >"$M/verdict_fusion.py" <<'PY'
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
PY


cat >"$M/selftest_verdict_fusion.py" <<'PY'
from __future__ import annotations

from .verdict_fusion import (
    fuse_country_verdict,
)


def main() -> int:

    # Strong primary retained.
    r=fuse_country_verdict(
        primary={
            "state":"confirmed",
            "country_code":"DE",
            "country_name":"Germany",
            "flag":"🇩🇪",
            "country_confidence":1.0,
        },
        recovery=None,
    )

    assert r.state=="confirmed"
    assert r.country_code=="DE"
    assert r.source=="primary"

    print(
        "[PASS] strong primary retained"
    )


    # Weak/unknown primary recovered.
    r=fuse_country_verdict(
        primary={
            "state":"unknown",
            "country_code":None,
            "country_confidence":0.0,
        },
        recovery={
            "state":"confirmed",
            "country_code":"DE",
            "country_name":"Germany",
            "flag":"🇩🇪",
            "confidence":1.0,
        },
    )

    assert r.state=="confirmed"
    assert r.country_code=="DE"
    assert r.source=="recovery"

    print(
        "[PASS] unknown recovered"
    )


    # Strong disagreement must never pick one side.
    r=fuse_country_verdict(
        primary={
            "state":"confirmed",
            "country_code":"DE",
            "country_confidence":1.0,
        },
        recovery={
            "state":"confirmed",
            "country_code":"US",
            "confidence":1.0,
        },
    )

    assert r.state=="ambiguous"
    assert r.country_code is None
    assert r.conflict is True

    print(
        "[PASS] strong conflict blocked"
    )


    # Weak signal conflict also blocked.
    r=fuse_country_verdict(
        primary={
            "state":"ambiguous",
            "country_code":"DE",
            "country_confidence":0.5,
        },
        recovery={
            "state":"confirmed",
            "country_code":"US",
            "confidence":1.0,
        },
    )

    assert r.state=="ambiguous"
    assert r.country_code is None

    print(
        "[PASS] weak conflict blocked"
    )


    # No evidence remains unknown.
    r=fuse_country_verdict(
        primary={
            "state":"unknown",
            "country_code":None,
        },
        recovery={
            "state":"unknown",
            "country_code":None,
        },
    )

    assert r.state=="unknown"

    print(
        "[PASS] unknown remains unknown"
    )


    # Temporal rotation is preserved.
    r=fuse_country_verdict(
        primary={
            "state":"rotating",
            "country_code":None,
        },
        recovery=None,
    )

    assert r.state=="rotating"

    print(
        "[PASS] rotation preserved"
    )


    print(
        "[PASS] FIX22F2 verdict fusion"
    )

    return 0


if __name__=="__main__":
    raise SystemExit(
        main()
    )
PY


echo "=== 1. COMPILE ==="

"$PY" -m py_compile \
"$M/verdict_fusion.py" \
"$M/selftest_verdict_fusion.py"

echo "COMPILE=PASS"


echo "=== 2. SELFTEST ==="

PYTHONPATH="$R" \
"$PY" -m app.country.selftest_verdict_fusion

echo "SELFTEST=PASS"


echo "=== 3. REAL PRIMARY + RECOVERY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.geo_intelligence import (
    resolve_geo,
)

from app.country.recovery import (
    recover_country,
)

from app.country.verdict_fusion import (
    fuse_country_verdict,
)


IP="91.107.184.117"

primary=resolve_geo(
    config_id="FIX22F2-REAL",
    ip=IP,
)

# Force secondary execution for cross-layer
# verification only.
recovery=recover_country(
    ip=IP,
    previous_state="unknown",
)

print(
    "PRIMARY=",
    primary["state"],
    primary["country_code"],
    primary["country_confidence"],
)

print(
    "RECOVERY=",
    recovery["state"],
    recovery.get("country_code"),
    recovery.get("confidence"),
)

fused=fuse_country_verdict(
    primary=primary,
    recovery=recovery,
)

print(
    "FUSED=",
    fused.to_dict(),
)

assert (
    primary["country_code"]
    == "DE"
)

assert (
    recovery["country_code"]
    == "DE"
)

assert (
    fused.country_code
    == "DE"
)

assert (
    fused.state
    == "confirmed"
)

assert (
    fused.conflict
    is False
)

print(
    "REAL_CROSS_LAYER_CONSENSUS=PASS"
)
PY


echo "=== 4. SYNTHETIC CONFLICT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.verdict_fusion import (
    fuse_country_verdict,
)

r=fuse_country_verdict(
    primary={
        "state":"confirmed",
        "country_code":"DE",
        "country_name":"Germany",
        "country_confidence":1.0,
    },
    recovery={
        "state":"confirmed",
        "country_code":"US",
        "country_name":"United States",
        "confidence":1.0,
    },
)

print(
    r.to_dict()
)

assert r.state=="ambiguous"
assert r.country_code is None
assert r.conflict is True

print(
    "CROSS_LAYER_CONFLICT_BLOCK=PASS"
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
    X=$(systemctl is-active "$svc" 2>/dev/null || true)

    echo "$svc=$X"

    test "$X" = active
done


echo "========================================"
echo "FIX22F2=PASS"
echo "FINAL_VERDICT_FUSION=READY"
echo "PRIMARY_AUTHORITY=PROTECTED"
echo "SECONDARY_RECOVERY=READY"
echo "CROSS_LAYER_CONFLICT=AMBIGUOUS"
echo "FALSE_COUNTRY_OVERWRITE=BLOCKED"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
