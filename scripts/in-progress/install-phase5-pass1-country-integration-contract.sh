#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass1-canonical-country-state-config-integration-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
DISCOVERY="$DISCOVERY_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR"

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
        ERRORS="${ERRORS}\nexit code $CODE"
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
READ ONLY INTEGRATION CONTRACT AUDIT

Country mutation:
NONE

Config mutation:
NONE

Publish mutation:
NONE

Panel mutation:
NONE

Service restart:
NONE

Discovery:
$DISCOVERY

Summary:
$SUMMARY

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
      "$DISCOVERY" \
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
echo " PHASE 5 PASS 1"
echo " CANONICAL COUNTRY STATE / CONFIG INTEGRATION"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/12] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -d "$PROJECT/app/country" || {
    fail "country package missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 COMPILE IMPORTANT MODULES
################################################

echo
echo "========== [2/12] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/pipeline.py \
  app/country/storage.py \
  app/country/country_identity.py \
  app/country/worker.py \
  app/country/event_consumer.py \
  app/country/geo_intelligence.py \
  app/publish/filter.py \
  app/publish/http.py \
  app/panel/read_model.py \
  app/panel/country_ui.py \
  app/core/config_store.py

echo "COMPILE_OK"


################################################
# 3 STATIC INTEGRATION MAP
################################################

echo
echo "========== [3/12] STATIC MAP =========="

{
echo "================================================"
echo " PHASE 5 PASS 1"
echo " CANONICAL COUNTRY STATE / CONFIG INTEGRATION"
echo "================================================"

echo "TIME=$(date -Is)"

echo
echo "========== A. COUNTRY STORAGE SYMBOLS =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

files = [
    "app/country/storage.py",
    "app/country/country_identity.py",
    "app/country/pipeline.py",
    "app/country/worker.py",
    "app/country/event_consumer.py",
    "app/publish/filter.py",
    "app/publish/http.py",
    "app/panel/read_model.py",
    "app/panel/country_ui.py",
    "app/core/config_store.py",
]

root = Path(os.environ["PROJECT"])

for rel in files:
    path = root / rel

    if not path.exists():
        continue

    print()
    print("FILE:", path)

    try:
        tree = ast.parse(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception as exc:
        print("PARSE_ERROR:", repr(exc))
        continue

    for node in ast.walk(tree):
        if isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
                ast.ClassDef,
            ),
        ):
            low = node.name.lower()

            if any(
                x in low
                for x in (
                    "country",
                    "config",
                    "publish",
                    "identity",
                    "result",
                    "view",
                    "read",
                    "load",
                    "save",
                    "iter",
                    "query",
                )
            ):
                print(
                    f"{node.lineno:5d} "
                    f"{type(node).__name__:18s} "
                    f"{node.name}"
                )
PY

echo
echo "========== B. COUNTRY STORAGE PATH REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  '/var/lib/config-location/country|country/results|country/pipeline|country-identity|pipeline/latest' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 2200 || true

echo
echo "========== C. CONFIG COUNTRY FIELD REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  '"country"|"country_name"|"country_code"|"flag"|"country_confidence"|country_identity' \
  "$PROJECT/app/core" \
  "$PROJECT/app/country" \
  "$PROJECT/app/panel" \
  "$PROJECT/app/publish" \
  2>/dev/null \
  | head -n 2600 || true

echo
echo "========== D. PUBLISH COUNTRY REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'country|flag|unknown|naesh|ناشناس|sub/all|publishable_config_ids|country_name|country_code' \
  "$PROJECT/app/publish" \
  "$PROJECT/app/panel" \
  2>/dev/null \
  | head -n 2200 || true


################################################
# 4 RUNTIME CORRELATION
################################################

echo
echo "========== [4] RUNTIME CORRELATION =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from pathlib import Path
from collections import Counter

CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

COUNTRY_ROOT = Path(
    "/var/lib/config-location/country"
)

RESULT_ROOT = (
    COUNTRY_ROOT / "results"
)

IDENTITY_ROOT = (
    COUNTRY_ROOT / "country-identity"
)

PIPELINE_LATEST_ROOT = (
    COUNTRY_ROOT / "pipeline" / "latest"
)

UNKNOWN_VALUES = {
    "",
    "unknown",
    "Unknown",
    "UNKNOWN",
    "ناشناس",
    "none",
    "null",
    "--",
}

def load(path):
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return None

def country_from_obj(d):
    if not isinstance(d, dict):
        return None

    for key in (
        "country_name",
        "country",
        "country_code",
    ):
        value = d.get(key)

        if value is not None:
            text = str(value).strip()

            if text and text not in UNKNOWN_VALUES:
                return text

    return None

configs = {}

if CONFIG_ROOT.exists():
    for path in CONFIG_ROOT.glob("*.json"):
        data = load(path)

        if not isinstance(data, dict):
            continue

        cid = str(
            data.get(
                "config_id",
                path.stem,
            )
        )

        configs[cid] = {
            "path": path,
            "data": data,
            "country": country_from_obj(data),
        }

def index_json_dir(root):
    out = {}

    if not root.exists():
        return out

    for path in root.rglob("*.json"):
        data = load(path)

        if not isinstance(data, dict):
            continue

        cid = (
            data.get("config_id")
            or data.get("id")
            or path.stem
        )

        if not cid:
            continue

        out[str(cid)] = {
            "path": path,
            "data": data,
            "country": country_from_obj(data),
        }

    return out

results = index_json_dir(
    RESULT_ROOT
)

identities = index_json_dir(
    IDENTITY_ROOT
)

pipeline = index_json_dir(
    PIPELINE_LATEST_ROOT
)

total = len(configs)

config_known = sum(
    1 for row in configs.values()
    if row["country"]
)

results_known = sum(
    1 for row in results.values()
    if row["country"]
)

identity_known = sum(
    1 for row in identities.values()
    if row["country"]
)

pipeline_known = sum(
    1 for row in pipeline.values()
    if row["country"]
)

config_ids = set(configs)
result_ids = set(results)
identity_ids = set(identities)
pipeline_ids = set(pipeline)

intersection_result = (
    config_ids & result_ids
)

intersection_identity = (
    config_ids & identity_ids
)

intersection_pipeline = (
    config_ids & pipeline_ids
)

resolved_elsewhere = []

for cid in config_ids:

    config_country = configs[cid]["country"]

    result_country = (
        results.get(cid, {}).get("country")
    )

    identity_country = (
        identities.get(cid, {}).get("country")
    )

    pipeline_country = (
        pipeline.get(cid, {}).get("country")
    )

    external = (
        identity_country
        or result_country
        or pipeline_country
    )

    if (
        not config_country
        and external
    ):
        resolved_elsewhere.append(
            {
                "config_id": cid,
                "external_country": external,
                "result_country": result_country,
                "identity_country": identity_country,
                "pipeline_country": pipeline_country,
            }
        )

print("TOTAL_CONFIGS=", total)
print("CONFIG_KNOWN_COUNTRY=", config_known)

print("COUNTRY_RESULTS_FILES=", len(results))
print("COUNTRY_RESULTS_KNOWN=", results_known)

print("COUNTRY_IDENTITY_FILES=", len(identities))
print("COUNTRY_IDENTITY_KNOWN=", identity_known)

print("PIPELINE_LATEST_FILES=", len(pipeline))
print("PIPELINE_LATEST_KNOWN=", pipeline_known)

print("CONFIG_RESULT_ID_OVERLAP=", len(intersection_result))
print("CONFIG_IDENTITY_ID_OVERLAP=", len(intersection_identity))
print("CONFIG_PIPELINE_ID_OVERLAP=", len(intersection_pipeline))

print(
    "CONFIG_UNKNOWN_BUT_COUNTRY_RESOLVED_ELSEWHERE=",
    len(resolved_elsewhere),
)

print(
    "RESOLVED_ELSEWHERE_SAMPLE=",
    json.dumps(
        resolved_elsewhere[:40],
        ensure_ascii=False,
        indent=2,
    ),
)
PY


################################################
# 5 SAMPLE DEEP JOIN
################################################

echo
echo "========== [5] SAMPLE DEEP JOIN =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from pathlib import Path

CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

SEARCH_ROOT = Path(
    "/var/lib/config-location/country"
)

def load(path):
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return None

samples = []

for path in CONFIG_ROOT.glob("*.json"):

    d = load(path)

    if not isinstance(d, dict):
        continue

    cid = str(
        d.get(
            "config_id",
            path.stem,
        )
    )

    country = (
        d.get("country")
        or d.get("country_name")
        or d.get("country_code")
    )

    if country:
        continue

    hits = []

    for root in (
        SEARCH_ROOT / "results",
        SEARCH_ROOT / "country-identity",
        SEARCH_ROOT / "pipeline" / "latest",
    ):

        if not root.exists():
            continue

        direct = root / f"{cid}.json"

        if direct.exists():
            hits.append(
                str(direct)
            )

    if hits:
        samples.append(
            {
                "config_id": cid,
                "config_path": str(path),
                "country_hits": hits,
            }
        )

    if len(samples) >= 25:
        break

for sample in samples:

    print()
    print("CONFIG_ID=", sample["config_id"])
    print("CONFIG_PATH=", sample["config_path"])

    for hit in sample["country_hits"]:
        print("COUNTRY_PATH=", hit)

        data = load(Path(hit))

        if isinstance(data, dict):
            keep = {}

            for key in (
                "config_id",
                "state",
                "country",
                "country_code",
                "country_name",
                "flag",
                "country_confidence",
                "provider",
                "source",
                "reason",
                "updated_at",
                "detected_at",
            ):
                if key in data:
                    keep[key] = data[key]

            print(
                json.dumps(
                    keep,
                    ensure_ascii=False,
                    indent=2,
                )
            )
PY


################################################
# 6 PANEL READ MODEL
################################################

echo
echo "========== [6] PANEL READ MODEL =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'country_result|country_identity|country_name|country_code|flag|country_confidence' \
  "$PROJECT/app/panel" \
  2>/dev/null \
  | head -n 1600 || true


################################################
# 7 PUBLISH READ MODEL
################################################

echo
echo "========== [7] PUBLISH READ MODEL =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'country_result|country_identity|country_name|country_code|flag|country_confidence|country/' \
  "$PROJECT/app/publish" \
  2>/dev/null \
  | head -n 1600 || true


################################################
# 8 CONFIG STORE SCHEMA
################################################

echo
echo "========== [8] CONFIG STORE SCHEMA =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from pathlib import Path
from collections import Counter

root = Path(
    "/var/lib/config-location/configs"
)

counter = Counter()

samples = []

for path in root.glob("*.json"):

    try:
        d = json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        continue

    if not isinstance(d, dict):
        continue

    for key in d:
        counter[key] += 1

    if len(samples) < 5:
        samples.append(
            {
                "file": str(path),
                "keys": sorted(d.keys()),
            }
        )

print("TOP_KEYS=")

for key,count in counter.most_common(80):
    print(count, key)

print(
    "SAMPLE_KEYS=",
    json.dumps(
        samples,
        ensure_ascii=False,
        indent=2,
    ),
)
PY


################################################
# 9 SERVICE RUNTIME
################################################

echo
echo "========== [9] COUNTRY SERVICES =========="

for UNIT in \
  config-location-country-worker.service \
  config-location-country-event-consumer.service
do

    echo
    echo "--- $UNIT ---"

    systemctl is-active \
      "$UNIT" \
      2>/dev/null || true

    systemctl is-enabled \
      "$UNIT" \
      2>/dev/null || true

    systemctl status \
      "$UNIT" \
      --no-pager \
      -l \
      2>/dev/null \
      | head -n 100 || true

done


################################################
# 10 RECENT COUNTRY JOURNAL
################################################

echo
echo "========== [10] RECENT COUNTRY JOURNAL =========="

journalctl \
  --since "30 minutes ago" \
  --no-pager \
  -u config-location-country-worker.service \
  -u config-location-country-event-consumer.service \
  2>/dev/null \
  | tail -n 500 || true


################################################
# 11 STORAGE SIZE MAP
################################################

echo
echo "========== [11] COUNTRY STORAGE SIZE MAP =========="

find /var/lib/config-location/country \
  -mindepth 1 \
  -maxdepth 2 \
  -type d \
  -exec du -sh {} \; \
  2>/dev/null \
  | sort -h \
  | tail -n 100 || true


################################################
# 12 CONTRACT CONCLUSIONS INPUT
################################################

echo
echo "========== [12] CONTRACT QUESTIONS =========="

cat <<'QUESTIONS'
Q1. Is Config Store canonical for country?
Q2. Is country/results canonical?
Q3. Is country-identity canonical after lock?
Q4. Is pipeline/latest merely working state?
Q5. Does Panel merge Country Store at read time?
Q6. Does Publish merge Country Store at read time?
Q7. Is country intentionally excluded from Config Store?
Q8. How many current Config IDs overlap country/results?
Q9. How many current Config IDs overlap country-identity?
Q10. How many UNKNOWN configs already have resolved country elsewhere?
Q11. Are Country files keyed directly by config_id?
Q12. Is there stale Country state for deleted Config IDs?
Q13. Does worker write result only to Country Store?
Q14. Does event consumer write result only to Country Store?
Q15. Is a canonical projection layer missing?
Q16. Is Panel using the same canonical projection as Publish?
Q17. Are per-country subscriptions driven by config metadata or Country Store?
Q18. Is UNKNOWN caused by missing integration rather than failed resolution?
Q19. What exact component should own the country projection?
Q20. What is the safest Phase 5 Pass 2 implementation point?
QUESTIONS

echo
echo "READ_ONLY=true"
echo "COUNTRY_MUTATION=false"
echo "CONFIG_MUTATION=false"
echo "PUBLISH_MUTATION=false"
echo "PANEL_MUTATION=false"
echo "SERVICE_RESTART=false"

echo "PHASE5_PASS1_DISCOVERY_COMPLETE"

} > "$DISCOVERY"


################################################
# BUILD MACHINE SUMMARY
################################################

echo
echo "========== MACHINE SUMMARY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import json
import sys
from pathlib import Path

CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

COUNTRY_ROOT = Path(
    "/var/lib/config-location/country"
)

roots = {
    "results":
        COUNTRY_ROOT / "results",

    "identity":
        COUNTRY_ROOT / "country-identity",

    "pipeline_latest":
        COUNTRY_ROOT / "pipeline" / "latest",
}

def load(path):
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return None

def ids_from_dir(root):
    ids=set()

    if not root.exists():
        return ids

    for path in root.rglob("*.json"):

        data=load(path)

        if isinstance(data,dict):

            cid=(
                data.get("config_id")
                or data.get("id")
                or path.stem
            )

            if cid:
                ids.add(str(cid))

    return ids

config_ids=set()

for path in CONFIG_ROOT.glob("*.json"):

    d=load(path)

    if not isinstance(d,dict):
        continue

    cid=d.get(
        "config_id",
        path.stem,
    )

    config_ids.add(str(cid))

summary={
    "phase":
        "phase5-pass1-canonical-country-state-config-integration-contract",

    "read_only":
        True,

    "config_count":
        len(config_ids),

    "country_storage": {},

    "services": {
        "country_worker":
            "not_mutated",

        "country_event_consumer":
            "not_mutated",
    },
}

for name,root in roots.items():

    ids=ids_from_dir(root)

    summary[
        "country_storage"
    ][name] = {
        "path":
            str(root),

        "record_count":
            len(ids),

        "config_id_overlap":
            len(
                ids & config_ids
            ),

        "orphan_id_count":
            len(
                ids - config_ids
            ),
    }

Path(
    sys.argv[1]
).write_text(
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
        summary,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# VALIDATE
################################################

echo
echo "========== VALIDATE =========="

test -s "$DISCOVERY" || {
    fail "discovery empty"
    exit 1
}

test -s "$SUMMARY" || {
    fail "summary empty"
    exit 1
}

grep -q \
  'PHASE5_PASS1_DISCOVERY_COMPLETE' \
  "$DISCOVERY" || {
    fail "discovery incomplete"
    exit 1
}

SIZE="$(
    stat -c '%s' \
      "$DISCOVERY"
)"

if [ "$SIZE" -gt $((25 * 1024 * 1024)) ]; then
    fail "discovery exceeded 25MB"
    exit 1
fi

echo "DISCOVERY_SIZE=$SIZE"
echo "DISCOVERY_VALID"
echo "SUMMARY_VALID"

echo
echo "PHASE5_PASS1_SUCCESS"

RESULT="SUCCESS"
