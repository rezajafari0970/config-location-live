from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from ...plugins.base import RuntimeBuilderPlugin
from ...plugins.types import RuntimeArtifact, RuntimeRequest
from .tls_policy import secure_tls_runtime


class XrayJsonBuilderError(ValueError):
    pass


def _as_object(source: Any) -> dict:
    if isinstance(source, dict):
        return copy.deepcopy(source)

    if not isinstance(source, str):
        raise XrayJsonBuilderError(
            "xray json source must be str or dict"
        )

    try:
        obj = json.loads(source)
    except Exception as exc:
        raise XrayJsonBuilderError(
            "invalid xray json"
        ) from exc

    if not isinstance(obj, dict):
        raise XrayJsonBuilderError(
            "xray json root must be object"
        )

    return obj



def _extract_proxy_outbound(
    obj: dict,
) -> dict:

    outbounds=obj.get(
        "outbounds"
    )

    if not isinstance(outbounds,list):
        raise XrayJsonBuilderError(
            "outbounds array missing"
        )

    internal={
        "freedom",
        "blackhole",
        "dns",
    }

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
            protocol in internal
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
        raise XrayJsonBuilderError(
            "no proxy outbound found"
        )

    candidates.sort(
        key=lambda item:
            not item[0]
    )

    return copy.deepcopy(
        candidates[0][1]
    )



def _minimal_runtime(
    outbound: dict,
    socks_port: int,
) -> dict:

    outbound = copy.deepcopy(outbound)
    outbound["tag"] = "health-proxy"

    return {
        "log": {
            "loglevel": "warning",
        },

        "inbounds": [
            {
                "listen": "127.0.0.1",
                "port": socks_port,
                "protocol": "socks",
                "settings": {
                    "auth": "noauth",
                    "udp": True,
                },
                "tag": "health-socks",
            }
        ],

        "outbounds": [
            outbound,
            {
                "protocol": "blackhole",
                "tag": "health-block",
            },
        ],

        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {
                    "type": "field",
                    "network": "tcp,udp",
                    "outboundTag": "health-proxy",
                }
            ],
        },
    }


class XrayJsonRuntimeBuilder(
    RuntimeBuilderPlugin
):
    plugin_name = "runtime-xray-json"
    plugin_version = "1"

    def describe(self):
        return {
            "name": self.plugin_name,
            "version": self.plugin_version,
            "strategy": (
                "extract-real-proxy-outbound"
            ),
        }

    def supports(self, config_type: str) -> bool:
        return (
            config_type.strip().lower()
            == "json_xray"
        )

    def build_runtime(
        self,
        request: RuntimeRequest,
    ) -> RuntimeArtifact:

        obj = _as_object(request.source)

        outbound = _extract_proxy_outbound(obj)

        runtime = _minimal_runtime(
            outbound,
            request.socks_port,
        )

        # JSON source may itself contain insecure
        # TLS flags. They are disabled only in the
        # generated health runtime.
        runtime = secure_tls_runtime(runtime)

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
            socks_host="127.0.0.1",
            socks_port=request.socks_port,
            metadata={
                "builder": self.plugin_name,
                "outbound_protocol": (
                    outbound.get("protocol")
                ),
            },
        )
