#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
SERVER="$R/app/panel/server.py"

echo "=== 1. SERVER AROUND PUBLISH STATUS REFERENCE ==="

nl -ba "$SERVER" \
| sed -n '240,340p'


echo
echo "=== 2. ALL PUBLISH REFERENCES ==="

grep -RIn \
--include='*.py' \
-E \
'publish/status|publish_status|publishable|eligible_count|eligible_healthy|recovered_count|healthy_count|/sub/all|def .*publish|class .*Publish' \
"$R/app" \
| head -n 1000


echo
echo "=== 3. PUBLISH MODULE INVENTORY ==="

find "$R/app" \
-type f \
\( \
-name '*publish*.py' \
-o -path '*/publish/*' \
\) \
-print \
| sort


echo
echo "=== 4. SERVER FUNCTIONS NEAR PUBLISH ==="

PYTHONPATH="$R" "$PY" <<'PY'
import ast
from pathlib import Path

p=Path(
    "/opt/config-location/app/panel/server.py"
)

src=p.read_text()
tree=ast.parse(src)

for node in tree.body:

    if not isinstance(
        node,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):
        continue

    name=node.name.lower()

    if (
        "publish" in name
        or "sub" in name
    ):

        print(
            f"{node.lineno}: {node.name}"
        )
PY


echo
echo "=== 5. ROUTE REGISTRATION CONTEXT ==="

grep -n \
'/api/publish/status' \
"$SERVER" \
|| true

LINE=$(
    grep -n \
    '/api/publish/status' \
    "$SERVER" \
    | head -n1 \
    | cut -d: -f1 \
    || true
)

if [ -n "$LINE" ]; then

    START=$((LINE-40))

    if [ "$START" -lt 1 ]; then
        START=1
    fi

    END=$((LINE+60))

    nl -ba "$SERVER" \
    | sed -n "${START},${END}p"
fi


echo
echo "=== 6. CANONICAL SUB HANDLERS ==="

grep -nE \
'async def .*sub|def .*sub|/sub/all|/sub/\{config_type\}' \
"$SERVER" \
| head -n 300


echo
echo "=== 7. IMPORT GRAPH FOR PUBLISH ==="

grep -nE \
'^from .*publish|^import .*publish|eligib|lifecycle.*publish|publish.*lifecycle' \
"$SERVER" \
| head -n 300


echo
echo "=== 8. EXISTING STATUS API BEHAVIOR ==="

PYTHONPATH="$R" "$PY" <<'PY'
import asyncio

from aiohttp.test_utils import (
    make_mocked_request,
)

import app.panel.server as server


async def main():

    candidates=[]

    for name in dir(server):

        if "publish" not in name.lower():
            continue

        obj=getattr(
            server,
            name,
        )

        if callable(obj):
            candidates.append(
                name
            )

    print(
        "CALLABLES=",
        candidates,
    )


asyncio.run(main())
PY


echo
echo "=== 9. FILES CONTAINING ELIGIBILITY ==="

grep -RIl \
--include='*.py' \
-E \
'publishable|eligible_for_publish|publish_eligible|is_publishable|healthy.*recovered|recovered.*healthy' \
"$R/app" \
| sort


echo
echo "=== 10. CURRENT PUBLISH READ MODEL ==="

nl -ba \
"$R/app/panel/publish_read_model.py" \
| sed -n '1,360p'


echo
echo "======================================================"
echo "PANEL_A7_R2_DIAG=PASS"
echo "PRODUCTION_MUTATION=NO"
echo "PANEL_RESTART=NO"
echo "NEXT=PATCH_REAL_CANONICAL_PUBLISH_STATUS"
echo "======================================================"
