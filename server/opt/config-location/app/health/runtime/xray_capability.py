from __future__ import annotations

import json

from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs,urlsplit


MATRIX=Path(
    "/var/lib/config-location/"
    "integrity/xray-runtime/"
    "capability-matrix.json"
)


XRAY_TYPES={
    "vless",
    "vmess",
    "trojan",
    "ss",
    "socks",
    "wireguard",
    "json_xray",
}


NON_XRAY_TYPES={
    "hysteria",
    "hysteria2",
    "hy",
    "hy2",
    "tuic",
    "anytls",
    "naive",
    "juicity",
}


XRAY_PROTOCOLS={
    "vless",
    "vmess",
    "trojan",
    "shadowsocks",
    "socks",
    "wireguard",
}


INTERNAL={
    "freedom",
    "blackhole",
    "dns",
}


TRANSPORT_ALIASES={
    "raw":"tcp",
    "mkcp":"kcp_legacy",
    "kcp":"kcp_legacy",
    "http":"http_h2_legacy",
    "h2":"http_h2_legacy",
}


PROTOCOL_ALIASES={
    "ss":"shadowsocks",
}


@dataclass(frozen=True)
class CapabilityDecision:
    supported: bool
    status: str
    reason: str
    protocol: str | None = None
    network: str | None = None
    security: str | None = None


def load_matrix() -> dict:

    try:
        obj=json.loads(
            MATRIX.read_text(
                encoding="utf-8"
            )
        )
    except Exception:
        return {}

    if not isinstance(obj,dict):
        return {}

    return obj


def _q(query,name,default=None):

    values=query.get(name)

    if not values:
        return default

    return str(values[-1])


def _uri_characteristics(
    raw: str,
):

    try:
        u=urlsplit(raw)
    except Exception:
        return None,None,None

    protocol=u.scheme.lower()

    protocol=PROTOCOL_ALIASES.get(
        protocol,
        protocol,
    )

    query=parse_qs(
        u.query,
        keep_blank_values=True,
    )

    network=str(
        _q(
            query,
            "type",
            "tcp",
        )
        or "tcp"
    ).lower()

    security=str(
        _q(
            query,
            "security",
            "none",
        )
        or "none"
    ).lower()

    flow=_q(
        query,
        "flow",
    )

    if (
        protocol=="vless"
        and
        security=="reality"
        and
        flow=="xtls-rprx-vision"
    ):
        security="vision_reality"

    return (
        protocol,
        network,
        security,
    )


def _json_proxy_outbound(
    source: Any,
):

    if isinstance(source,dict):
        obj=source

    elif isinstance(source,str):
        try:
            obj=json.loads(source)
        except Exception:
            return None

    else:
        return None

    if not isinstance(obj,dict):
        return None

    outbounds=obj.get(
        "outbounds"
    )

    if not isinstance(outbounds,list):
        return None

    selected=set()

    routing=obj.get(
        "routing"
    )

    if isinstance(routing,dict):
        rules=routing.get(
            "rules"
        )

        if isinstance(rules,list):
            for rule in rules:
                if not isinstance(rule,dict):
                    continue

                tag=rule.get(
                    "outboundTag"
                )

                if isinstance(tag,str):
                    selected.add(tag)

    candidates=[]

    for outbound in outbounds:

        if not isinstance(outbound,dict):
            continue

        protocol=str(
            outbound.get(
                "protocol",
                "",
            )
        ).lower()

        if (
            not protocol
            or
            protocol in INTERNAL
        ):
            continue

        tag=str(
            outbound.get(
                "tag",
                "",
            )
        )

        candidates.append(
            (
                tag in selected,
                outbound,
            )
        )

    if not candidates:
        return None

    candidates.sort(
        key=lambda x:
            not x[0]
    )

    return candidates[0][1]


def _json_characteristics(
    source: Any,
):

    outbound=_json_proxy_outbound(
        source
    )

    if outbound is None:
        return None,None,None

    protocol=str(
        outbound.get(
            "protocol",
            "",
        )
    ).lower()

    protocol=PROTOCOL_ALIASES.get(
        protocol,
        protocol,
    )

    network="tcp"
    security="none"

    stream=outbound.get(
        "streamSettings"
    )

    if isinstance(stream,dict):

        network=str(
            stream.get(
                "network",
                "tcp",
            )
            or "tcp"
        ).lower()

        security=str(
            stream.get(
                "security",
                "none",
            )
            or "none"
        ).lower()

    if (
        protocol=="vless"
        and
        security=="reality"
    ):

        settings=outbound.get(
            "settings"
        )

        if isinstance(settings,dict):

            vnext=settings.get(
                "vnext"
            )

            if (
                isinstance(vnext,list)
                and vnext
                and isinstance(vnext[0],dict)
            ):

                users=vnext[0].get(
                    "users"
                )

                if (
                    isinstance(users,list)
                    and users
                    and isinstance(users[0],dict)
                    and
                    users[0].get("flow")
                    ==
                    "xtls-rprx-vision"
                ):
                    security="vision_reality"

    return (
        protocol,
        network,
        security,
    )


def classify_xray_capability(
    config_type: str,
    source: Any,
) -> CapabilityDecision:

    kind=str(
        config_type
        or ""
    ).strip().lower()

    if kind in NON_XRAY_TYPES:

        return CapabilityDecision(
            False,
            "unsupported_by_xray",
            "protocol_outside_xray_scope",
            protocol=kind,
        )

    if kind not in XRAY_TYPES:

        return CapabilityDecision(
            False,
            "not_tested",
            "unknown_config_type",
        )

    if kind=="json_xray":

        (
            protocol,
            network,
            security,
        )=_json_characteristics(
            source
        )

        if protocol is None:

            return CapabilityDecision(
                False,
                "invalid",
                "json_proxy_outbound_missing",
            )

    elif kind=="wireguard":

        protocol="wireguard"
        network=None
        security=None

    else:

        protocol=PROTOCOL_ALIASES.get(
            kind,
            kind,
        )

        network=None
        security=None

        if isinstance(source,str):

            (
                up,
                un,
                us,
            )=_uri_characteristics(
                source
            )

            if up:
                protocol=up

            network=un
            security=us

    if protocol not in XRAY_PROTOCOLS:

        return CapabilityDecision(
            False,
            "unsupported_by_xray",
            "outbound_protocol_not_supported",
            protocol=protocol,
            network=network,
            security=security,
        )

    matrix=load_matrix()

    pstate=(
        matrix
        .get("protocols",{})
        .get(protocol)
    )

    if (
        isinstance(pstate,dict)
        and
        pstate.get("supported")
        is False
    ):

        return CapabilityDecision(
            False,
            "unsupported_by_xray_version",
            "installed_xray_rejects_protocol",
            protocol=protocol,
            network=network,
            security=security,
        )

    if network:

        transport_key=TRANSPORT_ALIASES.get(
            network,
            network,
        )

        tstate=(
            matrix
            .get("transports",{})
            .get(transport_key)
        )

        if (
            isinstance(tstate,dict)
            and
            tstate.get("supported")
            is False
        ):

            return CapabilityDecision(
                False,
                "unsupported_by_xray_version",
                (
                    "installed_xray_rejects_transport:"
                    +network
                ),
                protocol=protocol,
                network=network,
                security=security,
            )

    if security in {
        "tls",
        "reality",
        "vision_reality",
    }:

        sstate=(
            matrix
            .get("security",{})
            .get(security)
        )

        if (
            isinstance(sstate,dict)
            and
            sstate.get("supported")
            is False
        ):

            return CapabilityDecision(
                False,
                "unsupported_by_xray_version",
                (
                    "installed_xray_rejects_security:"
                    +security
                ),
                protocol=protocol,
                network=network,
                security=security,
            )

    return CapabilityDecision(
        True,
        "supported",
        "xray_capable",
        protocol=protocol,
        network=network,
        security=security,
    )
