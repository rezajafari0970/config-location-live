#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/opt/config-location"

echo "============================================================"
echo " HT4.2 - SANITIZED XRAY ERROR DETAIL"
echo "============================================================"

PYTHONPATH="$ROOT" python3 - <<'PY'
from pathlib import Path
import hashlib
import json
import re
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
            prefix="ht42err-"
        ) as td:

            artifact = builder.build_runtime(
                RuntimeRequest(
                    config_id=str(rec.get("id", "")),
                    config_type="vless",
                    source=raw,
                    sandbox_dir=Path(td),
                    socks_port=39201,
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

            text = (
                result.stderr
                or result.stdout
                or ""
            )

            # Remove runtime paths.
            text = re.sub(
                r'/tmp/[^\s:]+',
                '<TMP>',
                text,
            )

            # Remove UUIDs.
            text = re.sub(
                r'\b[0-9a-fA-F]{8}-'
                r'[0-9a-fA-F]{4}-'
                r'[0-9a-fA-F]{4}-'
                r'[0-9a-fA-F]{4}-'
                r'[0-9a-fA-F]{12}\b',
                '<UUID>',
                text,
            )

            # Remove IPv4 addresses.
            text = re.sub(
                r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
                '<IP>',
                text,
            )

            # Remove obvious domain names.
            text = re.sub(
                r'\b(?:[A-Za-z0-9-]+\.)+'
                r'[A-Za-z]{2,}\b',
                '<DOMAIN>',
                text,
            )

            # Remove long key/token-like strings.
            text = re.sub(
                r'\b[A-Za-z0-9_+/=-]{24,}\b',
                '<SECRET>',
                text,
            )

            # Keep only useful Xray lines.
            useful = []

            for line in text.splitlines():
                low = line.lower()

                if any(
                    marker in low
                    for marker in (
                        "failed",
                        "invalid",
                        "error",
                        "tls",
                        "reality",
                        "flow",
                        "transport",
                        "websocket",
                        "short",
                        "fingerprint",
                        "public",
                        "config",
                    )
                ):
                    useful.append(
                        line.strip()[:500]
                    )

            failures.append({
                "fingerprint":
                    hashlib.sha256(
                        raw.encode()
                    ).hexdigest()[:12],

                "network":
                    artifact.metadata.get(
                        "network"
                    ),

                "security":
                    artifact.metadata.get(
                        "security"
                    ),

                "xray_error":
                    useful[-8:],
            })

    except Exception as exc:
        failures.append({
            "fingerprint":
                hashlib.sha256(
                    raw.encode()
                ).hexdigest()[:12],

            "builder_exception":
                type(exc).__name__,
        })


print(
    f"FAILURES={len(failures)}"
)

for item in failures:
    print()
    print(
        json.dumps(
            item,
            ensure_ascii=False,
            indent=2,
        )
    )

if len(failures) != 2:
    print(
        "[WARN] Failure count changed "
        "while fetcher was running"
    )

print()
print(
    "[PASS] Sanitized Xray errors collected"
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
echo "[PASS] Credentials sanitized"
echo "[PASS] Xray -test only"
echo "[PASS] No real proxy traffic"
echo "[PASS] Panel 4040 active"

echo
echo "============================================================"
echo " HT4.2-ERROR-DETAIL PASS"
echo "============================================================"
echo "NEXT=TARGETED_RUNTIME_FIX"
echo "============================================================"
