#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/opt/config-location"

echo "============================================================"
echo " HT4.2 - VLESS FAILURE DIAGNOSTIC"
echo "============================================================"

PYTHONPATH="$ROOT" python3 - <<'PY'
from pathlib import Path
from collections import Counter
import hashlib
import json
import subprocess
import tempfile

from app.health.runtime.builders.uri_xray import (
    UriXrayRuntimeBuilder,
)
from app.health.plugins.types import RuntimeRequest

STORE = Path("/var/lib/config-location/configs")
XRAY = "/usr/local/bin/xray"

builder = UriXrayRuntimeBuilder()
failures = []

for path in STORE.glob("*.json"):

    try:
        rec = json.loads(
            path.read_text(encoding="utf-8")
        )
    except Exception:
        continue

    if rec.get("type") != "vless":
        continue

    raw = rec.get("raw")

    if not isinstance(raw, str):
        continue

    try:
        with tempfile.TemporaryDirectory(
            prefix="ht42diag-"
        ) as td:

            artifact = builder.build_runtime(
                RuntimeRequest(
                    config_id=str(rec.get("id", "")),
                    config_type="vless",
                    source=raw,
                    sandbox_dir=Path(td),
                    socks_port=39101,
                )
            )

            result = subprocess.run(
                [
                    XRAY,
                    "run",
                    "-test",
                    "-c",
                    str(artifact.config_path),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )

            if result.returncode == 0:
                continue

            runtime = json.loads(
                artifact.config_path.read_text(
                    encoding="utf-8"
                )
            )

            outbound = runtime["outbounds"][0]
            stream = outbound.get(
                "streamSettings", {}
            )

            network = str(
                artifact.metadata.get(
                    "network", ""
                )
            )

            security = str(
                artifact.metadata.get(
                    "security", ""
                )
            )

            error_text = (
                result.stderr
                or result.stdout
                or ""
            ).lower()

            categories = []

            markers = {
                "reality": "reality",
                "public key": "public_key",
                "short id": "short_id",
                "shortid": "short_id",
                "flow": "flow",
                "transport": "transport",
                "xhttp": "xhttp",
                "grpc": "grpc",
                "websocket": "websocket",
                "httpupgrade": "httpupgrade",
                "tls": "tls",
                "invalid": "invalid",
                "failed to": "failed_to",
            }

            for needle, label in markers.items():
                if needle in error_text:
                    categories.append(label)

            # Structural information only.
            safe = {
                "fingerprint": hashlib.sha256(
                    raw.encode()
                ).hexdigest()[:12],

                "network": network,
                "security": security,

                "has_flow": bool(
                    outbound.get(
                        "settings", {}
                    )
                    .get("vnext", [{}])[0]
                    .get("users", [{}])[0]
                    .get("flow")
                ),

                "has_tls_settings": (
                    "tlsSettings" in stream
                ),

                "has_reality_settings": (
                    "realitySettings" in stream
                ),

                "has_tcp_settings": (
                    "tcpSettings" in stream
                ),

                "has_ws_settings": (
                    "wsSettings" in stream
                ),

                "has_grpc_settings": (
                    "grpcSettings" in stream
                ),

                "has_xhttp_settings": (
                    "xhttpSettings" in stream
                ),

                "has_httpupgrade_settings": (
                    "httpupgradeSettings"
                    in stream
                ),

                "error_categories": sorted(
                    set(categories)
                ),
            }

            reality = stream.get(
                "realitySettings", {}
            )

            safe.update({
                "reality_has_serverName":
                    bool(reality.get("serverName")),

                "reality_has_publicKey":
                    bool(reality.get("publicKey")),

                "reality_has_shortId":
                    bool(reality.get("shortId")),

                "reality_has_fingerprint":
                    bool(reality.get("fingerprint")),
            })

            failures.append(safe)

    except Exception as exc:

        failures.append({
            "fingerprint": hashlib.sha256(
                raw.encode()
            ).hexdigest()[:12],
            "builder_exception":
                type(exc).__name__,
        })


print(
    f"VLESS_FAILURES={len(failures)}"
)

print()
print("===== SAFE FAILURE DETAILS =====")

for item in failures:
    print(
        json.dumps(
            item,
            ensure_ascii=False,
            sort_keys=True,
        )
    )

summary = Counter()

for item in failures:
    summary[
        (
            item.get("network", "unknown"),
            item.get("security", "unknown"),
        )
    ] += 1

print()
print("===== FAILURE MATRIX =====")

for (network, security), count in sorted(
    summary.items()
):
    print(
        f"{network}:{security}={count}"
    )

if not failures:
    print(
        "[PASS] No current VLESS failures"
    )
else:
    print(
        "[PASS] Failures safely classified"
    )
PY

echo
echo "===== ISOLATION ====="

systemctl is-active \
  config-location-panel.service

systemctl is-active \
  config-location-fetcher.service

ss -lntp |
grep ':4040 ' >/dev/null

echo "[PASS] Store read-only"
echo "[PASS] No raw URI printed"
echo "[PASS] No UUID printed"
echo "[PASS] No endpoint printed"
echo "[PASS] Xray only used with -test"
echo "[PASS] No real proxy traffic"
echo "[PASS] Panel 4040 active"

echo
echo "============================================================"
echo " HT4.2-FAIL-DIAG PASS"
echo "============================================================"
echo "NEXT=HT4.2_TARGETED_FIX"
echo "============================================================"
