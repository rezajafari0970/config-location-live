from __future__ import annotations

import dataclasses
import hashlib
import importlib
import inspect
import json
import sys

from pathlib import Path
from typing import Any


def normalize(
    value: Any,
) -> Any:

    if dataclasses.is_dataclass(
        value
    ):

        return normalize(
            dataclasses.asdict(
                value
            )
        )


    if isinstance(
        value,
        Path
    ):

        return str(value)


    if isinstance(
        value,
        bytes
    ):

        return {
            "__bytes_hex__":
                value.hex()
        }


    if isinstance(
        value,
        dict
    ):

        return {
            str(k):
                normalize(v)
            for k,v
            in value.items()
        }


    if isinstance(
        value,
        (
            list,
            tuple,
        )
    ):

        return [
            normalize(x)
            for x in value
        ]


    if isinstance(
        value,
        set
    ):

        normalized=[
            normalize(x)
            for x in value
        ]

        return sorted(
            normalized,
            key=lambda x:
                json.dumps(
                    x,
                    ensure_ascii=False,
                    sort_keys=True,
                    default=str,
                )
        )


    if isinstance(
        value,
        (
            str,
            int,
            float,
            bool,
        )
    ) or value is None:

        return value


    if hasattr(
        value,
        "__dict__"
    ):

        return normalize(
            vars(value)
        )


    return {
        "__type__":
            type(value).__name__,

        "__repr__":
            repr(value),
    }


def call_extract(
    fn,
    text: str,
):

    sig=inspect.signature(fn)

    required=[
        p
        for p in sig.parameters.values()
        if (
            p.default
            is inspect.Parameter.empty
            and
            p.kind
            in (
                inspect.Parameter.POSITIONAL_ONLY,
                inspect.Parameter.POSITIONAL_OR_KEYWORD,
            )
        )
    ]


    if len(required) > 1:

        raise RuntimeError(
            "extract_configs has unsupported "
            f"required signature: {sig}"
        )


    return fn(text)


def sha256_text(
    text: str,
) -> str:

    return hashlib.sha256(
        text.encode("utf-8")
    ).hexdigest()


def main():

    root=Path(sys.argv[1])
    module_name=sys.argv[2]
    fixture_dir=Path(sys.argv[3])
    output=Path(sys.argv[4])

    sys.path.insert(
        0,
        str(root)
    )

    m=importlib.import_module(
        module_name
    )

    fn=getattr(
        m,
        "extract_configs"
    )


    results={}


    for path in sorted(
        fixture_dir.iterdir()
    ):

        if not path.is_file():
            continue


        text=path.read_text(
            encoding="utf-8"
        )


        try:

            raw=call_extract(
                fn,
                text
            )

            normalized=normalize(
                raw
            )

            results[path.name]={
                "input_sha256":
                    sha256_text(
                        text
                    ),

                "status":
                    "ok",

                "output":
                    normalized,
            }


        except Exception as exc:

            results[path.name]={
                "input_sha256":
                    sha256_text(
                        text
                    ),

                "status":
                    "exception",

                "exception_type":
                    type(exc).__name__,

                "exception_message":
                    str(exc),
            }


    detector_file=Path(
        inspect.getsourcefile(m)
    )


    detector_sha=hashlib.sha256(
        detector_file.read_bytes()
    ).hexdigest()


    obj={
        "schema_version":1,

        "module":
            module_name,

        "detector_file":
            str(detector_file),

        "detector_sha256":
            detector_sha,

        "extract_signature":
            str(
                inspect.signature(
                    fn
                )
            ),

        "fixtures":
            results,
    }


    output.write_text(
        json.dumps(
            obj,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )+"\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
