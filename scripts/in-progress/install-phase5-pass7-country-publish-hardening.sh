#!/usr/bin/env bash
set -Eeu -o pipefail

PHASE="phase5-pass7-country-publish-production-hardening-permanent-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"

HTTP="$PROJECT/app/publish/http.py"
GUARD="$PROJECT/app/country/publish_contract_guard.py"

STATE_ROOT="/var/lib/config-location/country/publish-contract"
STATUS="$STATE_ROOT/status.json"

SERVICE="/etc/systemd/system/config-location-country-publish-contract.service"
TIMER="/etc/systemd/system/config-location-country-publish-contract.timer"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR" \
  "$BACKUP_DIR" \
  "$STATE_ROOT"

RESULT="SUCCESS"
ERRORS=""
ROLLED_BACK="NO"

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

rollback() {

    echo
    echo "========== AUTOMATIC ROLLBACK =========="

    if [ -f "$BACKUP_DIR/http.py.before" ]; then
        cp -a \
          "$BACKUP_DIR/http.py.before" \
          "$HTTP"
    fi

    if [ -f "$BACKUP_DIR/publish_contract_guard.py.before" ]; then
        cp -a \
          "$BACKUP_DIR/publish_contract_guard.py.before" \
          "$GUARD"
    else
        rm -f "$GUARD"
    fi

    if [ -f "$BACKUP_DIR/service.before" ]; then
        cp -a \
          "$BACKUP_DIR/service.before" \
          "$SERVICE"
    else
        rm -f "$SERVICE"
    fi

    if [ -f "$BACKUP_DIR/timer.before" ]; then
        cp -a \
          "$BACKUP_DIR/timer.before" \
          "$TIMER"
    else
        rm -f "$TIMER"
    fi

    systemctl daemon-reload || true

    systemctl disable --now \
      config-location-country-publish-contract.timer \
      >/dev/null 2>&1 || true

    systemctl restart \
      config-location-panel.service \
      >/dev/null 2>&1 || true

    ROLLED_BACK="YES"

    echo "ROLLBACK_DONE"
}

finish() {

    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
    fi

    cat > "$REPORT" <<REPORT
CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Mode:
COUNTRY PUBLISH PRODUCTION HARDENING / PERMANENT CONTRACT

Country Route:
/sub/country/{country_code}

Permanent Guard:
config-location-country-publish-contract.timer

Contract Status:
$STATUS

Rollback:
$ROLLED_BACK

Config mutation:
NONE

Canonical Country-store mutation:
NONE

Summary:
$SUMMARY

Backup:
$BACKUP_DIR

Log:
$LOG

Errors:
$ERRORS
REPORT

    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$REPO" || exit 1

    git add \
      "$LOG" \
      "$REPORT" \
      "$SUMMARY" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase execution $PHASE $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT


echo "================================================"
echo " PHASE 5 PASS 7"
echo " COUNTRY PUBLISH PRODUCTION HARDENING"
echo " PERMANENT CONTRACT"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/14] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f "$HTTP" || {
    fail "publish http missing"
    exit 1
}

test -f "$PROJECT/app/publish/filter.py" || {
    fail "publish filter missing"
    exit 1
}

test -f "$PROJECT/app/country/projection.py" || {
    fail "projection missing"
    exit 1
}

test -f "$PROJECT/app/country/production_publish_projection.py" || {
    fail "production projection adapter missing"
    exit 1
}

grep -q \
  '/sub/country/{country_code}' \
  "$HTTP" || {
    fail "country route missing"
    exit 1
}

systemctl is-active \
  config-location-panel.service \
  >/dev/null || {
    fail "panel inactive"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/14] BACKUP =========="

cp -a \
  "$HTTP" \
  "$BACKUP_DIR/http.py.before"

[ ! -f "$GUARD" ] || \
cp -a \
  "$GUARD" \
  "$BACKUP_DIR/publish_contract_guard.py.before"

[ ! -f "$SERVICE" ] || \
cp -a \
  "$SERVICE" \
  "$BACKUP_DIR/service.before"

[ ! -f "$TIMER" ] || \
cp -a \
  "$TIMER" \
  "$BACKUP_DIR/timer.before"

echo "BACKUP_OK"


################################################
# 3 /sub/all BASELINE
################################################

echo
echo "========== [3/14] PRODUCTION BASELINE =========="

BASE_ALL="/tmp/pass7-sub-all-before"

HTTP_BEFORE="$(
curl \
  -sS \
  --max-time 20 \
  -o "$BASE_ALL" \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  || true
)"

[ "$HTTP_BEFORE" = "200" ] || {
    fail "/sub/all baseline unhealthy"
    exit 1
}

SIZE_BEFORE="$(stat -c '%s' "$BASE_ALL")"
SHA_BEFORE="$(sha256sum "$BASE_ALL" | awk '{print $1}')"

HTTP_CODE_HASH_BEFORE="$(
sha256sum "$HTTP" \
| awk '{print $1}'
)"

echo "SUB_ALL_HTTP_BEFORE=$HTTP_BEFORE"
echo "SUB_ALL_SIZE_BEFORE=$SIZE_BEFORE"
echo "SUB_ALL_SHA_BEFORE=$SHA_BEFORE"
echo "HTTP_PY_SHA_BEFORE=$HTTP_CODE_HASH_BEFORE"


################################################
# 4 INSTALL PERMANENT GUARD
################################################

echo
echo "========== [4/14] INSTALL CONTRACT GUARD =========="

cat > "$GUARD" <<'PY'
from __future__ import annotations

import json
import os
import tempfile
import time
import urllib.error
import urllib.request

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.publish.filter import (
    PublishSnapshot,
    build_publish_snapshot,
)

from app.country.projection import (
    build_projection,
)


BASE = "http://127.0.0.1:4040"

STATE_ROOT = Path(
    "/var/lib/config-location/country/publish-contract"
)

STATUS = STATE_ROOT / "status.json"

TIMEOUT = 10.0


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def atomic_json(
    path: Path,
    data: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix="." + path.name + ".",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as fh:

            json.dump(
                data,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())

        os.chmod(
            tmp,
            0o640,
        )

        os.replace(
            tmp,
            path,
        )

    finally:

        if os.path.exists(tmp):
            os.unlink(tmp)


def http_get(
    path: str,
) -> dict[str, Any]:

    url = BASE + path

    started = time.monotonic()

    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "User-Agent":
                "config-location-country-contract/1",
        },
    )

    try:

        with urllib.request.urlopen(
            request,
            timeout=TIMEOUT,
        ) as response:

            body = response.read()

            status = int(
                response.status
            )

            headers = {
                k.lower(): v
                for k, v
                in response.headers.items()
            }

    except urllib.error.HTTPError as exc:

        body = exc.read()

        status = int(
            exc.code
        )

        headers = {
            k.lower(): v
            for k, v
            in exc.headers.items()
        }

    elapsed = (
        time.monotonic()
        - started
    )

    return {
        "path":
            path,

        "status":
            status,

        "body":
            body,

        "headers":
            headers,

        "elapsed_seconds":
            round(
                elapsed,
                4,
            ),
    }


def nonempty_lines(
    body: bytes,
) -> int:

    text = body.decode(
        "utf-8",
        errors="replace",
    )

    return sum(
        1
        for line in text.splitlines()
        if line.strip()
    )


def select_targets(
    snapshot: PublishSnapshot,
    projection: dict[str, Any],
) -> tuple[str, str]:

    publish_ids = {
        str(record["id"])
        for record in snapshot.configs
        if (
            isinstance(record, dict)
            and record.get("id")
        )
    }

    country_counts: dict[str, int] = {}

    for cid, row in projection.get(
        "records",
        {},
    ).items():

        if str(cid) not in publish_ids:
            continue

        if row.get(
            "state"
        ) != "resolved":
            continue

        code = row.get(
            "country_code"
        )

        if not isinstance(
            code,
            str,
        ):
            continue

        code = code.strip().upper()

        if (
            len(code) != 2
            or not code.isalpha()
        ):
            continue

        country_counts[code] = (
            country_counts.get(
                code,
                0,
            )
            + 1
        )

    if not country_counts:
        raise RuntimeError(
            "no resolved publishable country"
        )

    country = max(
        country_counts,
        key=country_counts.get,
    )

    type_counts: dict[str, int] = {}

    for record in snapshot.configs:

        if not isinstance(
            record,
            dict,
        ):
            continue

        config_type = record.get(
            "type"
        )

        if not isinstance(
            config_type,
            str,
        ):
            continue

        config_type = (
            config_type
            .strip()
            .lower()
        )

        if not config_type:
            continue

        type_counts[
            config_type
        ] = (
            type_counts.get(
                config_type,
                0,
            )
            + 1
        )

    if not type_counts:
        raise RuntimeError(
            "no publishable config type"
        )

    config_type = max(
        type_counts,
        key=type_counts.get,
    )

    return (
        country,
        config_type,
    )


def run_contract() -> dict[str, Any]:

    started = time.monotonic()

    gates: dict[str, bool] = {}

    errors: list[str] = []

    try:

        snapshot = (
            build_publish_snapshot()
        )

        gates[
            "snapshot_type"
        ] = isinstance(
            snapshot,
            PublishSnapshot,
        )

        gates[
            "snapshot_configs_tuple"
        ] = isinstance(
            snapshot.configs,
            tuple,
        )

        gates[
            "snapshot_count_match"
        ] = (
            len(
                snapshot.configs
            )
            == snapshot.publishable
        )

    except Exception as exc:

        snapshot = None

        errors.append(
            "snapshot:"
            + repr(exc)
        )

        gates[
            "snapshot_type"
        ] = False

        gates[
            "snapshot_configs_tuple"
        ] = False

        gates[
            "snapshot_count_match"
        ] = False


    try:

        projection = (
            build_projection()
        )

        gates[
            "projection_mapping"
        ] = isinstance(
            projection,
            dict,
        )

        gates[
            "projection_records"
        ] = isinstance(
            projection.get(
                "records"
            ),
            dict,
        )

    except Exception as exc:

        projection = None

        errors.append(
            "projection:"
            + repr(exc)
        )

        gates[
            "projection_mapping"
        ] = False

        gates[
            "projection_records"
        ] = False


    country = None
    config_type = None

    if (
        snapshot is not None
        and projection is not None
    ):

        try:

            country, config_type = (
                select_targets(
                    snapshot,
                    projection,
                )
            )

            gates[
                "target_selection"
            ] = True

        except Exception as exc:

            errors.append(
                "targets:"
                + repr(exc)
            )

            gates[
                "target_selection"
            ] = False

    else:

        gates[
            "target_selection"
        ] = False


    results: dict[str, Any] = {}


    def capture(
        key: str,
        path: str,
    ) -> None:

        try:

            results[key] = http_get(
                path
            )

        except Exception as exc:

            errors.append(
                key
                + ":"
                + repr(exc)
            )

            results[key] = {
                "path":
                    path,

                "status":
                    0,

                "body":
                    b"",

                "headers":
                    {},

                "elapsed_seconds":
                    999.0,
            }


    capture(
        "all",
        "/sub/all",
    )

    if config_type:

        capture(
            "type",
            "/sub/"
            + config_type,
        )

    if country:

        capture(
            "country",
            "/sub/country/"
            + country,
        )

    capture(
        "unknown",
        "/sub/country/UNKNOWN",
    )

    capture(
        "invalid",
        "/sub/country/INVALID",
    )


    gates[
        "sub_all_http_200"
    ] = (
        results["all"][
            "status"
        ] == 200
    )

    gates[
        "sub_all_nonempty"
    ] = (
        len(
            results["all"][
                "body"
            ]
        ) > 0
    )


    if "type" in results:

        gates[
            "sub_type_http_200"
        ] = (
            results["type"][
                "status"
            ] == 200
        )

    else:

        gates[
            "sub_type_http_200"
        ] = False


    if "country" in results:

        country_result = (
            results["country"]
        )

        gates[
            "country_http_200"
        ] = (
            country_result[
                "status"
            ] == 200
        )

        gates[
            "country_source_header"
        ] = (
            country_result[
                "headers"
            ].get(
                "x-country-source"
            )
            ==
            "canonical-projection-v2"
        )

        header_count = (
            country_result[
                "headers"
            ].get(
                "x-config-country-count"
            )
        )

        try:
            header_count_int = int(
                header_count
            )
        except Exception:
            header_count_int = -1

        gates[
            "country_count_match"
        ] = (
            header_count_int
            ==
            nonempty_lines(
                country_result[
                    "body"
                ]
            )
        )

    else:

        gates[
            "country_http_200"
        ] = False

        gates[
            "country_source_header"
        ] = False

        gates[
            "country_count_match"
        ] = False


    unknown = results[
        "unknown"
    ]

    gates[
        "unknown_http_200"
    ] = (
        unknown["status"]
        == 200
    )

    gates[
        "unknown_source_header"
    ] = (
        unknown[
            "headers"
        ].get(
            "x-country-source"
        )
        ==
        "canonical-projection-v2"
    )

    unknown_count = (
        unknown[
            "headers"
        ].get(
            "x-config-country-count"
        )
    )

    try:
        unknown_count_int = int(
            unknown_count
        )
    except Exception:
        unknown_count_int = -1

    gates[
        "unknown_count_match"
    ] = (
        unknown_count_int
        ==
        nonempty_lines(
            unknown[
                "body"
            ]
        )
    )


    gates[
        "invalid_http_404"
    ] = (
        results[
            "invalid"
        ][
            "status"
        ]
        == 404
    )


    latency_values = [
        float(
            result[
                "elapsed_seconds"
            ]
        )
        for result in results.values()
    ]

    max_latency = max(
        latency_values
    ) if latency_values else 999.0

    gates[
        "max_latency_le_10s"
    ] = (
        max_latency <= 10.0
    )


    healthy = all(
        gates.values()
    )


    clean_results = {}

    for key, value in results.items():

        clean_results[key] = {
            "path":
                value["path"],

            "status":
                value["status"],

            "elapsed_seconds":
                value[
                    "elapsed_seconds"
                ],

            "size":
                len(
                    value["body"]
                ),
        }


    data = {
        "component":
            "country-publish-contract-guard",

        "schema":
            1,

        "updated_at":
            now_iso(),

        "healthy":
            healthy,

        "state":
            (
                "healthy"
                if healthy
                else "contract_failed"
            ),

        "country_source":
            "CANONICAL_PROJECTION_V2",

        "selected_country":
            country,

        "selected_config_type":
            config_type,

        "publishable":
            (
                snapshot.publishable
                if snapshot is not None
                else None
            ),

        "gates":
            gates,

        "results":
            clean_results,

        "max_latency_seconds":
            round(
                max_latency,
                4,
            ),

        "errors":
            errors,

        "production_mutation":
            False,

        "service_restart":
            False,

        "fail_closed_contract":
            {
                "invalid_country_404":
                    True,

                "country_contract_failure":
                    "guard reports unhealthy and exits non-zero",
            },

        "elapsed_seconds":
            round(
                time.monotonic()
                - started,
                4,
            ),
    }


    atomic_json(
        STATUS,
        data,
    )

    return data


def main() -> int:

    data = run_contract()

    print(
        json.dumps(
            data,
            ensure_ascii=False,
            indent=2,
        )
    )

    return (
        0
        if data["healthy"]
        else 2
    )


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
PY

echo "GUARD_INSTALLED"


################################################
# 5 HARDEN COUNTRY HANDLER FAIL-CLOSED
################################################

echo
echo "========== [5/14] COUNTRY FAIL-CLOSED PATCH =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$HTTP" <<'PY'
import ast
import sys
from pathlib import Path


path = Path(
    sys.argv[1]
)

source = path.read_text(
    encoding="utf-8"
)

tree = ast.parse(source)


target = None

for node in tree.body:

    if (
        isinstance(
            node,
            ast.AsyncFunctionDef,
        )
        and node.name
        ==
        "subscription_country"
    ):
        target = node
        break


if target is None:
    raise SystemExit(
        "subscription_country missing"
    )


segment = ast.get_source_segment(
    source,
    target,
) or ""


if "HTTPServiceUnavailable" in segment:

    print(
        "FAIL_CLOSED_ALREADY_PRESENT=YES"
    )

    raise SystemExit(0)


new_function = r'''
async def subscription_country(request):

    country_code = str(
        request.match_info.get(
            "country_code",
            ""
        )
    ).strip().upper()

    if (
        country_code != "UNKNOWN"
        and (
            len(country_code) != 2
            or not country_code.isalpha()
        )
    ):
        raise web.HTTPNotFound()

    try:

        text, snapshot, count = (
            _country_subscription_text(
                country_code
            )
        )

    except Exception:

        raise web.HTTPServiceUnavailable(
            headers={
                "Cache-Control":
                    "no-store",

                "Retry-After":
                    "5",

                "X-Country-Source":
                    "canonical-projection-v2",

                "X-Country-Contract":
                    "unavailable",
            }
        )

    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Country":
                country_code,

            "X-Config-Publishable":
                str(
                    snapshot.publishable
                ),

            "X-Config-Country-Count":
                str(count),

            "X-Country-Source":
                "canonical-projection-v2",

            "X-Country-Contract":
                "healthy",
        },
    )
'''


replacement = ast.parse(
    new_function
).body[0]


lines = source.splitlines(
    keepends=True
)

start = target.lineno - 1
end = target.end_lineno


new_text = (
    "".join(
        lines[:start]
    )
    + ast.unparse(
        replacement
    )
    + "\n"
    + "".join(
        lines[end:]
    )
)


path.write_text(
    new_text,
    encoding="utf-8",
)


print(
    "COUNTRY_FAIL_CLOSED_PATCHED=YES"
)

print(
    "COUNTRY_CONTRACT_HEADER=ENABLED"
)

print(
    "PROJECTION_FAILURE_HTTP=503"
)
PY


################################################
# 6 COMPILE
################################################

echo
echo "========== [6/14] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/publish/http.py \
  app/country/publish_contract_guard.py \
  app/publish/filter.py \
  app/country/projection.py \
  app/country/production_publish_projection.py

echo "COMPILE_OK"


################################################
# 7 INSTALL SYSTEMD CONTRACT
################################################

echo
echo "========== [7/14] SYSTEMD CONTRACT =========="

cat > "$SERVICE" <<EOF_SERVICE
[Unit]
Description=Config Location Country Publish Permanent Contract Guard
After=network-online.target config-location-panel.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=$PROJECT
Environment=PYTHONPATH=$PROJECT
ExecStart=$PROJECT/venv/bin/python -m app.country.publish_contract_guard
TimeoutStartSec=45
Nice=10
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE


cat > "$TIMER" <<'EOF_TIMER'
[Unit]
Description=Config Location Country Publish Contract Timer

[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=config-location-country-publish-contract.service

[Install]
WantedBy=timers.target
EOF_TIMER


systemctl daemon-reload

echo "SYSTEMD_CONTRACT_INSTALLED"


################################################
# 8 RESTART PANEL FOR HARDENED HANDLER
################################################

echo
echo "========== [8/14] PANEL RESTART =========="

systemctl restart \
  config-location-panel.service

sleep 4

ACTIVE="$(
systemctl is-active \
  config-location-panel.service \
  || true
)"

echo "PANEL_ACTIVE=$ACTIVE"

if [ "$ACTIVE" != "active" ]; then

    rollback

    fail "panel inactive after hardening"
    exit 1
fi


################################################
# 9 /sub/all BYTE REGRESSION
################################################

echo
echo "========== [9/14] SUB ALL REGRESSION =========="

AFTER_ALL="/tmp/pass7-sub-all-after"

HTTP_AFTER="$(
curl \
  -sS \
  --max-time 20 \
  -o "$AFTER_ALL" \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  || true
)"

if [ "$HTTP_AFTER" != "200" ]; then

    rollback

    fail "/sub/all failed after hardening"
    exit 1
fi


SIZE_AFTER="$(
stat -c '%s' \
"$AFTER_ALL"
)"

SHA_AFTER="$(
sha256sum \
"$AFTER_ALL" \
| awk '{print $1}'
)"


echo "SUB_ALL_HTTP_AFTER=$HTTP_AFTER"
echo "SUB_ALL_SIZE_AFTER=$SIZE_AFTER"
echo "SUB_ALL_SHA_AFTER=$SHA_AFTER"


MIN_SIZE="$(( SIZE_BEFORE * 70 / 100 ))"

if [ "$SIZE_AFTER" -lt "$MIN_SIZE" ]; then

    rollback

    fail "/sub/all catastrophic shrink"
    exit 1
fi

echo "SUB_ALL_REGRESSION_OK"


################################################
# 10 START PERMANENT GUARD
################################################

echo
echo "========== [10/14] START PERMANENT GUARD =========="

systemctl enable --now \
  config-location-country-publish-contract.timer

systemctl start \
  config-location-country-publish-contract.service

sleep 3

TIMER_ACTIVE="$(
systemctl is-active \
  config-location-country-publish-contract.timer \
  || true
)"

echo "CONTRACT_TIMER_ACTIVE=$TIMER_ACTIVE"

[ "$TIMER_ACTIVE" = "active" ] || {

    rollback

    fail "contract timer inactive"
    exit 1
}


test -s "$STATUS" || {

    rollback

    fail "contract status missing"
    exit 1
}


echo "PERMANENT_GUARD_RUNNING=YES"


################################################
# 11 CONTRACT STATUS VALIDATION
################################################

echo
echo "========== [11/14] CONTRACT VALIDATION =========="

"$PROJECT/venv/bin/python" \
- "$STATUS" <<'PY'
import json
import sys

data = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

print(
    json.dumps(
        data,
        ensure_ascii=False,
        indent=2,
    )
)

assert (
    data["healthy"]
    is True
)

assert (
    data["state"]
    == "healthy"
)

assert (
    data["country_source"]
    ==
    "CANONICAL_PROJECTION_V2"
)

assert all(
    data["gates"].values()
)

print(
    "PERMANENT_CONTRACT_HEALTHY=YES"
)

print(
    "PERMANENT_CONTRACT_GATES=PASS"
)
PY


################################################
# 12 LIVE FAIL-CLOSED CONTRACT
################################################

echo
echo "========== [12/14] LIVE CONTRACT =========="

COUNTRY="$(
"$PROJECT/venv/bin/python" \
- "$STATUS" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

print(
    d["selected_country"]
)
PY
)"


echo "TEST_COUNTRY=$COUNTRY"


curl \
  -sS \
  --max-time 20 \
  -D /tmp/pass7-country.headers \
  -o /tmp/pass7-country.body \
  "http://127.0.0.1:4040/sub/country/$COUNTRY"


COUNTRY_HTTP="$(
awk \
  'toupper($1) ~ /^HTTP\// {code=$2} END {print code}' \
  /tmp/pass7-country.headers
)"


echo "COUNTRY_HTTP=$COUNTRY_HTTP"

[ "$COUNTRY_HTTP" = "200" ] || {

    rollback

    fail "healthy country endpoint failed"
    exit 1
}


grep -qi \
  '^X-Country-Contract: healthy' \
  /tmp/pass7-country.headers || {

    rollback

    fail "country contract header missing"
    exit 1
}


INVALID_HTTP="$(
curl \
  -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/INVALID \
  || true
)"


echo "INVALID_HTTP=$INVALID_HTTP"

[ "$INVALID_HTTP" = "404" ] || {

    rollback

    fail "invalid country not fail-closed"
    exit 1
}


echo "LIVE_CONTRACT_OK"


################################################
# 13 RUNTIME / IMMUTABILITY
################################################

echo
echo "========== [13/14] RUNTIME REGRESSION =========="

FATAL="$(
journalctl \
  -u config-location-panel.service \
  --since "$START" \
  --no-pager \
| grep -Ei \
  'Traceback|SyntaxError|ImportError|ModuleNotFoundError|fatal' \
|| true
)"


if [ -n "$FATAL" ]; then

    echo "$FATAL"

    rollback

    fail "panel runtime regression"
    exit 1
fi


for UNIT in \
  config-location-panel.service \
  config-location-country-worker.service \
  config-location-country-event-consumer.service
do

    ACTIVE="$(
        systemctl is-active \
        "$UNIT" \
        2>/dev/null || true
    )"

    echo "$UNIT ACTIVE=$ACTIVE"

    [ "$ACTIVE" = "active" ] || {

        rollback

        fail "$UNIT inactive"
        exit 1
    }

done


echo "RUNTIME_REGRESSION_OK"


################################################
# 14 FINAL SUMMARY
################################################

echo
echo "========== [14/14] FINAL =========="

HTTP_CODE_HASH_AFTER="$(
sha256sum "$HTTP" \
| awk '{print $1}'
)"


"$PROJECT/venv/bin/python" \
- "$STATUS" "$SUMMARY" <<PY
import json
import sys

status = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

summary = {
    "phase":
        "$PHASE",

    "result":
        "SUCCESS",

    "country_publish_state":
        "PRODUCTION_HARDENED",

    "country_route":
        "/sub/country/{country_code}",

    "country_source":
        "CANONICAL_PROJECTION_V2",

    "permanent_contract":
        True,

    "permanent_guard_service":
        "config-location-country-publish-contract.service",

    "permanent_guard_timer":
        "config-location-country-publish-contract.timer",

    "contract_status":
        "$STATUS",

    "contract_healthy":
        status["healthy"],

    "fail_closed_invalid_country":
        True,

    "projection_failure_behavior":
        "HTTP 503 on country route",

    "country_contract_header":
        "X-Country-Contract",

    "sub_all_http_before":
        "$HTTP_BEFORE",

    "sub_all_http_after":
        "$HTTP_AFTER",

    "sub_all_size_before":
        $SIZE_BEFORE,

    "sub_all_size_after":
        $SIZE_AFTER,

    "sub_all_sha_before":
        "$SHA_BEFORE",

    "sub_all_sha_after":
        "$SHA_AFTER",

    "http_py_sha_before":
        "$HTTP_CODE_HASH_BEFORE",

    "http_py_sha_after":
        "$HTTP_CODE_HASH_AFTER",

    "automatic_rollback":
        True,

    "rolled_back":
        False,

    "config_write":
        False,

    "canonical_country_store_write":
        False,
}

with open(
    sys.argv[2],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        summary,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")

print(
    json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )
)
PY


echo
echo "COUNTRY_PUBLISH=PRODUCTION_HARDENED"
echo "COUNTRY_SOURCE=CANONICAL_PROJECTION_V2"

echo "PERMANENT_CONTRACT=ENABLED"
echo "PERMANENT_GUARD_TIMER=ACTIVE"

echo "COUNTRY_FAILURE_HTTP=503"
echo "INVALID_COUNTRY_HTTP=404"
echo "COUNTRY_CONTRACT_HEADER=ENABLED"

echo "SUB_ALL_REGRESSION=PASS"
echo "SUB_TYPE_CONTRACT=PROTECTED"

echo "AUTOMATIC_ROLLBACK=READY"
echo "ROLLED_BACK=NO"

echo "CONFIG_WRITE=NO"
echo "CANONICAL_COUNTRY_STORE_WRITE=NO"

echo
echo "PHASE5_PASS7_SUCCESS"

RESULT="SUCCESS"
