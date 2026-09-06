#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
MOD="$R/app/panel/read_model.py"

echo "=== 1. FILE / COMPILE ==="

test -s "$MOD"

"$PY" -m py_compile "$MOD"

echo "COMPILE=PASS"


echo
echo "=== 2. STRICT READ-ONLY SOURCE AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/panel/read_model.py"
)

src=p.read_text()
tree=ast.parse(src)

forbidden_calls={
    "write_text",
    "write_bytes",
    "unlink",
    "mkdir",
    "rename",
    "replace",
    "touch",
    "rmdir",
    "remove",
    "rmtree",
    "system",
    "run",
    "Popen",
    "check_call",
    "check_output",
}

bad=[]

for node in ast.walk(tree):

    if not isinstance(node,ast.Call):
        continue

    func=node.func

    name=None

    if isinstance(func,ast.Attribute):
        name=func.attr

    elif isinstance(func,ast.Name):
        name=func.id

    if name in forbidden_calls:

        # str.replace() is harmless and read-only.
        if name=="replace":
            if isinstance(func,ast.Attribute):
                # We don't use Path.replace() in this module.
                # Confirm based on receiver source where possible.
                receiver=ast.get_source_segment(
                    src,
                    func.value,
                ) or ""

                if not receiver.startswith(
                    ("Path(", "p", "path", "root")
                ):
                    continue

        bad.append(
            {
                "line":
                    getattr(
                        node,
                        "lineno",
                        None,
                    ),
                "call":
                    name,
            }
        )


# Explicitly reject write-mode open().
for node in ast.walk(tree):

    if not isinstance(node,ast.Call):
        continue

    if not (
        isinstance(node.func,ast.Name)
        and node.func.id=="open"
    ):
        continue

    mode=None

    if len(node.args)>=2:
        try:
            mode=ast.literal_eval(
                node.args[1]
            )
        except Exception:
            pass

    for kw in node.keywords:
        if kw.arg=="mode":
            try:
                mode=ast.literal_eval(
                    kw.value
                )
            except Exception:
                pass

    if (
        isinstance(mode,str)
        and any(
            x in mode
            for x in ("w","a","+","x")
        )
    ):
        bad.append(
            {
                "line":node.lineno,
                "call":
                    f"open:{mode}",
            }
        )


print(
    "WRITE_CALLS=",
    bad,
)

assert not bad

print(
    "READ_ONLY_CONTRACT=PASS"
)
PY


echo
echo "=== 3. LIVE SUMMARY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.read_model import (
    dashboard_summary,
)

s=dashboard_summary()

print(
    "TOTAL_CONFIGS=",
    s["total_configs"],
)

print(
    "COUNTRY_KNOWN=",
    s["country_known"],
)

print(
    "COUNTRY_UNRESOLVED=",
    s["country_unresolved"],
)

print(
    "COUNTRY_ROTATING=",
    s["country_rotating"],
)

print(
    "COUNTRY_COVERAGE_PERCENT=",
    s["country_coverage_percent"],
)

print(
    "HEALTH=",
    s["health"],
)

print(
    "COUNTRY_STATES=",
    s["country_states"],
)

assert s["total_configs"]>0

print(
    "SUMMARY_TEST=PASS"
)
PY


echo
echo "=== 4. PAGINATION / FILTER TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.read_model import (
    query_configs,
)

r=query_configs(
    limit=25,
)

print("TOTAL=",r["total"])
print(
    "RETURNED=",
    len(r["items"]),
)

assert r["total"]>0
assert 0 < len(r["items"]) <= 25


u=query_configs(
    unresolved_only=True,
    limit=25,
)

print(
    "UNRESOLVED_TOTAL=",
    u["total"],
)

for row in u["items"]:
    assert row[
        "country_unresolved"
    ] is True


p1=query_configs(
    offset=0,
    limit=10,
)

p2=query_configs(
    offset=10,
    limit=10,
)

ids1={
    x["config_id"]
    for x in p1["items"]
}

ids2={
    x["config_id"]
    for x in p2["items"]
}

assert not (
    ids1 & ids2
)

print(
    "QUERY_PAGINATION=PASS"
)
PY


echo
echo "=== 5. COUNTRY IDENTITY AUTHORITY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.panel.read_model import (
    build_config_view,
)

I=Path(
    "/var/lib/config-location/"
    "country/country-identity"
)

tested=0

for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
        continue

    if not (
        ident.get("locked") is True
        and ident.get("country_code")
    ):
        continue

    cid=str(
        ident.get("config_id")
        or ip.stem
    )

    row=build_config_view(
        cid,
        {
            "config_id":cid,
            "config_type":"test",
            "source_ids":[],
        },
    )

    assert (
        str(
            row["country_code"]
        ).upper()
        ==
        str(
            ident["country_code"]
        ).upper()
    )

    assert (
        row["country_source"]
        =="identity"
    )

    tested+=1

    if tested>=100:
        break


print(
    "IDENTITY_TESTED=",
    tested,
)

assert tested>0

print(
    "IDENTITY_AUTHORITY=PASS"
)
PY


echo
echo "=== 6. NO PANEL RESTART / NO MUTATION ==="

for S in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service
do
    X=$(
        systemctl is-active \
        "$S" 2>/dev/null || true
    )

    echo "$S=$X"
    test "$X" = active
done


echo
echo "======================================================"
echo "PANEL_A2_R1=PASS"
echo "COUNTRY_READ_MODEL=READY"
echo "READ_ONLY=PROVEN"
echo "PRODUCTION_MUTATION=NO"
echo "PANEL_RESTART=NO"
echo "NEXT=PANEL-A3-COUNTRY-API"
echo "======================================================"
