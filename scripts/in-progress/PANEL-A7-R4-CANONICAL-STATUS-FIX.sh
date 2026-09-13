#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

MODEL="$R/app/panel/publish_read_model.py"
UI="$R/app/panel/publish_ui.py"
SERVER="$R/app/panel/server.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/PANEL-A7-R4-$TS"

mkdir -p "$B"

cp -a "$MODEL" "$B/publish_read_model.py.before"
cp -a "$UI" "$B/publish_ui.py.before"
cp -a "$SERVER" "$B/server.py.before"

echo "BACKUP=$B"


echo
echo "=== 1. REPLACE STATUS DISCOVERY WITH CANONICAL FILTER ==="

export MODEL

"$PY" <<'PY'
from pathlib import Path
import os
import re

p=Path(
    os.environ["MODEL"]
)

s=p.read_text()

MARK="PANEL_A7_R4_CANONICAL_STATUS"

if MARK in s:
    print(
        "CANONICAL_STATUS_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


start=s.find(
    "def _discover_publish_status()"
)

end=s.find(
    "\ndef _discover_routes()",
    start,
)

if start<0 or end<0:
    raise SystemExit(
        "ERROR=STATUS_FUNCTION_BOUNDARY_NOT_FOUND"
    )


new=r'''def _discover_publish_status() -> dict[str, Any]:
    """
    PANEL_A7_R4_CANONICAL_STATUS

    This adapter does not create publish semantics.

    Canonical authority:
      app.publish.filter.build_publish_snapshot
      app.publish.filter.publishable_config_ids
      health-lifecycle/policy-latest.json

    Allowed states remain exactly:
      healthy
      recovered
    """

    try:

        from app.publish.filter import (
            ALLOWED_STATES,
            POLICY_PATH,
            _policy_index,
            _read_json,
            build_publish_snapshot,
            publishable_config_ids,
        )

    except Exception as exc:

        return {
            "_source":
                "app.publish.filter",

            "available":
                False,

            "error":
                type(exc).__name__,

            "message":
                str(exc),
        }


    try:

        # config_type is keyword-only but optional;
        # zero-argument invocation is canonical.
        snapshot=build_publish_snapshot()

    except Exception as exc:

        return {
            "_source":
                "app.publish.filter.build_publish_snapshot",

            "available":
                False,

            "error":
                type(exc).__name__,

            "message":
                str(exc),
        }


    healthy=0
    recovered=0

    eligible_by_state={}


    try:

        policy=_read_json(
            POLICY_PATH
        )

        index=(
            _policy_index(policy)
            if policy
            else {}
        )


        for item in index.values():

            if not isinstance(
                item,
                dict,
            ):
                continue


            state=str(
                item.get(
                    "policy_state",
                    "",
                )
            ).strip().lower()


            eligible=bool(
                item.get(
                    "publish_eligible",
                    False,
                )
            )


            if (
                state not in ALLOWED_STATES
                or not eligible
            ):
                continue


            eligible_by_state[
                state
            ]=(
                eligible_by_state.get(
                    state,
                    0,
                )
                +1
            )


        healthy=int(
            eligible_by_state.get(
                "healthy",
                0,
            )
        )

        recovered=int(
            eligible_by_state.get(
                "recovered",
                0,
            )
        )

    except Exception:

        # Total publishability still comes from
        # canonical PublishSnapshot even if the
        # optional state breakdown cannot be read.
        eligible_by_state={}


    try:

        canonical_ids=len(
            publishable_config_ids()
        )

    except Exception:

        canonical_ids=None


    return {
        "_source":
            "app.publish.filter.build_publish_snapshot",

        "available":
            True,

        "mode":
            "production-output-filter",

        "policy_available":
            bool(
                snapshot.policy_available
            ),

        "total_configs":
            int(
                snapshot.total_configs
            ),

        "policy_tracked":
            int(
                snapshot.policy_tracked
            ),

        "publishable":
            int(
                snapshot.publishable
            ),

        "suppressed":
            int(
                snapshot.suppressed
            ),

        "missing_policy_record":
            int(
                snapshot.missing_policy_record
            ),

        "healthy":
            healthy,

        "recovered":
            recovered,

        "eligible_by_state":
            eligible_by_state,

        "allowed_states":
            sorted(
                str(x)
                for x in ALLOWED_STATES
            ),

        "publishable_id_count":
            canonical_ids,

        "production_delete":
            False,
    }


'''

s=(
    s[:start]
    +new
    +s[end+1:]
)

p.write_text(s)

print(
    "CANONICAL_STATUS_PATCH=PASS"
)
PY


echo
echo "=== 2. COMPILE ==="

"$PY" -m py_compile \
"$MODEL" \
"$UI" \
"$SERVER"

echo "COMPILE=PASS"


echo
echo "=== 3. ROOT CANONICAL SNAPSHOT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.publish.filter import (
    build_publish_snapshot,
    publishable_config_ids,
)

snap=build_publish_snapshot()

ids=publishable_config_ids()

print(
    "POLICY_AVAILABLE=",
    snap.policy_available,
)

print(
    "TOTAL_CONFIGS=",
    snap.total_configs,
)

print(
    "POLICY_TRACKED=",
    snap.policy_tracked,
)

print(
    "PUBLISHABLE=",
    snap.publishable,
)

print(
    "SUPPRESSED=",
    snap.suppressed,
)

print(
    "MISSING_POLICY_RECORD=",
    snap.missing_policy_record,
)

print(
    "PUBLISHABLE_IDS=",
    len(ids),
)

assert (
    snap.publishable
    ==
    len(ids)
)

print(
    "CANONICAL_ROOT=PASS"
)
PY


echo
echo "=== 4. PANEL MODEL AS REAL USER ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
from app.panel.publish_read_model import (
    publish_summary,
)

from app.publish.filter import (
    build_publish_snapshot,
    publishable_config_ids,
)

result=publish_summary()

status=result[
    "publish_status"
]

canonical=build_publish_snapshot()

ids=publishable_config_ids()


print(
    "STATUS=",
    status,
)

print(
    "ROUTES=",
    result["routes"],
)

print(
    "LINKS=",
    result["links"],
)


assert status[
    "available"
] is True

assert status[
    "policy_available"
] == canonical.policy_available

assert status[
    "total_configs"
] == canonical.total_configs

assert status[
    "policy_tracked"
] == canonical.policy_tracked

assert status[
    "publishable"
] == canonical.publishable

assert status[
    "suppressed"
] == canonical.suppressed

assert status[
    "missing_policy_record"
] == canonical.missing_policy_record

assert status[
    "publishable_id_count"
] == len(ids)

assert status[
    "publishable"
] == len(ids)


state_total=(
    int(
        status.get(
            "healthy",
            0,
        )
    )
    +
    int(
        status.get(
            "recovered",
            0,
        )
    )
)

print(
    "ELIGIBLE_STATE_TOTAL=",
    state_total,
)

print(
    "CANONICAL_PUBLISHABLE=",
    status["publishable"],
)

assert (
    state_total
    ==
    status["publishable"]
)


assert "/sub/all" in result[
    "routes"
]

assert "/sub/{config_type}" in result[
    "routes"
]


print(
    "CONFIGLOC_CANONICAL_STATUS=PASS"
)
PY


echo
echo "=== 5. TYPE SNAPSHOT CONTRACT ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
from app.publish.filter import (
    build_publish_snapshot,
)

types=[
    "vless",
    "vmess",
    "trojan",
    "ss",
    "wireguard",
    "json_xray",
]

total=0

for kind in types:

    snap=build_publish_snapshot(
        config_type=kind
    )

    print(
        "TYPE=",
        kind,
        "TOTAL=",
        snap.total_configs,
        "PUBLISHABLE=",
        snap.publishable,
        "SUPPRESSED=",
        snap.suppressed,
    )

    assert (
        snap.publishable
        >=0
    )

    assert (
        snap.publishable
        <=snap.total_configs
    )

    total+=snap.publishable


print(
    "KNOWN_TYPE_PUBLISHABLE_TOTAL=",
    total,
)

print(
    "TYPE_SNAPSHOTS=PASS"
)
PY


echo
echo "=== 6. ROUTE CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import (
    create_app,
)

app=create_app()

routes=set()

for route in app.router.routes():

    try:
        path=route.resource.canonical
    except Exception:
        continue

    routes.add(
        (
            route.method,
            path,
        )
    )


required={
    (
        "GET",
        "/publish",
    ),
    (
        "GET",
        "/api/publish/summary",
    ),
    (
        "GET",
        "/api/publish/status",
    ),
    (
        "GET",
        "/sub/all",
    ),
    (
        "GET",
        "/sub/{config_type}",
    ),
}


missing=(
    required
    -routes
)

print(
    "MISSING=",
    missing,
)

assert not missing

print(
    "PUBLISH_ROUTES=PASS"
)
PY


echo
echo "=== 7. RESTART PANEL ONLY ==="

systemctl restart \
config-location-panel.service

sleep 4

PANEL_STATE=$(
    systemctl is-active \
    config-location-panel.service
)

echo "PANEL=$PANEL_STATE"

test "$PANEL_STATE" = active

echo "PANEL_RESTART=PASS"


echo
echo "=== 8. AUTHENTICATED LIVE A7 API ==="

"$PY" <<'PY'
import http.client
import json
import urllib.parse
from pathlib import Path


env={}

for line in Path(
    "/etc/config-location/panel.env"
).read_text().splitlines():

    line=line.strip()

    if (
        not line
        or line.startswith("#")
        or "=" not in line
    ):
        continue

    key,value=line.split(
        "=",
        1,
    )

    env[key.strip()]=(
        value.strip()
        .strip('"')
        .strip("'")
    )


body=urllib.parse.urlencode(
    {
        "username":
            env[
                "CONFIGLOC_ADMIN_USER"
            ],

        "password":
            env[
                "CONFIGLOC_ADMIN_PASSWORD"
            ],
    }
)


conn=http.client.HTTPConnection(
    "127.0.0.1",
    4040,
    timeout=20,
)

conn.request(
    "POST",
    "/login",
    body=body,
    headers={
        "Content-Type":
            "application/x-www-form-urlencoded",
    },
)

r=conn.getresponse()

headers=r.getheaders()

r.read()
conn.close()


cookie=None

for key,value in headers:

    if key.lower()=="set-cookie":

        cookie=value.split(
            ";",
            1,
        )[0]

        break


assert cookie


def get_json(path):

    conn=http.client.HTTPConnection(
        "127.0.0.1",
        4040,
        timeout=60,
    )

    conn.request(
        "GET",
        path,
        headers={
            "Cookie":
                cookie,

            "Accept":
                "application/json",

            "Cache-Control":
                "no-cache",
        },
    )

    response=conn.getresponse()

    raw=response.read().decode(
        "utf-8",
        errors="replace",
    )

    status=response.status

    conn.close()

    print()
    print(
        "PATH=",
        path,
    )

    print(
        "STATUS=",
        status,
    )

    print(
        "BODY=",
        raw[:5000],
    )

    assert status==200

    return json.loads(raw)


panel=get_json(
    "/api/publish/summary"
)

canonical=get_json(
    "/api/publish/status"
)


status=panel[
    "publish_status"
]


print()
print(
    "PANEL_PUBLISHABLE=",
    status["publishable"],
)

print(
    "CANONICAL_PUBLISHABLE=",
    canonical["publishable"],
)

print(
    "HEALTHY=",
    status["healthy"],
)

print(
    "RECOVERED=",
    status["recovered"],
)


assert status[
    "policy_available"
] == canonical[
    "policy_available"
]

assert status[
    "total_configs"
] == canonical[
    "total_configs"
]

assert status[
    "policy_tracked"
] == canonical[
    "policy_tracked"
]

assert status[
    "publishable"
] == canonical[
    "publishable"
]

assert status[
    "suppressed"
] == canonical[
    "suppressed"
]

assert status[
    "missing_policy_record"
] == canonical[
    "missing_policy_record"
]


assert (
    status["healthy"]
    +status["recovered"]
    ==
    status["publishable"]
)


print(
    "LIVE_CANONICAL_HTTP_MATCH=PASS"
)
PY


echo
echo "=== 9. SUBSCRIPTION CONTENT SMOKE ==="

"$PY" <<'PY'
import http.client

paths=[
    "/sub/all",
    "/sub/vless",
    "/sub/vmess",
    "/sub/trojan",
    "/sub/ss",
    "/sub/wireguard",
    "/sub/json_xray",
]

for path in paths:

    conn=http.client.HTTPConnection(
        "127.0.0.1",
        4040,
        timeout=60,
    )

    conn.request(
        "GET",
        path,
    )

    response=conn.getresponse()

    body=response.read()

    status=response.status

    content_type=response.getheader(
        "Content-Type"
    )

    conn.close()


    print(
        "PATH=",
        path,
        "STATUS=",
        status,
        "BYTES=",
        len(body),
        "CONTENT_TYPE=",
        content_type,
    )

    assert status==200


print(
    "SUBSCRIPTIONS_HTTP=PASS"
)
PY


echo
echo "=== 10. CORE SERVICES ==="

for S in \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$S" 2>/dev/null || true
    )

    echo "$S=$X"

    test "$X" = active
done

echo "CORE_SERVICES=PASS"


echo
echo "=== 11. PANEL JOURNAL ==="

J=$(
    journalctl \
    -u config-location-panel.service \
    --since "5 minutes ago" \
    --no-pager \
    2>&1 || true
)

printf '%s\n' "$J" \
| tail -n 100


if printf '%s\n' "$J" \
| grep -Ei \
'Traceback|SyntaxError|ImportError|ModuleNotFoundError'
then

    echo "ERROR=PANEL_RUNTIME_EXCEPTION"
    exit 1
fi


echo "PANEL_RUNTIME=PASS"


echo
echo "======================================================"
echo "PANEL_A7_R4=PASS"
echo "CANONICAL_FILTER=app.publish.filter.build_publish_snapshot"
echo "PUBLISH_STATUS=REAL"
echo "HEALTHY_COUNT=REAL"
echo "RECOVERED_COUNT=REAL"
echo "PUBLISHABLE_COUNT=REAL"
echo "SUB_ALL=CANONICAL"
echo "TYPE_SUBSCRIPTIONS=CANONICAL"
echo "PRODUCTION_DELETE=NO"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A8"
echo "======================================================"
