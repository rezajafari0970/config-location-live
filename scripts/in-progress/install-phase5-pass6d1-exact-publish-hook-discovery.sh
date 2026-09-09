#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass6d1-exact-production-publish-hook-discovery"

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
READ ONLY EXACT PUBLISH HOOK DISCOVERY

Production mutation:
NONE

Publish mutation:
NONE

Endpoint mutation:
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
echo " PHASE 5 PASS 6D.1"
echo " EXACT PRODUCTION PUBLISH HOOK DISCOVERY"
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

test -d "$PROJECT/app" || {
    fail "app directory missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 ROUTE STRING SEARCH
################################################

echo
echo "========== [2/12] ROUTE STRING SEARCH =========="

{
echo "================================================"
echo " PHASE 5 PASS 6D.1"
echo " EXACT PRODUCTION PUBLISH HOOK DISCOVERY"
echo "================================================"
echo "TIME=$(date -Is)"

echo
echo "========== A. EXACT /sub/all REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  --include='*.php' \
  --include='*.js' \
  --include='*.html' \
  --include='*.conf' \
  --include='*.service' \
  -F '/sub/all' \
  "$PROJECT" \
  /etc/nginx \
  /etc/systemd/system \
  2>/dev/null \
  | head -n 1200 || true


echo
echo "========== B. /sub/ ROUTES =========="

grep -RnsI \
  --include='*.py' \
  --include='*.php' \
  -E \
  '/sub/|sub/all|sub/\{.*country|country.*sub|@app\.(get|route)|add_api_route|APIRouter|Flask|FastAPI|aiohttp|BaseHTTPRequestHandler' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 2600 || true


################################################
# 3 ROUTER / SERVER SYMBOL MAP
################################################

echo
echo "========== C. ROUTER / SERVER SYMBOL MAP =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

root=Path(os.environ["PROJECT"])/"app"

terms=(
    "sub",
    "country",
    "publish",
    "route",
    "endpoint",
    "http",
    "server",
    "response",
)

for path in sorted(root.rglob("*.py")):

    try:
        tree=ast.parse(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        continue

    rows=[]

    for node in ast.walk(tree):

        if isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
                ast.ClassDef,
            ),
        ):

            low=node.name.lower()

            if any(
                term in low
                for term in terms
            ):
                rows.append(
                    (
                        node.lineno,
                        type(node).__name__,
                        node.name,
                    )
                )

    if rows:
        print()
        print("FILE:",path)

        for line,kind,name in rows:
            print(
                f"{line:5d} "
                f"{kind:18s} "
                f"{name}"
            )
PY


################################################
# 4 DECORATOR ROUTE EXTRACTION
################################################

echo
echo "========== D. DECORATED ROUTES =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

root=Path(os.environ["PROJECT"])/"app"

for path in sorted(root.rglob("*.py")):

    try:
        tree=ast.parse(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        continue

    for node in ast.walk(tree):

        if not isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
            ),
        ):
            continue

        routes=[]

        for dec in node.decorator_list:

            if not isinstance(dec,ast.Call):
                continue

            for arg in dec.args:

                if (
                    isinstance(arg,ast.Constant)
                    and isinstance(arg.value,str)
                    and (
                        "/sub" in arg.value
                        or "country" in arg.value.lower()
                    )
                ):
                    routes.append(
                        arg.value
                    )

        if routes:

            print(
                f"FILE={path}"
            )
            print(
                f"FUNCTION={node.name}"
            )
            print(
                f"LINE={node.lineno}"
            )
            print(
                f"ROUTES={routes}"
            )
            print()
PY


################################################
# 5 HTTP ENTRYPOINTS
################################################

echo
echo "========== E. HTTP ENTRYPOINT FILES =========="

grep -RIl \
  --include='*.py' \
  -E \
  'FastAPI\(|Flask\(|APIRouter\(|aiohttp|HTTPServer|BaseHTTPRequestHandler|uvicorn|gunicorn|serve\(' \
  "$PROJECT/app" \
  2>/dev/null \
  | sort \
  | head -n 200


for FILE in $(
    grep -RIl \
      --include='*.py' \
      -E \
      'FastAPI\(|Flask\(|APIRouter\(|aiohttp|HTTPServer|BaseHTTPRequestHandler|uvicorn|gunicorn|serve\(' \
      "$PROJECT/app" \
      2>/dev/null \
      | sort \
      | head -n 20
); do

    echo
    echo "################################################"
    echo "FILE: $FILE"
    echo "################################################"

    nl -ba "$FILE" \
      | sed -n '1,900p'

done


################################################
# 6 PUBLISH MODULE CONTENT
################################################

echo
echo "========== F. PUBLISH MODULE CONTENT =========="

find "$PROJECT/app/publish" \
  -maxdepth 2 \
  -type f \
  -name '*.py' \
  -print \
  | sort

for FILE in $(
    find "$PROJECT/app/publish" \
      -maxdepth 2 \
      -type f \
      -name '*.py' \
      | sort
); do

    echo
    echo "################################################"
    echo "FILE: $FILE"
    echo "################################################"

    nl -ba "$FILE" \
      | sed -n '1,900p'
done


################################################
# 7 COUNTRY ENDPOINT SEARCH
################################################

echo
echo "========== G. COUNTRY ENDPOINT SEARCH =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'country_code|country_name|country.*endpoint|per.country|countries|country.*path|country.*route|UNKNOWN' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 2600 || true


################################################
# 8 NGINX MAP
################################################

echo
echo "========== H. NGINX ROUTING =========="

nginx -T 2>/dev/null \
  | grep -nE \
  'listen 4040|server_name|location |proxy_pass|fastcgi_pass|sub/all|/sub/' \
  | head -n 1400 || true


################################################
# 9 SYSTEMD MAP
################################################

echo
echo "========== I. SYSTEMD SERVICES =========="

for UNIT in \
  config-location-panel.service \
  config-country-panel.service \
  config-location-country-worker.service \
  config-location-country-event-consumer.service
do

    echo
    echo "--- $UNIT ---"

    systemctl cat \
      "$UNIT" \
      2>/dev/null \
      || true

done


################################################
# 10 LIVE HTTP PROBES
################################################

echo
echo "========== J. LIVE HTTP PROBES =========="

for URL in \
  'http://127.0.0.1:4040/sub/all' \
  'http://127.0.0.1:4040/' \
  'http://127.0.0.1:4040/docs' \
  'http://127.0.0.1:4040/openapi.json'
do

    echo
    echo "URL=$URL"

    curl \
      -sS \
      --max-time 10 \
      -D - \
      -o /tmp/phase5-pass6d1-body.tmp \
      "$URL" \
      2>/dev/null \
      | head -n 30 || true

    echo "BODY_HEAD:"

    head -c 800 \
      /tmp/phase5-pass6d1-body.tmp \
      2>/dev/null || true

    echo
done


################################################
# 11 STACK TRACE BY SOURCE IMPORTS
################################################

echo
echo "========== K. IMPORT / CALL REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'publishable_config_ids|app\.publish|from app\.publish|import app\.publish|render.*sub|subscription|country.*subscription' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 2600 || true


################################################
# 12 CONTRACT QUESTIONS
################################################

echo
echo "========== L. CONTRACT QUESTIONS =========="

cat <<'QUESTIONS'
Q1. Which exact file defines GET /sub/all?
Q2. Which exact function handles GET /sub/all?
Q3. Is /sub/all served by FastAPI/Flask/custom HTTP/nginx/PHP?
Q4. Does /sub/all directly use app.publish.filter?
Q5. Which function converts config IDs into subscription text?
Q6. Which function handles per-country subscriptions?
Q7. Are country endpoints explicit or dynamically generated?
Q8. Is country filtering done before or after serialization?
Q9. Which function receives the requested country code/name?
Q10. Is there one exact per-country hook safe to patch?
Q11. Does the same function also serve /sub/all?
Q12. Can per-country wiring be changed without touching /sub/all?
Q13. Where are remarks/flag/country name injected into output?
Q14. Does Panel HTTP server own both UI and subscription endpoints?
Q15. Is nginx only proxying 4040 or serving files directly?
Q16. What exact module should Phase 5 Pass 6D.2 patch?
Q17. What exact function should be patched?
Q18. What rollback files are required?
Q19. What regression checks preserve /sub/all?
Q20. Is production switch now safe?
QUESTIONS

echo
echo "READ_ONLY=true"
echo "PRODUCTION_MUTATION=false"
echo "PUBLISH_MUTATION=false"
echo "ENDPOINT_MUTATION=false"
echo "SERVICE_RESTART=false"

echo "PHASE5_PASS6D1_DISCOVERY_COMPLETE"

} > "$DISCOVERY"


################################################
# BUILD MACHINE SUMMARY
################################################

echo
echo "========== [11/12] MACHINE SUMMARY =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path

root=Path(os.environ["PROJECT"])/"app"

route_hits=[]
country_hits=[]

for path in sorted(root.rglob("*.py")):

    try:
        source=path.read_text(
            encoding="utf-8",
            errors="replace",
        )
        tree=ast.parse(source)
    except Exception:
        continue

    if "/sub/all" in source:
        route_hits.append(
            {
                "file":str(path),
                "contains_sub_all":True,
            }
        )

    for node in ast.walk(tree):

        if not isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
            ),
        ):
            continue

        decorators=[]

        for dec in node.decorator_list:

            if not isinstance(dec,ast.Call):
                continue

            for arg in dec.args:

                if (
                    isinstance(arg,ast.Constant)
                    and isinstance(arg.value,str)
                ):
                    decorators.append(
                        arg.value
                    )

        if any(
            "/sub" in x
            for x in decorators
        ):
            route_hits.append(
                {
                    "file":str(path),
                    "function":node.name,
                    "line":node.lineno,
                    "routes":decorators,
                }
            )

        low=node.name.lower()

        if (
            "country" in low
            and any(
                x in low
                for x in (
                    "sub",
                    "publish",
                    "config",
                    "get",
                    "list",
                )
            )
        ):
            country_hits.append(
                {
                    "file":str(path),
                    "function":node.name,
                    "line":node.lineno,
                }
            )


summary={
    "phase":
        "phase5-pass6d1-exact-production-publish-hook-discovery",

    "read_only":
        True,

    "sub_route_hits":
        route_hits,

    "country_function_hits":
        country_hits,

    "sub_route_hit_count":
        len(route_hits),

    "country_function_hit_count":
        len(country_hits),

    "production_mutation":
        False,

    "service_restart":
        False,
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
echo "========== [12/12] VALIDATE =========="

test -s "$DISCOVERY" || {
    fail "discovery missing"
    exit 1
}

test -s "$SUMMARY" || {
    fail "summary missing"
    exit 1
}

grep -q \
  'PHASE5_PASS6D1_DISCOVERY_COMPLETE' \
  "$DISCOVERY" || {
    fail "discovery incomplete"
    exit 1
}

echo "DISCOVERY_VALID"
echo "SUMMARY_VALID"

echo
echo "PRODUCTION_MUTATION=NO"
echo "PUBLISH_MUTATION=NO"
echo "ENDPOINT_MUTATION=NO"
echo "SERVICE_RESTART=NO"

echo
echo "PHASE5_PASS6D1_SUCCESS"

RESULT="SUCCESS"
