from __future__ import annotations

import json
import sys
from pathlib import Path

from app.parser.detector import (
    extract_configs,
)

from app.parser.universal_json import (
    analyze_json,
)


fixtures=Path(sys.argv[1])
output=Path(sys.argv[2])

result={}

for p in sorted(
    fixtures.iterdir()
):
    if not p.is_file():
        continue

    text=p.read_text(
        encoding="utf-8"
    )

    a=analyze_json(text)

    parsed=extract_configs(text)

    result[p.name]={
        "decoded":
            a.decoded,

        "schema":
            a.schema,

        "json_documents":
            a.json_documents,

        "uri_count":
            len(a.uris),

        "uris":
            a.uris,

        "protocols":[
            x.protocol
            for x in a.outbounds
        ],

        "selected":[
            {
                "protocol":x.protocol,
                "tag":x.tag,
                "selected":x.selected,
            }
            for x in a.outbounds
        ],

        "unknown_protocols":
            a.unknown_protocols,

        "warnings":
            a.warnings,

        "detector_output_count":
            (
                len(parsed)
                if isinstance(parsed,(list,tuple))
                else 1
            ),
    }

output.write_text(
    json.dumps(
        result,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )+"\n",
    encoding="utf-8",
)
