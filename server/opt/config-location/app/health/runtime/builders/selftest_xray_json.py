from __future__ import annotations

import json
import tempfile
from pathlib import Path

from .xray_json import (
    XrayJsonRuntimeBuilder,
    XrayJsonBuilderError,
)

from ...plugins.types import RuntimeRequest


def main():

    original = {
        "log": {
            "loglevel": "debug",
        },

        "dns": {
            "servers": ["1.1.1.1"],
        },

        "inbounds": [
            {
                "port": 9999,
                "protocol": "socks",
            }
        ],

        "outbounds": [
            {
                "protocol": "freedom",
                "tag": "direct",
            },
            {
                "protocol": "vless",
                "tag": "proxy-original",
                "settings": {
                    "vnext": [
                        {
                            "address": "example.invalid",
                            "port": 443,
                            "users": [
                                {
                                    "id": (
                                        "00000000-0000-"
                                        "0000-0000-"
                                        "000000000000"
                                    ),
                                    "encryption": "none",
                                }
                            ],
                        }
                    ]
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "none",
                },
            },
        ],

        "routing": {
            "rules": [
                {
                    "type": "field",
                    "domain": ["example.com"],
                    "outboundTag": "direct",
                }
            ]
        },
    }

    builder = XrayJsonRuntimeBuilder()

    assert builder.supports(
        "json_xray"
    )

    with tempfile.TemporaryDirectory() as td:

        artifact = builder.build_runtime(
            RuntimeRequest(
                config_id="test-json",
                config_type="json_xray",
                source=json.dumps(original),
                sandbox_dir=Path(td),
                socks_port=34567,
            )
        )

        runtime = json.loads(
            artifact.config_path.read_text()
        )

        assert runtime["inbounds"][0]["port"] == 34567

        assert len(runtime["outbounds"]) == 2

        proxy = runtime["outbounds"][0]

        assert proxy["protocol"] == "vless"
        assert proxy["tag"] == "health-proxy"

        assert (
            proxy["settings"]
            == original["outbounds"][1]["settings"]
        )

        assert (
            proxy["streamSettings"]
            == original["outbounds"][1]["streamSettings"]
        )

        assert "dns" not in runtime

        assert (
            runtime["routing"]["rules"][0]
            ["outboundTag"]
            == "health-proxy"
        )

        assert (
            artifact.config_path.stat().st_mode
            & 0o777
        ) == 0o600

    try:
        builder.build_runtime(
            RuntimeRequest(
                config_id="bad",
                config_type="json_xray",
                source='{"outbounds":[]}',
                sandbox_dir=Path("/tmp/unused"),
                socks_port=12345,
            )
        )
    except XrayJsonBuilderError:
        pass
    else:
        raise AssertionError(
            "missing proxy outbound accepted"
        )

    print("[PASS] json parsed")
    print("[PASS] real outbound extracted")
    print("[PASS] original outbound settings preserved")
    print("[PASS] original streamSettings preserved")
    print("[PASS] original routing removed")
    print("[PASS] original DNS removed")
    print("[PASS] minimal isolated runtime")
    print("[PASS] dynamic SOCKS port")
    print("[PASS] config mode 0600")
    print("[PASS] HT4.1 builder")


if __name__ == "__main__":
    main()
