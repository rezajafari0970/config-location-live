from __future__ import annotations

import base64
import ipaddress
import json
import re

from pathlib import Path
from typing import Any
from urllib.parse import (
    parse_qs,
    unquote,
    urlsplit,
)

from ...plugins.base import RuntimeBuilderPlugin
from ...plugins.types import (
    RuntimeArtifact,
    RuntimeRequest,
)


class WireGuardRuntimeBuilderError(
    ValueError
):
    pass


def _b64decode_maybe(
    value: str,
) -> str | None:
    try:
        return base64.b64decode(
            value + "=" * (-len(value) % 4),
            validate=False,
        ).decode("utf-8")
    except Exception:
        return None


def _first(
    mapping: dict[str, Any],
    *names: str,
) -> str:
    lower = {
        str(k).lower(): v
        for k, v in mapping.items()
    }

    for name in names:
        value = lower.get(
            name.lower()
        )

        if isinstance(value, list):
            value = (
                value[0]
                if value
                else ""
            )

        if value is not None:
            text = str(value).strip()

            if text:
                return text

    return ""


def _split_addresses(
    value: Any,
) -> list[str]:

    if isinstance(value, list):
        items = value
    else:
        items = re.split(
            r'[,;\s]+',
            str(value or ""),
        )

    result = []

    for item in items:
        item = str(item).strip()

        if not item:
            continue

        # Xray WireGuard accepts CIDR addresses.
        try:
            ipaddress.ip_interface(
                item
            )
        except Exception:
            continue

        result.append(item)

    return result


def _parse_wg_quick(
    text: str,
) -> dict[str, Any]:

    section = None
    interface: dict[str, str] = {}
    peers: list[dict[str, str]] = []
    peer: dict[str, str] | None = None

    for original in text.splitlines():

        line = original.strip()

        if (
            not line
            or line.startswith("#")
            or line.startswith(";")
        ):
            continue

        if (
            line.startswith("[")
            and line.endswith("]")
        ):

            section = (
                line[1:-1]
                .strip()
                .lower()
            )

            if section == "peer":
                peer = {}
                peers.append(peer)

            continue

        if "=" not in line:
            continue

        key, value = line.split(
            "=",
            1,
        )

        key = key.strip()
        value = value.strip()

        if section == "interface":
            interface[key] = value

        elif (
            section == "peer"
            and peer is not None
        ):
            peer[key] = value


    if not peers:
        raise WireGuardRuntimeBuilderError(
            "WireGuard peer missing"
        )

    private_key = _first(
        interface,
        "PrivateKey",
        "SecretKey",
    )

    address = _split_addresses(
        _first(
            interface,
            "Address",
        )
    )

    mtu_raw = _first(
        interface,
        "MTU",
    )

    output_peers = []

    for item in peers:

        public_key = _first(
            item,
            "PublicKey",
        )

        endpoint = _first(
            item,
            "Endpoint",
        )

        if (
            not public_key
            or not endpoint
        ):
            continue

        p: dict[str, Any] = {
            "publicKey": public_key,
            "endpoint": endpoint,
        }

        pre = _first(
            item,
            "PresharedKey",
            "PreSharedKey",
        )

        if pre:
            p["preSharedKey"] = pre

        keepalive = _first(
            item,
            "PersistentKeepalive",
            "KeepAlive",
        )

        if keepalive:
            try:
                p["keepAlive"] = int(
                    keepalive
                )
            except Exception:
                pass

        output_peers.append(p)


    if not private_key:
        raise WireGuardRuntimeBuilderError(
            "WireGuard private key missing"
        )

    if not address:
        raise WireGuardRuntimeBuilderError(
            "WireGuard address missing"
        )

    if not output_peers:
        raise WireGuardRuntimeBuilderError(
            "WireGuard valid peer missing"
        )


    result: dict[str, Any] = {
        "secretKey": private_key,
        "address": address,
        "peers": output_peers,
    }

    if mtu_raw:
        try:
            result["mtu"] = int(
                mtu_raw
            )
        except Exception:
            pass

    return result


def _parse_json(
    value: Any,
) -> dict[str, Any]:

    if not isinstance(
        value,
        dict,
    ):
        raise WireGuardRuntimeBuilderError(
            "WireGuard JSON must be object"
        )

    # If already an Xray outbound.
    if (
        value.get("protocol")
        == "wireguard"
        and isinstance(
            value.get("settings"),
            dict,
        )
    ):
        return dict(
            value["settings"]
        )

    # Common standalone formats.
    private_key = _first(
        value,
        "secretKey",
        "privateKey",
        "private_key",
    )

    address = value.get(
        "address",
        value.get(
            "addresses",
            value.get("Address"),
        ),
    )

    peers_raw = value.get(
        "peers",
        value.get("Peers"),
    )

    if (
        private_key
        and address
        and isinstance(
            peers_raw,
            list,
        )
    ):

        peers = []

        for item in peers_raw:

            if not isinstance(
                item,
                dict,
            ):
                continue

            public_key = _first(
                item,
                "publicKey",
                "public_key",
                "PublicKey",
            )

            endpoint = _first(
                item,
                "endpoint",
                "Endpoint",
            )

            if (
                not public_key
                or not endpoint
            ):
                continue

            p = {
                "publicKey":
                    public_key,

                "endpoint":
                    endpoint,
            }

            pre = _first(
                item,
                "preSharedKey",
                "presharedKey",
                "PresharedKey",
            )

            if pre:
                p["preSharedKey"] = pre

            peers.append(p)

        if peers:

            out = {
                "secretKey":
                    private_key,

                "address":
                    _split_addresses(
                        address
                    ),

                "peers":
                    peers,
            }

            mtu = value.get(
                "mtu",
                value.get("MTU"),
            )

            if mtu is not None:
                try:
                    out["mtu"] = int(
                        mtu
                    )
                except Exception:
                    pass

            return out


    raise WireGuardRuntimeBuilderError(
        "unsupported WireGuard JSON structure"
    )


def _parse_uri(
    raw: str,
) -> dict[str, Any]:

    p = urlsplit(
        raw
    )

    q = {
        k.lower(): v
        for k, v in parse_qs(
            p.query,
            keep_blank_values=True,
        ).items()
    }

    def q1(
        *names: str,
    ) -> str:

        for name in names:
            values = q.get(
                name.lower()
            )

            if values:
                value = (
                    values[0]
                    .strip()
                )

                if value:
                    return unquote(
                        value
                    )

        return ""


    # Several WireGuard URI generators encode
    # private key in username.
    private_key = (
        unquote(
            p.username or ""
        )
        or q1(
            "privatekey",
            "private_key",
            "secretkey",
        )
    )

    public_key = q1(
        "publickey",
        "public_key",
        "peerpublickey",
    )

    pre_shared = q1(
        "presharedkey",
        "pre_shared_key",
        "psk",
    )

    address = q1(
        "address",
        "addresses",
        "localaddress",
    )

    endpoint = ""

    host = p.hostname
    port = p.port

    if (
        host
        and port
    ):
        endpoint = (
            f"{host}:{port}"
        )

    if not endpoint:
        endpoint = q1(
            "endpoint",
        )


    if (
        not private_key
        or not public_key
        or not endpoint
        or not address
    ):
        raise WireGuardRuntimeBuilderError(
            "WireGuard URI missing required fields"
        )


    peer: dict[str, Any] = {
        "publicKey":
            public_key,

        "endpoint":
            endpoint,
    }

    if pre_shared:
        peer[
            "preSharedKey"
        ] = pre_shared


    result: dict[str, Any] = {
        "secretKey":
            private_key,

        "address":
            _split_addresses(
                address
            ),

        "peers":
            [peer],
    }

    mtu = q1(
        "mtu",
    )

    if mtu:
        try:
            result["mtu"] = int(
                mtu
            )
        except Exception:
            pass

    reserved = q1(
        "reserved",
    )

    if reserved:

        try:
            result["reserved"] = [
                int(x)
                for x in re.split(
                    r'[,.\s]+',
                    reserved,
                )
                if x.strip()
            ]
        except Exception:
            pass


    return result


def parse_wireguard(
    raw: str,
) -> dict[str, Any]:

    text = raw.strip()

    if not text:
        raise WireGuardRuntimeBuilderError(
            "empty WireGuard source"
        )

    if text.startswith(
        ("{", "[")
    ):
        return _parse_json(
            json.loads(text)
        )

    if "[interface]" in text.lower():
        return _parse_wg_quick(
            text
        )

    if "://" in text:
        return _parse_uri(
            text
        )

    decoded = _b64decode_maybe(
        text
    )

    if decoded:

        decoded = decoded.strip()

        if "[interface]" in decoded.lower():
            return _parse_wg_quick(
                decoded
            )

        if decoded.startswith(
            ("{", "[")
        ):
            return _parse_json(
                json.loads(decoded)
            )

    raise WireGuardRuntimeBuilderError(
        "unsupported WireGuard source format"
    )


def minimal_runtime(
    settings: dict[str, Any],
    socks_port: int,
) -> dict[str, Any]:

    return {
        "log": {
            "loglevel": "warning",
        },

        "inbounds": [
            {
                "listen":
                    "127.0.0.1",

                "port":
                    socks_port,

                "protocol":
                    "socks",

                "settings": {
                    "auth":
                        "noauth",

                    "udp":
                        True,
                },

                "tag":
                    "health-socks",
            }
        ],

        "outbounds": [
            {
                "protocol":
                    "wireguard",

                "tag":
                    "health-proxy",

                "settings":
                    settings,
            },

            {
                "protocol":
                    "blackhole",

                "tag":
                    "health-block",
            },
        ],

        "routing": {
            "domainStrategy":
                "AsIs",

            "rules": [
                {
                    "type":
                        "field",

                    "network":
                        "tcp,udp",

                    "outboundTag":
                        "health-proxy",
                }
            ],
        },
    }


class WireGuardXrayRuntimeBuilder(
    RuntimeBuilderPlugin
):
    plugin_name = (
        "runtime-wireguard-xray"
    )

    plugin_version = "1"

    def describe(self):
        return {
            "name":
                self.plugin_name,

            "version":
                self.plugin_version,

            "types":
                ["wireguard"],
        }

    def supports(
        self,
        config_type: str,
    ) -> bool:

        return (
            config_type
            .strip()
            .lower()
            == "wireguard"
        )

    def build_runtime(
        self,
        request: RuntimeRequest,
    ) -> RuntimeArtifact:

        if not isinstance(
            request.source,
            str,
        ):
            raise WireGuardRuntimeBuilderError(
                "WireGuard source must be string"
            )

        settings = parse_wireguard(
            request.source
        )

        runtime = minimal_runtime(
            settings,
            request.socks_port,
        )

        request.sandbox_dir.mkdir(
            parents=True,
            exist_ok=True,
        )

        path = (
            request.sandbox_dir
            / "config.json"
        )

        path.write_text(
            json.dumps(
                runtime,
                ensure_ascii=False,
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )

        path.chmod(0o600)

        return RuntimeArtifact(
            config_path=path,

            socks_host=
                "127.0.0.1",

            socks_port=
                request.socks_port,

            metadata={
                "builder":
                    self.plugin_name,

                "protocol":
                    "wireguard",

                "network":
                    "wireguard",

                "security":
                    "wireguard",
            },
        )
