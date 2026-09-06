from __future__ import annotations

import json
from typing import Any

from ...plugins.base import RuntimeBuilderPlugin
from ...plugins.types import RuntimeArtifact, RuntimeRequest
from .uri_parser import ParsedProxy, parse_proxy_uri
from .tls_policy import secure_tls_runtime


class UriRuntimeBuilderError(ValueError):
    pass


def q(p: ParsedProxy, key: str, default: str = "") -> str:
    value = p.query.get(key, default)
    return str(value) if value is not None else default


def as_bool(value: str) -> bool:
    return str(value).strip().lower() in {
        "1", "true", "yes", "on"
    }


def security_settings(p: ParsedProxy) -> dict[str, Any]:
    security = p.security.lower()

    if security == "none":
        return {}

    if security == "tls":
        settings: dict[str, Any] = {}

        sni = q(p, "sni")
        fp = q(p, "fp")
        alpn = q(p, "alpn")

        if sni:
            settings["serverName"] = sni

        if fp:
            settings["fingerprint"] = fp

        if alpn:
            settings["alpn"] = [
                x.strip()
                for x in alpn.split(",")
                if x.strip()
            ]

        # Xray 26.x removed allowInsecure.
        # Do not inject this deprecated client-side
        # compatibility flag into health runtime.
        return {"tlsSettings": settings}

    if security == "reality":
        settings: dict[str, Any] = {}

        mapping = {
            "sni": "serverName",
            "fp": "fingerprint",
            "pbk": "publicKey",
            "sid": "shortId",
            "spx": "spiderX",
        }

        for source, target in mapping.items():
            value = q(p, source)
            if value:
                settings[target] = value

        return {"realitySettings": settings}

    raise UriRuntimeBuilderError(
        f"unsupported security: {security}"
    )


def stream_settings(p: ParsedProxy) -> dict[str, Any]:
    network = p.network.lower()
    xray_network = "tcp" if network == "raw" else network

    stream: dict[str, Any] = {
        "network": xray_network,
        "security": p.security.lower(),
    }

    stream.update(security_settings(p))

    host = q(p, "host")
    path = q(p, "path")
    header_type = q(p, "headerType")

    if network in {"tcp", "raw"}:
        tcp: dict[str, Any] = {}

        if header_type and header_type != "none":
            header: dict[str, Any] = {
                "type": header_type
            }

            if header_type == "http":
                request: dict[str, Any] = {}

                if path:
                    request["path"] = [path]

                if host:
                    request["headers"] = {
                        "Host": [host]
                    }

                if request:
                    header["request"] = request

            tcp["header"] = header

        if tcp:
            stream["tcpSettings"] = tcp

    elif network == "ws":
        ws: dict[str, Any] = {}

        if path:
            ws["path"] = path

        if host:
            ws["headers"] = {"Host": host}

        if ws:
            stream["wsSettings"] = ws

    elif network == "grpc":
        grpc: dict[str, Any] = {}

        service = q(p, "serviceName") or path
        authority = q(p, "authority")

        if service:
            grpc["serviceName"] = service

        if authority:
            grpc["authority"] = authority

        if grpc:
            stream["grpcSettings"] = grpc

    elif network == "httpupgrade":
        hu: dict[str, Any] = {}

        if path:
            hu["path"] = path

        if host:
            hu["host"] = host

        if hu:
            stream["httpupgradeSettings"] = hu

    elif network == "xhttp":
        xh: dict[str, Any] = {}

        if path:
            xh["path"] = path

        xhost = host or q(p, "authority")
        mode = q(p, "mode")

        if xhost:
            xh["host"] = xhost

        if mode:
            xh["mode"] = mode

        if xh:
            stream["xhttpSettings"] = xh

    else:
        raise UriRuntimeBuilderError(
            f"unsupported network: {network}"
        )

    return stream


def build_outbound(p: ParsedProxy) -> dict[str, Any]:
    if p.protocol == "vless":
        user: dict[str, Any] = {
            "id": p.user_id,
            "encryption": q(
                p, "encryption", "none"
            ) or "none",
        }

        flow = q(p, "flow")
        if flow:
            user["flow"] = flow

        return {
            "protocol": "vless",
            "tag": "health-proxy",
            "settings": {
                "vnext": [{
                    "address": p.host,
                    "port": p.port,
                    "users": [user],
                }]
            },
            "streamSettings": stream_settings(p),
        }

    if p.protocol == "vmess":
        try:
            aid = int(p.extras.get("aid", 0) or 0)
        except Exception:
            aid = 0

        query = dict(p.query)

        for target, source in (
            ("sni", "sni"),
            ("host", "host"),
            ("path", "path"),
            ("headerType", "type"),
            ("fp", "fp"),
        ):
            if not query.get(target):
                query[target] = str(
                    p.extras.get(source, "") or ""
                )

        vmess = ParsedProxy(
            protocol=p.protocol,
            host=p.host,
            port=p.port,
            user_id=p.user_id,
            password=p.password,
            method=p.method,
            network=p.network,
            security=p.security,
            query=query,
            extras=p.extras,
        )

        return {
            "protocol": "vmess",
            "tag": "health-proxy",
            "settings": {
                "vnext": [{
                    "address": p.host,
                    "port": p.port,
                    "users": [{
                        "id": p.user_id,
                        "alterId": aid,
                        "security": str(
                            p.extras.get(
                                "scy", "auto"
                            ) or "auto"
                        ),
                    }],
                }]
            },
            "streamSettings": stream_settings(vmess),
        }

    if p.protocol == "trojan":
        return {
            "protocol": "trojan",
            "tag": "health-proxy",
            "settings": {
                "servers": [{
                    "address": p.host,
                    "port": p.port,
                    "password": p.password,
                }]
            },
            "streamSettings": stream_settings(p),
        }

    if p.protocol == "socks":

        server = {
            "address": p.host,
            "port": p.port,
        }

        if p.user_id:

            server["users"] = [{
                "user":
                    p.user_id,

                "pass":
                    p.password or "",
            }]

        return {
            "protocol":
                "socks",

            "tag":
                "health-proxy",

            "settings":{
                "servers":[
                    server
                ],
            },
        }


    if p.protocol == "shadowsocks":
        if not p.method:
            raise UriRuntimeBuilderError(
                "shadowsocks method missing"
            )

        return {
            "protocol": "shadowsocks",
            "tag": "health-proxy",
            "settings": {
                "servers": [{
                    "address": p.host,
                    "port": p.port,
                    "method": p.method,
                    "password": p.password or "",
                }]
            },
        }

    raise UriRuntimeBuilderError(
        f"unsupported protocol: {p.protocol}"
    )


def minimal_runtime(
    outbound: dict[str, Any],
    socks_port: int,
) -> dict[str, Any]:
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": True,
            },
            "tag": "health-socks",
        }],
        "outbounds": [
            outbound,
            {
                "protocol": "blackhole",
                "tag": "health-block",
            },
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [{
                "type": "field",
                "network": "tcp,udp",
                "outboundTag": "health-proxy",
            }],
        },
    }


class UriXrayRuntimeBuilder(RuntimeBuilderPlugin):
    plugin_name = "runtime-uri-xray"
    plugin_version = "1"

    SUPPORTED = {
        "vless", "vmess", "trojan", "ss", "socks"
    }

    def describe(self):
        return {
            "name": self.plugin_name,
            "version": self.plugin_version,
            "types": sorted(self.SUPPORTED),
        }

    def supports(self, config_type: str) -> bool:
        return (
            config_type.strip().lower()
            in self.SUPPORTED
        )

    def build_runtime(
        self,
        request: RuntimeRequest,
    ) -> RuntimeArtifact:

        if not isinstance(request.source, str):
            raise UriRuntimeBuilderError(
                "URI source must be string"
            )

        parsed = parse_proxy_uri(
            request.source,
            request.config_type,
        )

        runtime = minimal_runtime(
            build_outbound(parsed),
            request.socks_port,
        )

        # Health policy:
        # force secure TLS semantics without
        # mutating source.raw.
        runtime = secure_tls_runtime(runtime)

        request.sandbox_dir.mkdir(
            parents=True,
            exist_ok=True,
        )

        path = request.sandbox_dir / "config.json"

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
            socks_host="127.0.0.1",
            socks_port=request.socks_port,
            metadata={
                "builder": self.plugin_name,
                "protocol": parsed.protocol,
                "network": parsed.network,
                "security": parsed.security,
            },
        )
