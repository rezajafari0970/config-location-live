#!/usr/bin/env bash
set -Eeu -o pipefail

PHASE="phase5-final-closure-churn-safe-consistency-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"
BASE="http://127.0.0.1:4040"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
DETAIL_DIR="$DISCOVERY_DIR/${PHASE}-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"

BEFORE="/tmp/phase5-churn-before-${TS}.json"
AFTER="/tmp/phase5-churn-after-${TS}.json"
VALIDATION="/tmp/phase5-churn-validation-${TS}.json"
NEW_VALIDATION="/tmp/phase5-churn-new-validation-${TS}.json"
CHURN="/tmp/phase5-churn-delta-${TS}.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR" \
  "$DETAIL_DIR"

rm -f \
  "$BEFORE" \
  "$AFTER" \
  "$VALIDATION" \
  "$NEW_VALIDATION" \
  "$CHURN"

RESULT="SUCCESS"
ERRORS=""

exec > >(tee -a "$LOG") 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

finish() {

    CODE=$?

    [ "$CODE" -eq 0 ] || RESULT="FAILED"

    {
        echo "Phase: $PHASE"
        echo "Result: $RESULT"
        echo "Timestamp: $(date -Is)"
        echo
        echo "Production mutation: NO"
        echo "Service restart: NO"
        echo "Contract: CHURN_SAFE"
        echo
        echo "Summary: $SUMMARY"
        echo "Details: $DETAIL_DIR"
        echo "Errors: $ERRORS"
    } > "$REPORT"

    cd "$REPO" || exit 1

    git add \
      "$LOG" \
      "$REPORT" \
      "$SUMMARY" \
      "$DETAIL_DIR" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase5 churn-safe final closure $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main \
      >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ]
}

trap finish EXIT


echo "================================================"
echo " PHASE 5 FINAL CLOSURE FIX"
echo " CHURN-SAFE CONSISTENCY CONTRACT"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/9] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

id configloc >/dev/null 2>&1 || {
    fail "configloc missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

grep -q \
  '/sub/country/{country_code}' \
  "$PROJECT/app/publish/http.py" || {
    fail "dynamic country route missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 COMPILE
################################################

echo
echo "========== [2/9] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/publish/http.py \
  app/publish/filter.py \
  app/country/projection.py \
  app/country/production_publish_projection.py \
  app/country/publish_contract_guard.py \
  app/country/country_identity.py \
  app/country/worker.py \
  app/country/pipeline.py

echo "COMPILE_OK"


################################################
# 3 PERMISSION CONTRACT
################################################

echo
echo "========== [3/9] PERMISSION CONTRACT =========="

PIPE_ROOT="/var/lib/config-location/country/pipeline/latest"
IDENTITY_ROOT="/var/lib/config-location/country/country-identity"

PIPE_BAD="$(
sudo -u configloc \
find "$PIPE_ROOT" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  ! -readable \
  -print 2>/dev/null |
wc -l
)"

IDENTITY_BAD="$(
sudo -u configloc \
find "$IDENTITY_ROOT" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  ! -readable \
  -print 2>/dev/null |
wc -l
)"

PIPE_TOTAL="$(
find "$PIPE_ROOT" \
  -maxdepth 1 \
  -type f \
  -name '*.json' |
wc -l
)"

IDENTITY_TOTAL="$(
find "$IDENTITY_ROOT" \
  -maxdepth 1 \
  -type f \
  -name '*.json' |
wc -l
)"

echo "PIPELINE_FILES=$PIPE_TOTAL"
echo "PIPELINE_UNREADABLE=$PIPE_BAD"

echo "IDENTITY_FILES=$IDENTITY_TOTAL"
echo "IDENTITY_UNREADABLE=$IDENTITY_BAD"

[ "$PIPE_BAD" -eq 0 ] || {
    fail "pipeline permission contract failed"
    exit 1
}

[ "$IDENTITY_BAD" -eq 0 ] || {
    fail "identity permission contract failed"
    exit 1
}

echo "PERMISSION_CONTRACT=PASS"


################################################
# 4 SERVICES / BASIC ENDPOINTS
################################################

echo
echo "========== [4/9] PRODUCTION BASELINE =========="

for UNIT in \
  config-location-panel.service \
  config-location-country-worker.service \
  config-location-country-event-consumer.service \
  config-location-country-publish-contract.timer
do

    ACTIVE="$(
        systemctl is-active \
          "$UNIT" \
          2>/dev/null || true
    )"

    echo "$UNIT=$ACTIVE"

    [ "$ACTIVE" = "active" ] || {
        fail "$UNIT inactive"
        exit 1
    }

done

ALL_HTTP="$(
curl -sS \
  --max-time 20 \
  -o "$DETAIL_DIR/sub-all.body" \
  -w '%{http_code}' \
  "$BASE/sub/all" \
  || true
)"

UNKNOWN_HTTP="$(
curl -sS \
  --max-time 20 \
  -D "$DETAIL_DIR/unknown.headers" \
  -o "$DETAIL_DIR/unknown.body" \
  -w '%{http_code}' \
  "$BASE/sub/country/UNKNOWN" \
  || true
)"

INVALID_HTTP="$(
curl -sS \
  --max-time 10 \
  -o "$DETAIL_DIR/invalid.body" \
  -w '%{http_code}' \
  "$BASE/sub/country/INVALID" \
  || true
)"

echo "SUB_ALL_HTTP=$ALL_HTTP"
echo "UNKNOWN_HTTP=$UNKNOWN_HTTP"
echo "INVALID_HTTP=$INVALID_HTTP"

[ "$ALL_HTTP" = "200" ]
[ "$UNKNOWN_HTTP" = "200" ]
[ "$INVALID_HTTP" = "404" ]

echo "PRODUCTION_BASELINE=PASS"


################################################
# HELPER: CANONICAL SNAPSHOT
################################################

make_snapshot() {

    OUT="$1"

    sudo -u configloc \
    env \
      HOME=/nonexistent \
      PYTHONPATH="$PROJECT" \
    "$PROJECT/venv/bin/python" \
    - "$OUT" <<'PY'
import hashlib
import json
import sys

from collections import Counter

from app.publish.filter import build_publish_snapshot
from app.country.projection import build_projection


snapshot = build_publish_snapshot()
projection = build_projection()

ids = {
    str(row["id"])
    for row in snapshot.configs
    if isinstance(row, dict)
    and row.get("id")
}

counts = Counter()
unknown = 0
conflict = 0

for cid in ids:

    row = projection.get(
        "records",
        {},
    ).get(cid)

    if not isinstance(row, dict):
        unknown += 1
        continue

    if row.get("state") == "conflict":
        conflict += 1
        continue

    if row.get("state") != "resolved":
        unknown += 1
        continue

    code = row.get("country_code")

    if (
        isinstance(code, str)
        and len(code.strip()) == 2
        and code.strip().isalpha()
    ):
        counts[
            code.strip().upper()
        ] += 1
    else:
        unknown += 1


resolved = sum(counts.values())

accounted = (
    resolved
    + unknown
    + conflict
)

canonical = {
    "publishable":
        snapshot.publishable,

    "config_ids":
        len(ids),

    "resolved":
        resolved,

    "unknown":
        unknown,

    "conflict":
        conflict,

    "accounted":
        accounted,

    "countries":
        dict(
            sorted(
                counts.items()
            )
        ),
}


canonical["conservation_ok"] = (
    len(ids)
    == snapshot.publishable
    == accounted
)


fingerprint = hashlib.sha256(
    json.dumps(
        canonical,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
).hexdigest()

canonical["fingerprint"] = fingerprint


with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        canonical,
        fh,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )

    fh.write("\n")


print(
    "PUBLISHABLE=",
    canonical["publishable"],
)

print(
    "RESOLVED=",
    canonical["resolved"],
)

print(
    "UNKNOWN=",
    canonical["unknown"],
)

print(
    "CONFLICT=",
    canonical["conflict"],
)

print(
    "COUNTRY_COUNT=",
    len(canonical["countries"]),
)

print(
    "CONSERVATION_OK=",
    canonical["conservation_ok"],
)

print(
    "FINGERPRINT=",
    fingerprint,
)


if not canonical["conservation_ok"]:
    raise SystemExit(
        "CANONICAL_CONSERVATION_FAILED"
    )
PY
}


################################################
# HELPER: LIVE ENDPOINT VALIDATION
################################################

validate_codes() {

    SNAP="$1"
    OUT="$2"
    MODE="$3"

    sudo -u configloc \
    env \
      HOME=/nonexistent \
      PYTHONPATH="$PROJECT" \
    "$PROJECT/venv/bin/python" \
    - "$SNAP" "$OUT" "$MODE" <<'PY'
import json
import sys
import urllib.request


BASE = "http://127.0.0.1:4040"

snapshot = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

mode = sys.argv[3]


if mode == "ALL":
    codes = sorted(
        snapshot["countries"]
    )

elif mode == "NEW":
    codes = snapshot.get(
        "new_codes",
        [],
    )

else:
    raise SystemExit(
        "INVALID_VALIDATION_MODE"
    )


results = []
failed = []


def request_country(
    code,
    expected=None,
):

    request = urllib.request.Request(
        BASE
        + "/sub/country/"
        + code,
        headers={
            "User-Agent":
                "phase5-churn-safe-closure",
        },
    )

    try:

        with urllib.request.urlopen(
            request,
            timeout=20,
        ) as response:

            status = int(
                response.status
            )

            headers = dict(
                response.headers.items()
            )

            body = response.read()

    except Exception as exc:

        return {
            "code": code,
            "expected_at_snapshot": expected,
            "http": 0,
            "actual": -1,
            "body_lines": -1,
            "ok": False,
            "error": repr(exc),
        }


    text = body.decode(
        "utf-8",
        errors="replace",
    )

    lines = sum(
        1
        for line in text.splitlines()
        if line.strip()
    )


    try:
        actual = int(
            headers.get(
                "X-Config-Country-Count",
                "-1",
            )
        )
    except Exception:
        actual = -1


    try:
        publishable = int(
            headers.get(
                "X-Config-Publishable",
                "-1",
            )
        )
    except Exception:
        publishable = -1


    source = headers.get(
        "X-Country-Source"
    )

    contract = headers.get(
        "X-Country-Contract"
    )

    returned_code = headers.get(
        "X-Config-Country"
    )


    ok = (
        status == 200
        and actual >= 0
        and actual == lines
        and publishable >= actual
        and source
            == "canonical-projection-v2"
        and contract
            == "healthy"
        and returned_code == code
    )


    return {
        "code":
            code,

        "expected_at_snapshot":
            expected,

        "actual":
            actual,

        "body_lines":
            lines,

        "publishable_at_request":
            publishable,

        "http":
            status,

        "source":
            source,

        "contract":
            contract,

        "returned_code":
            returned_code,

        "drift":
            (
                None
                if expected is None
                else actual - expected
            ),

        "ok":
            ok,
    }


for code in codes:

    expected = snapshot.get(
        "countries",
        {},
    ).get(code)

    result = request_country(
        code,
        expected,
    )

    results.append(
        result
    )


    print(
        f"{code}: "
        f"snapshot={expected} "
        f"live={result['actual']} "
        f"lines={result['body_lines']} "
        f"drift={result.get('drift')} "
        f"http={result['http']} "
        f"ok={result['ok']}"
    )


    if not result["ok"]:
        failed.append(code)


data = {
    "mode":
        mode,

    "tested":
        len(results),

    "passed":
        sum(
            1
            for row in results
            if row["ok"]
        ),

    "failed":
        len(failed),

    "failed_codes":
        failed,

    "results":
        results,
}


with open(
    sys.argv[2],
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


print()
print(
    "ENDPOINTS_TESTED=",
    data["tested"],
)

print(
    "ENDPOINTS_PASSED=",
    data["passed"],
)

print(
    "ENDPOINTS_FAILED=",
    data["failed"],
)


if failed:
    raise SystemExit(2)
PY
}


################################################
# 5 BEFORE SNAPSHOT
################################################

echo
echo "========== [5/9] CANONICAL SNAPSHOT BEFORE =========="

make_snapshot "$BEFORE"

cp "$BEFORE" \
  "$DETAIL_DIR/snapshot-before.json"

echo "BEFORE_CONSERVATION=PASS"


################################################
# 6 WAVE 1 — ALL DISCOVERED COUNTRIES
################################################

echo
echo "========== [6/9] LIVE COUNTRY CONTRACT — WAVE 1 =========="

validate_codes \
  "$BEFORE" \
  "$VALIDATION" \
  "ALL"

cp "$VALIDATION" \
  "$DETAIL_DIR/validation-wave1.json"

echo "WAVE1_SELF_CONSISTENCY=PASS"


################################################
# 7 AFTER SNAPSHOT + CHURN + NEW COUNTRY WAVE
################################################

echo
echo "========== [7/9] CHURN RECONCILIATION =========="

make_snapshot "$AFTER"

cp "$AFTER" \
  "$DETAIL_DIR/snapshot-after.json"


"$PROJECT/venv/bin/python" \
- "$BEFORE" "$AFTER" "$CHURN" <<'PY'
import json
import sys


before = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

after = json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)


before_codes = set(
    before["countries"]
)

after_codes = set(
    after["countries"]
)


all_codes = sorted(
    before_codes
    | after_codes
)


changed = {}

for code in all_codes:

    a = before["countries"].get(
        code,
        0,
    )

    b = after["countries"].get(
        code,
        0,
    )

    if a != b:
        changed[code] = {
            "before": a,
            "after": b,
            "delta": b - a,
        }


new_codes = sorted(
    after_codes
    - before_codes
)

removed_codes = sorted(
    before_codes
    - after_codes
)


data = {
    "before_fingerprint":
        before["fingerprint"],

    "after_fingerprint":
        after["fingerprint"],

    "snapshot_stable":
        before["fingerprint"]
        == after["fingerprint"],

    "publishable_delta":
        after["publishable"]
        - before["publishable"],

    "resolved_delta":
        after["resolved"]
        - before["resolved"],

    "unknown_delta":
        after["unknown"]
        - before["unknown"],

    "conflict_delta":
        after["conflict"]
        - before["conflict"],

    "changed_country_count":
        len(changed),

    "changed_countries":
        changed,

    "new_codes":
        new_codes,

    "removed_codes":
        removed_codes,

    "before_conservation":
        before["conservation_ok"],

    "after_conservation":
        after["conservation_ok"],
}


with open(
    sys.argv[3],
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


print(
    "SNAPSHOT_STABLE=",
    "YES"
    if data["snapshot_stable"]
    else "NO",
)

print(
    "PUBLISHABLE_DELTA=",
    data["publishable_delta"],
)

print(
    "UNKNOWN_DELTA=",
    data["unknown_delta"],
)

print(
    "CHANGED_COUNTRIES=",
    data["changed_country_count"],
)

print(
    "NEW_COUNTRY_CODES=",
    " ".join(new_codes)
    if new_codes
    else "NONE",
)

print(
    "REMOVED_COUNTRY_CODES=",
    " ".join(removed_codes)
    if removed_codes
    else "NONE",
)

print(
    "CHURN_ACCEPTED=YES"
)
PY


cp "$CHURN" \
  "$DETAIL_DIR/churn.json"


# Build input containing only newly appeared codes.
"$PROJECT/venv/bin/python" \
- "$AFTER" "$CHURN" "$NEW_VALIDATION.input" <<'PY'
import json
import sys

after = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

churn = json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)

after["new_codes"] = churn[
    "new_codes"
]

json.dump(
    after,
    open(
        sys.argv[3],
        "w",
        encoding="utf-8",
    ),
    ensure_ascii=False,
    indent=2,
)
PY


NEW_COUNT="$(
"$PROJECT/venv/bin/python" \
-c \
'import json,sys; print(len(json.load(open(sys.argv[1]))["new_codes"]))' \
"$NEW_VALIDATION.input"
)"


echo "NEW_COUNTRY_COUNT=$NEW_COUNT"


if [ "$NEW_COUNT" -gt 0 ]; then

    echo
    echo "Testing countries discovered during validation..."

    validate_codes \
      "$NEW_VALIDATION.input" \
      "$NEW_VALIDATION" \
      "NEW"

else

    printf '%s\n' \
      '{"mode":"NEW","tested":0,"passed":0,"failed":0,"failed_codes":[],"results":[]}' \
      > "$NEW_VALIDATION"

    echo "NO_NEW_COUNTRY_WAVE_REQUIRED"

fi


cp "$NEW_VALIDATION" \
  "$DETAIL_DIR/validation-wave2-new-countries.json"


echo "CHURN_RECONCILIATION=PASS"


################################################
# 8 PERMANENT GUARD
################################################

echo
echo "========== [8/9] PERMANENT GUARD =========="

STATUS="/var/lib/config-location/country/publish-contract/status.json"

test -s "$STATUS" || {
    fail "publish-contract status missing"
    exit 1
}

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
    "GUARD_STATE=",
    data.get("state"),
)

print(
    "GUARD_HEALTHY=",
    data.get("healthy"),
)

gates = data.get(
    "gates",
    {},
)

print(
    "GUARD_GATES=",
    gates,
)

assert data.get(
    "healthy"
) is True

assert data.get(
    "state"
) == "healthy"

assert gates
assert all(
    gates.values()
)

print(
    "PERMANENT_GUARD=PASS"
)
PY


################################################
# 9 FINAL CLOSURE
################################################

echo
echo "========== [9/9] FINAL CLOSURE =========="

"$PROJECT/venv/bin/python" \
- \
"$BEFORE" \
"$AFTER" \
"$VALIDATION" \
"$NEW_VALIDATION" \
"$CHURN" \
"$SUMMARY" <<'PY'
import json
import sys


before = json.load(
    open(sys.argv[1])
)

after = json.load(
    open(sys.argv[2])
)

wave1 = json.load(
    open(sys.argv[3])
)

wave2 = json.load(
    open(sys.argv[4])
)

churn = json.load(
    open(sys.argv[5])
)


assert before["conservation_ok"]
assert after["conservation_ok"]

assert wave1["failed"] == 0
assert wave2["failed"] == 0


summary = {
    "phase":
        "phase5-final-closure-churn-safe-consistency-contract",

    "result":
        "SUCCESS",

    "phase5_state":
        "PRODUCTION_COMPLETE",

    "ready_for_phase6":
        True,

    "closure_contract":
        "CHURN_SAFE_SELF_CONSISTENT",

    "country_route":
        "/sub/country/{country_code}",

    "country_route_mode":
        "DYNAMIC_ALL_DISCOVERED_COUNTRIES",

    "country_source":
        "CANONICAL_PROJECTION_V2",

    "before_publishable":
        before["publishable"],

    "after_publishable":
        after["publishable"],

    "before_country_count":
        len(before["countries"]),

    "after_country_count":
        len(after["countries"]),

    "wave1_tested":
        wave1["tested"],

    "wave1_failed":
        wave1["failed"],

    "wave2_new_countries_tested":
        wave2["tested"],

    "wave2_failed":
        wave2["failed"],

    "snapshot_stable":
        churn["snapshot_stable"],

    "churn_observed":
        not churn["snapshot_stable"],

    "churn_accepted":
        True,

    "changed_country_count":
        churn["changed_country_count"],

    "publishable_delta":
        churn["publishable_delta"],

    "unknown_delta":
        churn["unknown_delta"],

    "new_country_codes":
        churn["new_codes"],

    "removed_country_codes":
        churn["removed_codes"],

    "canonical_conservation":
        "PASS",

    "endpoint_self_consistency":
        "PASS",

    "permission_contract":
        "PASS",

    "permanent_guard":
        "PASS",

    "production_mutation":
        False,

    "service_restart":
        False,
}


with open(
    sys.argv[6],
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
echo "=============================================="
echo " PHASE 5 CHURN-SAFE FINAL CLOSURE SUCCESS"
echo "=============================================="

echo "CANONICAL_CONSERVATION=PASS"
echo "ENDPOINT_SELF_CONSISTENCY=PASS"

echo "ALL_DISCOVERED_COUNTRIES=VALIDATED"
echo "NEWLY_DISCOVERED_COUNTRIES=VALIDATED"

echo "CHURN_ALLOWED=YES"
echo "CHURN_RECONCILIATION=PASS"

echo "PERMISSION_CONTRACT=PASS"
echo "PERMANENT_GUARD=PASS"

echo "PRODUCTION_MUTATION=NO"
echo "SERVICE_RESTART=NO"

echo
echo "PHASE5_STATE=PRODUCTION_COMPLETE"
echo "READY_FOR_PHASE6=YES"

echo
echo "PHASE5_FINAL_SUCCESS"

RESULT="SUCCESS"
