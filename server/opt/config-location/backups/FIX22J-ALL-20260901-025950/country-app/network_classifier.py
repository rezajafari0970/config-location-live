from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class NetworkClassification:
    network_type: str
    confidence: float
    signals: tuple[str, ...]


HOSTING_WORDS=(
    "hetzner",
    "digitalocean",
    "ovh",
    "linode",
    "vultr",
    "leaseweb",
    "contabo",
    "amazon",
    "aws",
    "google cloud",
    "microsoft",
    "azure",
    "oracle cloud",
    "datacamp",
    "m247",
)

CDN_WORDS=(
    "cloudflare",
    "akamai",
    "fastly",
    "cdn77",
    "bunny",
)


def classify_network(
    *,
    network_name: str | None,
) -> NetworkClassification:

    value=(
        network_name
        or ""
    ).strip().lower()

    if not value:
        return NetworkClassification(
            network_type="unknown",
            confidence=0.0,
            signals=(),
        )

    for word in CDN_WORDS:
        if word in value:
            return NetworkClassification(
                network_type="cdn",
                confidence=0.95,
                signals=(
                    f"name_contains:{word}",
                ),
            )

    for word in HOSTING_WORDS:
        if word in value:
            return NetworkClassification(
                network_type="hosting",
                confidence=0.90,
                signals=(
                    f"name_contains:{word}",
                ),
            )

    return NetworkClassification(
        network_type="isp_or_unknown",
        confidence=0.50,
        signals=(
            "no_known_hosting_or_cdn_signal",
        ),
    )
