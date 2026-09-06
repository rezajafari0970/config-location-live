from __future__ import annotations

import base64
import json
import subprocess
import tempfile

from pathlib import Path


from app.health.plugins.types import (
    RuntimeRequest,
)

from app.health.runtime.builders.uri_xray import (
    UriXrayRuntimeBuilder,
)

from app.health.runtime.builders.xray_json import (
    XrayJsonRuntimeBuilder,
)

from app.health.runtime.xray_capability import (
    classify_xray_capability,
)


XRAY=Path(
    "/usr/local/bin/xray"
)


UUID=(
    "11111111-1111-4111-"
    "8111-111111111111"
)


def validate(path: Path):

    r=subprocess.run(
        [
            str(XRAY),
            "run",
            "-test",
            "-c",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )

    return (
        r.returncode == 0,
        (
            r.stderr
            or r.stdout
            or ""
        )[-1000:],
    )


uris={

    "vless-tcp":
        (
            f"vless://{UUID}@"
            "example.com:443?"
            "encryption=none&"
            "security=none&"
            "type=tcp"
        ),

    "vless-ws":
        (
            f"vless://{UUID}@"
            "example.com:443?"
            "encryption=none&"
            "security=tls&"
            "sni=example.com&"
            "type=ws&"
            "host=example.com&"
            "path=%2Fws"
        ),

    "vless-grpc":
        (
            f"vless://{UUID}@"
            "example.com:443?"
            "encryption=none&"
            "security=tls&"
            "sni=example.com&"
            "type=grpc&"
            "serviceName=grpc"
        ),

    "vless-httpupgrade":
        (
            f"vless://{UUID}@"
            "example.com:443?"
            "encryption=none&"
            "security=tls&"
            "sni=example.com&"
            "type=httpupgrade&"
            "host=example.com&"
            "path=%2Fup"
        ),

    "vless-xhttp":
        (
            f"vless://{UUID}@"
            "example.com:443?"
            "encryption=none&"
            "security=tls&"
            "sni=example.com&"
            "type=xhttp&"
            "host=example.com&"
            "path=%2Fx"
        ),

    "vless-kcp":
        (
            f"vless://{UUID}@"
            "example.com:443?"
            "encryption=none&"
            "security=none&"
            "type=kcp&"
            "seed=test-seed&"
            "headerType=none"
        ),

    "trojan":
        (
            "trojan://password@"
            "example.com:443?"
            "security=tls&"
            "sni=example.com&"
            "type=tcp"
        ),

    "ss":
        (
            "ss://"
            + base64.urlsafe_b64encode(
                b"aes-128-gcm:password"
            ).decode().rstrip("=")
            + "@example.com:8388"
        ),

    "socks":
        (
            "socks://user:pass@"
            "example.com:1080"
        ),
}


types={
    "vless-tcp":"vless",
    "vless-ws":"vless",
    "vless-grpc":"vless",
    "vless-httpupgrade":"vless",
    "vless-xhttp":"vless",
    "vless-kcp":"vless",
    "trojan":"trojan",
    "ss":"ss",
    "socks":"socks",
}


builder=UriXrayRuntimeBuilder()

results={}


with tempfile.TemporaryDirectory(
    prefix="xray-golden-"
) as td:

    root=Path(td)

    port=21000


    for name,raw in uris.items():

        cap=classify_xray_capability(
            types[name],
            raw,
        )

        assert cap.supported, (
            name,
            cap,
        )


        sandbox=root/name

        artifact=builder.build_runtime(
            RuntimeRequest(
                config_id=name,
                config_type=
                    types[name],
                source=raw,
                sandbox_dir=sandbox,
                socks_port=port,
            )
        )

        ok,error=validate(
            artifact.config_path
        )

        results[name]={
            "xray_test":ok,
            "error":error,
            "metadata":
                artifact.metadata,
        }

        if not ok:
            raise AssertionError(
                name
                + ": "
                + error
            )

        port+=1


    xray_json={
        "routing":{
            "rules":[{
                "type":"field",
                "outboundTag":"proxy",
            }],
        },

        "dns":{
            "servers":[
                "1.1.1.1"
            ],
        },

        "outbounds":[
            {
                "protocol":
                    "freedom",
                "tag":
                    "direct",
            },

            {
                "protocol":
                    "vless",
                "tag":"proxy",

                "settings":{
                    "vnext":[{
                        "address":
                            "example.com",

                        "port":443,

                        "users":[{
                            "id":UUID,
                            "encryption":
                                "none",
                        }],
                    }],
                },

                "streamSettings":{
                    "network":"tcp",
                    "security":"none",
                },
            },
        ],
    }


    raw=json.dumps(
        xray_json
    )


    artifact=(
        XrayJsonRuntimeBuilder()
        .build_runtime(
            RuntimeRequest(
                config_id=
                    "json-xray",

                config_type=
                    "json_xray",

                source=raw,

                sandbox_dir=
                    root/"json",

                socks_port=
                    port,
            )
        )
    )


    runtime=json.loads(
        artifact.config_path
        .read_text()
    )


    assert "dns" not in runtime

    assert (
        runtime[
            "outbounds"
        ][0][
            "protocol"
        ]
        ==
        "vless"
    )

    assert (
        runtime[
            "outbounds"
        ][0][
            "tag"
        ]
        ==
        "health-proxy"
    )


    ok,error=validate(
        artifact.config_path
    )

    assert ok,error

    results[
        "json_xray"
    ]={
        "xray_test":ok,
        "error":error,
    }


unsupported=[

    ("hy2",
     "hy2://pass@example.com:443"),

    ("tuic",
     "tuic://uuid:pass@example.com:443"),

    ("anytls",
     "anytls://pass@example.com:443"),
]


for kind,raw in unsupported:

    cap=classify_xray_capability(
        kind,
        raw,
    )

    assert cap.supported is False

    assert (
        cap.status
        ==
        "unsupported_by_xray"
    )


print(
    json.dumps(
        results,
        ensure_ascii=False,
        indent=2,
    )
)

print(
    "[PASS] protocol builders"
)
print(
    "[PASS] transport builders"
)
print(
    "[PASS] Xray validation"
)
print(
    "[PASS] JSON outbound isolation"
)
print(
    "[PASS] unsupported capability gate"
)
