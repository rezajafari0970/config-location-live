from __future__ import annotations

import json
import tempfile

from pathlib import Path

import app.publish.filter as f


def main() -> int:

    with tempfile.TemporaryDirectory(
        prefix="ht18.3-"
    ) as td:

        root = Path(td)

        config_dir = (
            root / "configs"
        )

        config_dir.mkdir()

        policy = (
            root / "policy.json"
        )


        records = {
            "a": {
                "id": "a",
                "type": "vless",
                "raw":
                    "vless://a@example.com:443",
            },

            "b": {
                "id": "b",
                "type": "vless",
                "raw":
                    "vless://b@example.com:443",
            },

            "c": {
                "id": "c",
                "type": "vmess",
                "raw":
                    "vmess://example",
            },

            "d": {
                "id": "d",
                "type": "trojan",
                "raw":
                    "trojan://example",
            },
        }


        for cid, value in (
            records.items()
        ):

            (
                config_dir
                / f"{cid}.json"
            ).write_text(
                json.dumps(
                    value
                ),
                encoding="utf-8",
            )


        policy.write_text(
            json.dumps({
                "decisions": [
                    {
                        "config_id": "a",
                        "policy_state":
                            "healthy",
                        "publish_eligible":
                            True,
                    },

                    {
                        "config_id": "b",
                        "policy_state":
                            "quarantine",
                        "publish_eligible":
                            False,
                    },

                    {
                        "config_id": "c",
                        "policy_state":
                            "recovered",
                        "publish_eligible":
                            True,
                    },
                ]
            }),
            encoding="utf-8",
        )


        original_configs = (
            f.CONFIG_DIR
        )

        original_policy = (
            f.POLICY_PATH
        )


        try:

            f.CONFIG_DIR = (
                config_dir
            )

            f.POLICY_PATH = (
                policy
            )


            snap = (
                f.build_publish_snapshot()
            )


            ids = {
                item["id"]
                for item
                in snap.configs
            }


            assert ids == {
                "a",
                "c",
            }


            assert (
                snap.publishable
                == 2
            )


            assert (
                snap.missing_policy_record
                == 1
            )


            vless = (
                f.build_publish_snapshot(
                    config_type="vless"
                )
            )


            assert [
                x["id"]
                for x
                in vless.configs
            ] == [
                "a"
            ]


            # Invalid/missing policy must fail closed.
            f.POLICY_PATH = (
                root
                / "missing.json"
            )


            closed = (
                f.build_publish_snapshot()
            )


            assert (
                closed.publishable
                == 0
            )


            assert (
                closed.policy_available
                is False
            )


        finally:

            f.CONFIG_DIR = (
                original_configs
            )

            f.POLICY_PATH = (
                original_policy
            )


    print(
        "[PASS] healthy published"
    )

    print(
        "[PASS] recovered published"
    )

    print(
        "[PASS] quarantine suppressed"
    )

    print(
        "[PASS] missing policy record suppressed"
    )

    print(
        "[PASS] type filter"
    )

    print(
        "[PASS] policy failure -> fail closed"
    )

    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
