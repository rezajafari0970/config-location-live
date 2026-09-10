#!/usr/bin/env bash
set -Eeu -o pipefail

PHASE="phase5-pass6e-production-country-route-observation-endpoint-regression"

PROJECT="/opt/config-location"
REPO="/root/project-log"
BASE="http://127.0.0.1:4040"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

CYCLES=5
SLEEP_SECONDS=20

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
OBS_DIR="$DISCOVERY_DIR/${PHASE}-${TS}-cycles"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"
TARGET_JSON="$OBS_DIR/targets.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR" \
  "$OBS_DIR"

RESULT="SUCCESS"
ERRORS=""

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
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
PRODUCTION COUNTRY ROUTE OBSERVATION / ENDPOINT REGRESSION

Cycles:
$CYCLES

Production mutation:
NONE

Publish mutation:
NONE

Endpoint mutation:
NONE

Service restart:
NONE

Summary:
$SUMMARY

Observation:
$OBS_DIR

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
      "$OBS_DIR" \
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
echo " PHASE 5 PASS 6E"
echo " PRODUCTION COUNTRY ROUTE OBSERVATION"
echo " ENDPOINT REGRESSION"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/10] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f "$PROJECT/app/publish/http.py" || {
    fail "publish http.py missing"
    exit 1
}

test -f "$PROJECT/app/country/projection.py" || {
    fail "country projection missing"
    exit 1
}

grep -q \
  '/sub/country/{country_code}' \
  "$PROJECT/app/publish/http.py" || {
    fail "production country route missing"
    exit 1
}

systemctl is-active \
  config-location-panel.service \
  >/dev/null || {
    fail "panel service inactive"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 CODE HASH BASELINE
################################################

echo
echo "========== [2/10] PRODUCTION HASH BASELINE =========="

HTTP_HASH_BEFORE="$(
sha256sum \
  "$PROJECT/app/publish/http.py" \
  | awk '{print $1}'
)"

echo "HTTP_PY_HASH_BEFORE=$HTTP_HASH_BEFORE"


################################################
# 3 SELECT TEST TARGETS
################################################

echo
echo "========== [3/10] TARGET DISCOVERY =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$TARGET_JSON" <<'PY'
import json
import sys

from app.country.projection import build_projection
from app.publish.filter import build_publish_snapshot


projection = build_projection()
snapshot = build_publish_snapshot()

publish_ids = {
    str(record["id"])
    for record in snapshot.configs
    if isinstance(record, dict) and record.get("id")
}

country_counts = {}

for cid, row in projection.get("records", {}).items():
    if str(cid) not in publish_ids:
        continue

    if row.get("state") != "resolved":
        continue

    code = row.get("country_code")

    if not isinstance(code, str):
        continue

    code = code.strip().upper()

    if len(code) != 2 or not code.isalpha():
        continue

    country_counts[code] = country_counts.get(code, 0) + 1


countries = [
    code
    for code, count in sorted(
        country_counts.items(),
        key=lambda item: (-item[1], item[0]),
    )[:5]
]

assert countries, "no resolved production countries found"


type_counts = {}

for record in snapshot.configs:
    if not isinstance(record, dict):
        continue

    config_type = record.get("type")

    if not isinstance(config_type, str):
        continue

    config_type = config_type.strip().lower()

    if not config_type:
        continue

    type_counts[config_type] = (
        type_counts.get(config_type, 0) + 1
    )

assert type_counts, "no production config types found"

selected_type = max(
    type_counts,
    key=type_counts.get,
)


data = {
    "snapshot_publishable": snapshot.publishable,
    "countries": countries,
    "selected_country_counts": {
        code: country_counts[code]
        for code in countries
    },
    "config_type": selected_type,
    "config_type_count": type_counts[selected_type],
}

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:
    json.dump(
        data,
        fh,
        ensure_ascii=False,
        indent=2,
    )
    fh.write("\n")


print("SNAPSHOT_PUBLISHABLE=", snapshot.publishable)
print("COUNTRIES=", countries)
print("COUNTRY_COUNTS=", data["selected_country_counts"])
print("CONFIG_TYPE=", selected_type)
print("CONFIG_TYPE_COUNT=", type_counts[selected_type])
print("TARGET_DISCOVERY_OK")
PY


COUNTRIES="$(
"$PROJECT/venv/bin/python" \
  -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["countries"]))' \
  "$TARGET_JSON"
)"

CONFIG_TYPE="$(
"$PROJECT/venv/bin/python" \
  -c 'import json,sys; print(json.load(open(sys.argv[1]))["config_type"])' \
  "$TARGET_JSON"
)"

echo "COUNTRIES=$COUNTRIES"
echo "CONFIG_TYPE=$CONFIG_TYPE"


################################################
# 4 OBSERVATION CYCLES
################################################

echo
echo "========== [4/10] OBSERVATION =========="

for i in $(seq 1 "$CYCLES"); do

    echo
    echo "---------- CYCLE $i/$CYCLES ----------"

    CYCLE="$OBS_DIR/cycle-$i"
    mkdir -p "$CYCLE"

    date -Is > "$CYCLE/timestamp.txt"


    ############################################
    # /sub/all
    ############################################

    curl \
      -sS \
      --max-time 20 \
      -D "$CYCLE/all.headers" \
      -o "$CYCLE/all.body" \
      -w '{"http":%{http_code},"seconds":%{time_total},"size":%{size_download}}\n' \
      "$BASE/sub/all" \
      > "$CYCLE/all.curl.json" \
      || true


    ############################################
    # /sub/{config_type}
    ############################################

    curl \
      -sS \
      --max-time 20 \
      -D "$CYCLE/type.headers" \
      -o "$CYCLE/type.body" \
      -w '{"http":%{http_code},"seconds":%{time_total},"size":%{size_download}}\n' \
      "$BASE/sub/$CONFIG_TYPE" \
      > "$CYCLE/type.curl.json" \
      || true


    ############################################
    # top countries
    ############################################

    for COUNTRY in $COUNTRIES; do

        curl \
          -sS \
          --max-time 20 \
          -D "$CYCLE/country-$COUNTRY.headers" \
          -o "$CYCLE/country-$COUNTRY.body" \
          -w '{"http":%{http_code},"seconds":%{time_total},"size":%{size_download}}\n' \
          "$BASE/sub/country/$COUNTRY" \
          > "$CYCLE/country-$COUNTRY.curl.json" \
          || true

    done


    ############################################
    # UNKNOWN
    ############################################

    curl \
      -sS \
      --max-time 20 \
      -D "$CYCLE/unknown.headers" \
      -o "$CYCLE/unknown.body" \
      -w '{"http":%{http_code},"seconds":%{time_total},"size":%{size_download}}\n' \
      "$BASE/sub/country/UNKNOWN" \
      > "$CYCLE/unknown.curl.json" \
      || true


    ############################################
    # invalid country
    ############################################

    curl \
      -sS \
      --max-time 10 \
      -D "$CYCLE/invalid.headers" \
      -o "$CYCLE/invalid.body" \
      -w '{"http":%{http_code},"seconds":%{time_total},"size":%{size_download}}\n' \
      "$BASE/sub/country/INVALID" \
      > "$CYCLE/invalid.curl.json" \
      || true


    echo "CYCLE_${i}_COMPLETE"

    if [ "$i" -lt "$CYCLES" ]; then
        sleep "$SLEEP_SECONDS"
    fi

done


################################################
# 5 ANALYZE OBSERVATIONS
################################################

echo
echo "========== [5/10] ANALYSIS =========="

"$PROJECT/venv/bin/python" \
- "$OBS_DIR" "$TARGET_JSON" "$CYCLES" "$SUMMARY" <<'PY'
import hashlib
import json
import statistics
import sys
from pathlib import Path


root = Path(sys.argv[1])

targets = json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)

cycle_count = int(sys.argv[3])
summary_path = Path(sys.argv[4])

countries = targets["countries"]


def load_json(path):
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
            )
        )
    except Exception:
        return {
            "http": 0,
            "seconds": 999.0,
            "size": 0,
        }


def sha256(path):
    if not path.exists():
        return None

    return hashlib.sha256(
        path.read_bytes()
    ).hexdigest()


def line_count(path):
    if not path.exists():
        return 0

    return sum(
        1
        for line in path.read_text(
            encoding="utf-8",
            errors="replace",
        ).splitlines()
        if line.strip()
    )


def header(path, wanted):
    if not path.exists():
        return None

    wanted = wanted.lower()

    for line in path.read_text(
        encoding="utf-8",
        errors="replace",
    ).splitlines():

        if ":" not in line:
            continue

        key, value = line.split(
            ":",
            1,
        )

        if key.strip().lower() == wanted:
            return value.strip()

    return None


rows = []

for i in range(1, cycle_count + 1):

    cycle = root / f"cycle-{i}"

    row = {
        "cycle": i,

        "timestamp": (
            cycle / "timestamp.txt"
        ).read_text(
            encoding="utf-8",
        ).strip(),

        "all": load_json(
            cycle / "all.curl.json"
        ),

        "type": load_json(
            cycle / "type.curl.json"
        ),

        "unknown": load_json(
            cycle / "unknown.curl.json"
        ),

        "invalid": load_json(
            cycle / "invalid.curl.json"
        ),

        "all_sha256": sha256(
            cycle / "all.body"
        ),

        "all_lines": line_count(
            cycle / "all.body"
        ),

        "type_lines": line_count(
            cycle / "type.body"
        ),

        "countries": {},
    }


    unknown_count_header = header(
        cycle / "unknown.headers",
        "X-Config-Country-Count",
    )

    row["unknown"][
        "header_count"
    ] = (
        int(unknown_count_header)
        if (
            unknown_count_header
            and unknown_count_header.isdigit()
        )
        else None
    )

    row["unknown"][
        "lines"
    ] = line_count(
        cycle / "unknown.body"
    )

    row["unknown"][
        "source"
    ] = header(
        cycle / "unknown.headers",
        "X-Country-Source",
    )


    for country in countries:

        curl_data = load_json(
            cycle
            / f"country-{country}.curl.json"
        )

        count_header = header(
            cycle
            / f"country-{country}.headers",
            "X-Config-Country-Count",
        )

        row[
            "countries"
        ][country] = {
            **curl_data,

            "header_count": (
                int(count_header)
                if (
                    count_header
                    and count_header.isdigit()
                )
                else None
            ),

            "lines": line_count(
                cycle
                / f"country-{country}.body"
            ),

            "source": header(
                cycle
                / f"country-{country}.headers",
                "X-Country-Source",
            ),

            "sha256": sha256(
                cycle
                / f"country-{country}.body"
            ),
        }


    rows.append(row)


################################################
# HTTP gates
################################################

sub_all_http = all(
    row["all"]["http"] == 200
    for row in rows
)

sub_type_http = all(
    row["type"]["http"] == 200
    for row in rows
)

unknown_http = all(
    row["unknown"]["http"] == 200
    for row in rows
)

invalid_http = all(
    row["invalid"]["http"] == 404
    for row in rows
)

country_http = all(
    data["http"] == 200
    for row in rows
    for data in row[
        "countries"
    ].values()
)


################################################
# Country header gates
################################################

country_source_header = all(
    data["source"]
    == "canonical-projection-v2"
    for row in rows
    for data in row[
        "countries"
    ].values()
)

unknown_source_header = all(
    row["unknown"]["source"]
    == "canonical-projection-v2"
    for row in rows
)


################################################
# Country header/body count gates
################################################

country_count_match = all(
    data["header_count"]
    == data["lines"]
    for row in rows
    for data in row[
        "countries"
    ].values()
)

unknown_count_match = all(
    row["unknown"]["header_count"]
    == row["unknown"]["lines"]
    for row in rows
)


################################################
# latency
################################################

latencies = []

for row in rows:

    latencies.extend(
        [
            float(
                row["all"]["seconds"]
            ),
            float(
                row["type"]["seconds"]
            ),
            float(
                row["unknown"]["seconds"]
            ),
        ]
    )

    for data in row[
        "countries"
    ].values():

        latencies.append(
            float(
                data["seconds"]
            )
        )


max_latency = (
    max(latencies)
    if latencies
    else 999.0
)

average_latency = (
    statistics.mean(latencies)
    if latencies
    else 999.0
)


################################################
# /sub/all churn
################################################

all_sizes = [
    int(
        row["all"]["size"]
    )
    for row in rows
]

size_min = min(all_sizes)
size_max = max(all_sizes)
size_mean = statistics.mean(
    all_sizes
)

all_size_churn_pct = (
    (
        size_max
        - size_min
    )
    * 100
    / max(
        1,
        size_mean,
    )
)

sub_all_no_catastrophic_churn = (
    all_size_churn_pct <= 40.0
)


################################################
# Country count variation
################################################

country_series = {}

for country in countries:

    country_series[country] = [
        row[
            "countries"
        ][country][
            "header_count"
        ]
        for row in rows
    ]


unknown_series = [
    row["unknown"][
        "header_count"
    ]
    for row in rows
]


################################################
# Final gate
################################################

gates = {
    "sub_all_http_200":
        sub_all_http,

    "sub_type_http_200":
        sub_type_http,

    "country_http_200":
        country_http,

    "unknown_http_200":
        unknown_http,

    "invalid_http_404":
        invalid_http,

    "country_source_header":
        country_source_header,

    "unknown_source_header":
        unknown_source_header,

    "country_header_body_count_match":
        country_count_match,

    "unknown_header_body_count_match":
        unknown_count_match,

    "sub_all_no_catastrophic_churn":
        sub_all_no_catastrophic_churn,

    "max_latency_le_10s":
        max_latency <= 10.0,
}


stable = all(
    gates.values()
)


summary = {
    "phase":
        "phase5-pass6e-production-country-route-observation-endpoint-regression",

    "mode":
        "production_observation",

    "cycles":
        cycle_count,

    "targets":
        targets,

    "country_count_series":
        country_series,

    "unknown_count_series":
        unknown_series,

    "metrics": {
        "sub_all_size_min":
            size_min,

        "sub_all_size_max":
            size_max,

        "sub_all_size_churn_percent":
            round(
                all_size_churn_pct,
                3,
            ),

        "average_latency_seconds":
            round(
                average_latency,
                4,
            ),

        "max_latency_seconds":
            round(
                max_latency,
                4,
            ),
    },

    "gates":
        gates,

    "stable":
        stable,

    "rows":
        rows,

    "production_mutation":
        False,

    "publish_mutation":
        False,

    "endpoint_mutation":
        False,

    "service_restart":
        False,
}


summary_path.write_text(
    json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)


print(
    json.dumps(
        {
            "country_count_series":
                country_series,

            "unknown_count_series":
                unknown_series,

            "metrics":
                summary[
                    "metrics"
                ],

            "gates":
                gates,

            "stable":
                stable,
        },
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 6 FRESHNESS
################################################

echo
echo "========== [6/10] FRESHNESS =========="

"$PROJECT/venv/bin/python" \
- "$OBS_DIR" "$CYCLES" <<'PY'
import sys
from datetime import datetime
from pathlib import Path

root = Path(sys.argv[1])
cycles = int(sys.argv[2])

times = []

for i in range(1, cycles + 1):

    value = (
        root
        / f"cycle-{i}"
        / "timestamp.txt"
    ).read_text(
        encoding="utf-8"
    ).strip()

    times.append(
        datetime.fromisoformat(
            value
        )
    )


assert all(
    later > earlier
    for earlier, later
    in zip(
        times,
        times[1:],
    )
)

print(
    "FIRST_CYCLE=",
    times[0].isoformat(),
)

print(
    "LAST_CYCLE=",
    times[-1].isoformat(),
)

print("FRESHNESS_MONOTONIC=YES")
PY


################################################
# 7 SERVICE REGRESSION
################################################

echo
echo "========== [7/10] SERVICE REGRESSION =========="

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
        fail "$UNIT inactive"
        exit 1
    }

done

echo "SERVICE_REGRESSION_OK"


################################################
# 8 PRODUCTION IMMUTABILITY
################################################

echo
echo "========== [8/10] PRODUCTION IMMUTABILITY =========="

HTTP_HASH_AFTER="$(
sha256sum \
  "$PROJECT/app/publish/http.py" \
  | awk '{print $1}'
)"

echo "HTTP_PY_HASH_BEFORE=$HTTP_HASH_BEFORE"
echo "HTTP_PY_HASH_AFTER=$HTTP_HASH_AFTER"

[ "$HTTP_HASH_BEFORE" = "$HTTP_HASH_AFTER" ] || {
    fail "production http.py changed during observation"
    exit 1
}

echo "PRODUCTION_CODE_UNCHANGED=YES"


################################################
# 9 FINAL GATE
################################################

echo
echo "========== [9/10] FINAL GATE =========="

"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import json
import sys

data = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

print(
    "STABLE=",
    data["stable"],
)

for key, value in data[
    "gates"
].items():

    print(
        f"GATE_{key.upper()}={value}"
    )


print(
    "SUB_ALL_SIZE_CHURN_PERCENT=",
    data[
        "metrics"
    ][
        "sub_all_size_churn_percent"
    ],
)

print(
    "AVERAGE_LATENCY_SECONDS=",
    data[
        "metrics"
    ][
        "average_latency_seconds"
    ],
)

print(
    "MAX_LATENCY_SECONDS=",
    data[
        "metrics"
    ][
        "max_latency_seconds"
    ],
)


if not data["stable"]:
    raise SystemExit(2)


print("ENDPOINT_REGRESSION_GATE_PASS")
print("COUNTRY_ROUTE_STABILITY_GATE_PASS")
print("PRODUCTION_OBSERVATION_GATE_PASS")
PY


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "COUNTRY_PRODUCTION_ROUTE=STABLE"
echo "COUNTRY_SOURCE=CANONICAL_PROJECTION_V2"

echo "SUB_ALL_REGRESSION=PASS"
echo "SUB_TYPE_REGRESSION=PASS"
echo "COUNTRY_ENDPOINT_REGRESSION=PASS"

echo "FRESHNESS_GATE=PASS"
echo "SERVICE_REGRESSION=PASS"
echo "PRODUCTION_CODE_UNCHANGED=YES"

echo "PRODUCTION_MUTATION=NO"
echo "PUBLISH_MUTATION=NO"
echo "ENDPOINT_MUTATION=NO"
echo "SERVICE_RESTART=NO"

echo
echo "PHASE5_PASS6E_SUCCESS"

RESULT="SUCCESS"
