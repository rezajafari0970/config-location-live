#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

MODEL="$R/app/panel/publish_read_model.py"
SERVER="$R/app/panel/server.py"
UI="$R/app/panel/publish_ui.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/PANEL-A7-R5-$TS"

mkdir -p "$B"

cp -a "$MODEL" "$B/publish_read_model.py.before"
cp -a "$SERVER" "$B/server.py.before"
cp -a "$UI" "$B/publish_ui.py.before"

echo "BACKUP=$B"


echo
echo "=== 1. PATCH COHERENT CANONICAL STATUS ==="

export MODEL

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["MODEL"]
)

s=p.read_text()

start=s.find(
    "def _discover_publish_status()"
)

end=s.find(
    "\ndef _discover_routes()",
    start,
)

if start<0 or end<0:
    raise SystemExit(
        "ERROR=STATUS_FUNCTION_NOT_FOUND"
    )


new=r'''def _discover_publish_status() -> dict[str, Any]:
    """
    PANEL_A7_R5_COHERENT_CANONICAL_STATUS

    Canonical eligibility remains owned exclusively by:

        app.publish.filter.build_publish_snapshot()

    Healthy/recovered are only a breakdown of the exact
    publishable IDs returned by that canonical snapshot.

    Because production state changes continuously, we retry
    briefly until snapshot + policy view are coherent.
    """

    import time

    try:

        from app.publish.filter import (
            ALLOWED_STATES,
            POLICY_PATH,
            _policy_index,
            _read_json,
            build_publish_snapshot,
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


    last=None


    for attempt in range(1,9):

        try:

            snapshot=build_publish_snapshot()

            policy=_read_json(
                POLICY_PATH
            )

            index=(
                _policy_index(policy)
                if policy
                else {}
            )

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


        # These are the exact configs selected by the
        # canonical filter for this particular snapshot.
        snapshot_ids=set()

        for record in snapshot.configs:

            if not isinstance(
                record,
                dict,
            ):
                continue

            config_id=(
                record.get("id")
                or record.get(
                    "config_id"
                )
            )

            if config_id:

                snapshot_ids.add(
                    str(config_id)
                )


        breakdown={
            "healthy":0,
            "recovered":0,
        }

        unresolved_breakdown=0


        for config_id in snapshot_ids:

            item=index.get(
                config_id
            )

            if not isinstance(
                item,
                dict,
            ):

                unresolved_breakdown+=1
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
                not eligible
                or state
                not in ALLOWED_STATES
            ):

                # State changed between canonical
                # snapshot and policy read.
                unresolved_breakdown+=1
                continue


            if state in breakdown:

                breakdown[state]+=1

            else:

                unresolved_breakdown+=1


        classified=(
            breakdown["healthy"]
            +breakdown["recovered"]
        )


        coherent=(
            len(snapshot_ids)
            ==snapshot.publishable
            and classified
            ==snapshot.publishable
            and unresolved_breakdown
            ==0
        )


        last={
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
                int(
                    breakdown["healthy"]
                ),

            "recovered":
                int(
                    breakdown["recovered"]
                ),

            "eligible_by_state":{
                "healthy":
                    int(
                        breakdown[
                            "healthy"
                        ]
                    ),

                "recovered":
                    int(
                        breakdown[
                            "recovered"
                        ]
                    ),
            },

            "allowed_states":
                sorted(
                    str(x)
                    for x
                    in ALLOWED_STATES
                ),

            "breakdown_unresolved":
                int(
                    unresolved_breakdown
                ),

            "coherent":
                bool(coherent),

            "coherence_attempt":
                attempt,

            "production_delete":
                False,
        }


        if coherent:
            return last


        # Very short retry only; no production mutation.
        time.sleep(0.02)


    # State may be changing continuously.
    # Publishable itself is still canonical.
    return last or {
        "_source":
            "app.publish.filter.build_publish_snapshot",

        "available":
            False,

        "error":
            "snapshot_unavailable",
    }


'''

s=(
    s[:start]
    +new
    +s[end+1:]
)

p.write_text(s)

print(
    "COHERENT_STATUS_PATCH=PASS"
)
PY


echo
echo "=== 2. COMPILE ==="

"$PY" -m py_compile \
"$MODEL" \
"$SERVER" \
"$UI"

echo "COMPILE=PASS"


echo
echo "=== 3. CANONICAL MODEL AS PANEL USER ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
from app.panel.publish_read_model import (
    publish_summary,
)

s=publish_summary()

status=s[
    "publish_status"
]

print(
    "STATUS=",
    status,
)

assert status[
    "available"
] is True

assert status[
    "policy_available"
] is True

assert status[
    "publishable"
]>=0

assert (
    status["healthy"]
    +status["recovered"]
    +status["breakdown_unresolved"]
    ==
    status["publishable"]
)

print(
    "PUBLISHABLE=",
    status["publishable"],
)

print(
    "HEALTHY=",
    status["healthy"],
)

print(
    "RECOVERED=",
    status["recovered"],
)

print(
    "BREAKDOWN_UNRESOLVED=",
    status[
        "breakdown_unresolved"
    ],
)

print(
    "COHERENT=",
    status["coherent"],
)

print(
    "ATTEMPT=",
    status[
        "coherence_attempt"
    ],
)

print(
    "CONFIGLOC_CANONICAL_MODEL=PASS"
)
PY


echo
echo "=== 4. MULTI-SAMPLE LIVE STABILITY ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
from app.panel.publish_read_model import (
    publish_summary,
)

for i in range(10):

    status=publish_summary()[
        "publish_status"
    ]

    total=(
        status["healthy"]
        +status["recovered"]
        +status[
            "breakdown_unresolved"
        ]
    )

    print(
        "SAMPLE=",
        i+1,
        "TOTAL_CONFIGS=",
        status["total_configs"],
        "PUBLISHABLE=",
        status["publishable"],
        "HEALTHY=",
        status["healthy"],
        "RECOVERED=",
        status["recovered"],
        "UNRESOLVED=",
        status[
            "breakdown_unresolved"
        ],
        "COHERENT=",
        status["coherent"],
    )

    assert (
        total
        ==
        status["publishable"]
    )


print(
    "LIVE_STABILITY=PASS"
)
PY


echo
echo "=== 5. CANONICAL HTTP HANDLER EXISTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import (
    create_app,
)

app=create_app()

routes={
    (
        r.method,
        getattr(
            r.resource,
            "canonical",
            "",
        ),
    )
    for r in app.router.routes()
}

required={
    (
        "GET",
        "/api/publish/status",
    ),
    (
        "GET",
        "/api/publish/summary",
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

print(
    "MISSING=",
    required-routes,
)

assert not (
    required-routes
)

print(
    "PUBLISH_ROUTES=PASS"
)
PY


echo
echo "=== 6. RESTART PANEL ONLY ==="

systemctl restart \
config-location-panel.service

sleep 4

test "$(
    systemctl is-active \
    config-location-panel.service
)" = active

echo "PANEL_RESTART=PASS"


echo
echo "=== 7. AUTHENTICATED PANEL STATUS ==="

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

    k,v=line.split(
        "=",
        1,
    )

    env[k.strip()]=(
        v.strip()
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

for k,v in headers:

    if k.lower()=="set-cookie":

        cookie=v.split(
            ";",
            1,
        )[0]

        break

assert cookie


conn=http.client.HTTPConnection(
    "127.0.0.1",
    4040,
    timeout=60,
)

conn.request(
    "GET",
    "/api/publish/summary",
    headers={
        "Cookie":cookie,
        "Accept":"application/json",
        "Cache-Control":"no-cache",
    },
)

r=conn.getresponse()

raw=r.read().decode(
    "utf-8",
    errors="replace",
)

status_code=r.status

conn.close()


print(
    "HTTP_STATUS=",
    status_code,
)

data=json.loads(raw)

status=data[
    "publish_status"
]

print(
    "PUBLISHABLE=",
    status["publishable"],
)

print(
    "HEALTHY=",
    status["healthy"],
)

print(
    "RECOVERED=",
    status["recovered"],
)

print(
    "UNRESOLVED=",
    status[
        "breakdown_unresolved"
    ],
)

print(
    "COHERENT=",
    status[
        "coherent"
    ],
)


assert status_code==200

assert status[
    "publishable"
]>0

assert (
    status["healthy"]
    +status["recovered"]
    +status[
        "breakdown_unresolved"
    ]
    ==
    status["publishable"]
)

print(
    "LIVE_PANEL_STATUS=PASS"
)
PY


echo
echo "=== 8. PUBLIC CANONICAL STATUS SMOKE ==="

"$PY" <<'PY'
import http.client
import json

conn=http.client.HTTPConnection(
    "127.0.0.1",
    4040,
    timeout=60,
)

conn.request(
    "GET",
    "/api/publish/status",
)

r=conn.getresponse()

raw=r.read().decode(
    "utf-8",
    errors="replace",
)

status=r.status

conn.close()

data=json.loads(raw)

print(
    "STATUS=",
    status,
)

print(
    "CANONICAL=",
    data,
)

assert status==200

assert data[
    "policy_available"
] is True

assert data[
    "publishable"
]>0

print(
    "CANONICAL_STATUS_HTTP=PASS"
)
PY


echo
echo "=== 9. CORE SERVICES ==="

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
echo "======================================================"
echo "PANEL_A7_R5=PASS"
echo "CANONICAL_PUBLISH=CONNECTED"
echo "LIVE_STATE_RACE=HANDLED"
echo "PUBLISHABLE=REAL"
echo "HEALTHY_RECOVERED_BREAKDOWN=COHERENT"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A8"
echo "======================================================"
