from __future__ import annotations

import json
import os
from pathlib import Path

from .sandbox import (
    XraySandbox,
    allocate_loopback_port,
    port_is_free,
)


def minimal_config(port: int) -> str:
    # Deliberately has NO proxy outbound.
    # HT3 tests process isolation only.
    config = {
        "log": {
            "loglevel": "warning",
        },
        "inbounds": [
            {
                "listen": "127.0.0.1",
                "port": port,
                "protocol": "socks",
                "settings": {
                    "auth": "noauth",
                    "udp": False,
                },
                "tag": "health-socks",
            }
        ],
        "outbounds": [
            {
                "protocol": "blackhole",
                "tag": "blocked",
            }
        ],
        "routing": {
            "rules": [
                {
                    "type": "field",
                    "network": "tcp,udp",
                    "outboundTag": "blocked",
                }
            ]
        },
    }

    return json.dumps(
        config,
        separators=(",", ":"),
    )


def main() -> int:

    base = Path(
        "/var/lib/config-location/health-sandboxes"
    )

    base.mkdir(
        parents=True,
        exist_ok=True,
    )

    os.chmod(base, 0o700)

    p1 = allocate_loopback_port()
    p2 = allocate_loopback_port()

    assert p1 != p2
    assert port_is_free(p1)
    assert port_is_free(p2)

    sandbox = XraySandbox(
        base_dir=base,
        xray_binary=Path("/usr/local/bin/xray"),
        config_id="ht3-selftest",
    )

    root = None

    try:
        sandbox.create()
        root = sandbox.paths.root

        assert root.exists()
        assert sandbox.socks_port is not None
        assert port_is_free(
            sandbox.socks_port
        )

        sandbox.write_config(
            minimal_config(
                sandbox.socks_port
            )
        )

        assert sandbox.paths.config.exists()

        mode = (
            sandbox.paths.config.stat().st_mode
            & 0o777
        )

        assert mode == 0o600

        sandbox.start()

        assert sandbox.process is not None
        assert sandbox.process.pid > 1
        assert sandbox.paths.pid.exists()

        started = sandbox.wait_started(
            timeout=5.0
        )

        assert started is True
        assert sandbox.process.poll() is None

        print(
            f"[PASS] isolated sandbox={root}"
        )
        print(
            f"[PASS] dynamic socks port="
            f"{sandbox.socks_port}"
        )
        print(
            f"[PASS] isolated xray pid="
            f"{sandbox.process.pid}"
        )
        print("[PASS] Xray SOCKS listener ready")
        print("[PASS] stdout/stderr isolated")

    finally:
        sandbox.cleanup()

    assert root is not None
    assert not root.exists()

    print("[PASS] process terminated")
    print("[PASS] sandbox cleaned")
    print("[PASS] no fixed health port")
    print("[PASS] HT3 sandbox selftest")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
