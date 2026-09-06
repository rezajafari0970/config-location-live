#!/opt/config-location/venv/bin/python

import json
import sys

sys.path.insert(
    0,
    "/opt/config-location"
)

from app.parser.detector import extract_configs


samples = [
    (
        "bad text",
        "hello world"
    ),

    (
        "vless",
        "vless://12345678-1234-1234-1234-123456789012@example.com:443?security=tls&type=ws#test"
    ),

    (
        "trojan",
        "trojan://password@example.com:443?security=tls#test"
    ),

    (
        "hysteria2",
        "hy2://password@example.com:443?sni=example.com#test"
    ),

    (
        "custom",
        "mycustom://abc123@example-data"
    ),
]


failed = False

for name, raw in samples:

    result = extract_configs(
        raw
    )

    print()
    print(
        f"=== {name} ==="
    )

    print(
        json.dumps(
            result,
            ensure_ascii=False,
            indent=2,
        )
    )

    if (
        name == "bad text"
        and result
    ):
        failed = True

    if (
        name != "bad text"
        and not result
    ):
        failed = True


if failed:
    raise SystemExit(
        "DETECTOR TEST FAILED"
    )

print()
print(
    "DETECTOR TEST PASSED"
)
