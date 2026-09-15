#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass6d2-exact-suball-percountry-callgraph-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"

HTTP="$PROJECT/app/publish/http.py"
READMODEL="$PROJECT/app/panel/publish_read_model.py"

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
READ ONLY EXACT CALL-GRAPH CONTRACT

Production mutation:
NONE

Publish mutation:
NONE

Panel mutation:
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
echo " PHASE 5 PASS 6D.2"
echo " EXACT /sub/all + PER-COUNTRY CALL GRAPH"
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

test -f "$HTTP" || {
    fail "app/publish/http.py missing"
    exit 1
}

test -f "$READMODEL" || {
    fail "app/panel/publish_read_model.py missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 COMPILE
################################################

echo
echo "========== [2/10] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/publish/http.py \
  app/panel/publish_read_model.py \
  app/publish/filter.py \
  app/country/production_publish_projection.py \
  app/country/projection.py

echo "COMPILE_OK"


################################################
# 3 FULL FOCUSED SOURCE
################################################

echo
echo "========== [3/10] SOURCE CAPTURE =========="

{
echo "================================================"
echo " PHASE 5 PASS 6D.2"
echo " EXACT CALL-GRAPH CONTRACT"
echo "================================================"

echo "TIME=$(date -Is)"

echo
echo "################################################"
echo "FILE: $HTTP"
echo "################################################"

nl -ba "$HTTP" \
  | sed -n '1,1400p'

echo
echo "################################################"
echo "FILE: $READMODEL"
echo "################################################"

nl -ba "$READMODEL" \
  | sed -n '1,1400p'


################################################
# 4 ROUTE REFERENCES
################################################

echo
echo "========== ROUTE REFERENCES =========="

grep -nE \
  '/sub/all|/sub/|country|subscription|publish|Response|PlainText|Streaming|request|path' \
  "$HTTP" \
  "$READMODEL" \
  2>/dev/null || true


################################################
# 5 IMPORT MAP
################################################

echo
echo "========== IMPORT MAP =========="

grep -nE \
  '^(from|import) ' \
  "$HTTP" \
  "$READMODEL" \
  2>/dev/null || true


################################################
# 6 CROSS REFERENCES
################################################

echo
echo "========== CROSS REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'publish_read_model|app\.publish\.http|from app\.publish\.http|from app\.panel\.publish_read_model' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 1800 || true


echo
echo "========== SERIALIZER REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'serialize|render|subscription|encode|base64|text/plain|PlainTextResponse|Response\(|config.*text|join\(' \
  "$PROJECT/app/publish" \
  "$PROJECT/app/panel/publish_read_model.py" \
  2>/dev/null \
  | head -n 2000 || true


echo
echo "========== FILTER REFERENCES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'publishable_config_ids|publishable|country_code|country_name|filter|config_ids|ids =' \
  "$PROJECT/app/publish" \
  "$PROJECT/app/panel/publish_read_model.py" \
  2>/dev/null \
  | head -n 2200 || true


################################################
# 7 LIVE ROUTE BASELINE
################################################

echo
echo "========== LIVE /sub/all BASELINE =========="

curl \
  -sS \
  --max-time 15 \
  -o /tmp/phase5-pass6d2-sub-all.txt \
  -w 'HTTP=%{http_code} SIZE=%{size_download}\n' \
  http://127.0.0.1:4040/sub/all \
  || true

echo "SHA256=$(
sha256sum \
  /tmp/phase5-pass6d2-sub-all.txt \
  2>/dev/null \
  | awk '{print $1}'
)"


################################################
# 8 SYSTEMD ENTRYPOINT
################################################

echo
echo "========== PANEL SERVICE =========="

systemctl cat \
  config-location-panel.service \
  2>/dev/null || true


echo
echo "========== LISTENER =========="

ss -lntp \
  | grep -E ':4040[[:space:]]' \
  || true


################################################
# 9 CONTRACT QUESTIONS
################################################

echo
echo "========== CONTRACT QUESTIONS =========="

cat <<'QUESTIONS'
Q1. What exact function receives GET /sub/all?
Q2. What exact function receives per-country requests?
Q3. Is routing explicit or path-parsed dynamically?
Q4. Does /sub/all and per-country share one handler?
Q5. Which line distinguishes all vs country?
Q6. What exact read-model function is called by /sub/all?
Q7. What exact read-model function is called for country?
Q8. Where are publishable config IDs obtained?
Q9. Where is country filtering currently performed?
Q10. Does current filtering use Config Store country metadata?
Q11. Where should Canonical Projection v2 enter the call graph?
Q12. Can that insertion affect only country requests?
Q13. What function serializes configs into subscription text?
Q14. Is serialization shared by /sub/all and country?
Q15. What object/collection exists immediately before serialization?
Q16. Does filtering happen before serialization?
Q17. Is UNKNOWN currently a country endpoint/group?
Q18. What exact file needs modification in 6D.3?
Q19. What exact function needs modification in 6D.3?
Q20. Can /sub/all remain byte/logically unchanged?
Q21. Which service must restart after patch?
Q22. Which files must be backed up?
Q23. What HTTP checks prove /sub/all preservation?
Q24. What country endpoint should be used as production canary?
Q25. Is there exactly one safe production insertion point?
QUESTIONS

echo
echo "READ_ONLY=true"
echo "PRODUCTION_MUTATION=false"
echo "PUBLISH_MUTATION=false"
echo "PANEL_MUTATION=false"
echo "ENDPOINT_MUTATION=false"
echo "SERVICE_RESTART=false"

echo "PHASE5_PASS6D2_DISCOVERY_COMPLETE"

} > "$DISCOVERY"


################################################
# 4 AST CALL GRAPH
################################################

echo
echo "========== [4/10] AST CALL GRAPH =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path


project=Path(
    os.environ["PROJECT"]
)

files=[
    project/"app/publish/http.py",
    project/"app/panel/publish_read_model.py",
]


def expr_name(node):

    if isinstance(node,ast.Name):
        return node.id

    if isinstance(node,ast.Attribute):

        left=expr_name(
            node.value
        )

        if left:
            return (
                left
                + "."
                + node.attr
            )

        return node.attr

    return None


def const_strings(node):

    rows=[]

    for child in ast.walk(node):

        if (
            isinstance(
                child,
                ast.Constant,
            )
            and isinstance(
                child.value,
                str,
            )
        ):
            rows.append(
                child.value
            )

    return rows


result={
    "phase":
        "phase5-pass6d2-exact-suball-percountry-callgraph-contract",

    "read_only":
        True,

    "files":{},

    "route_candidates":[],

    "sub_all_candidates":[],

    "country_candidates":[],

    "cross_file_calls":[],

    "production_mutation":
        False,

    "service_restart":
        False,
}


all_functions=set()


for path in files:

    source=path.read_text(
        encoding="utf-8",
        errors="replace",
    )

    tree=ast.parse(
        source
    )

    file_data={
        "functions":[],
        "imports":[],
    }


    for node in tree.body:

        if isinstance(
            node,
            ast.ImportFrom,
        ):

            file_data[
                "imports"
            ].append(
                {
                    "module":
                        node.module,

                    "names":[
                        x.name
                        for x in node.names
                    ],
                }
            )


        elif isinstance(
            node,
            ast.Import,
        ):

            file_data[
                "imports"
            ].append(
                {
                    "module":
                        None,

                    "names":[
                        x.name
                        for x in node.names
                    ],
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

        all_functions.add(
            node.name
        )

        calls=[]

        for sub in ast.walk(node):

            if isinstance(
                sub,
                ast.Call,
            ):

                name=expr_name(
                    sub.func
                )

                if name:
                    calls.append(
                        {
                            "name":
                                name,

                            "line":
                                getattr(
                                    sub,
                                    "lineno",
                                    None,
                                ),

                            "string_args":
                                [
                                    x.value
                                    for x
                                    in sub.args
                                    if (
                                        isinstance(
                                            x,
                                            ast.Constant,
                                        )
                                        and isinstance(
                                            x.value,
                                            str,
                                        )
                                    )
                                ],
                        }
                    )


        strings=const_strings(
            node
        )

        row={
            "name":
                node.name,

            "line":
                node.lineno,

            "args":[
                x.arg
                for x
                in node.args.args
            ],

            "calls":
                calls,

            "strings":
                strings[:80],
        }

        file_data[
            "functions"
        ].append(
            row
        )


        joined=" ".join(
            strings
        ).lower()

        if (
            "/sub/" in joined
            or "/sub/all" in joined
            or "country" in joined
        ):

            result[
                "route_candidates"
            ].append(
                {
                    "file":
                        str(path),

                    "function":
                        node.name,

                    "line":
                        node.lineno,

                    "strings":
                        strings[:40],
                }
            )


        if (
            "/sub/all"
            in joined
        ):

            result[
                "sub_all_candidates"
            ].append(
                {
                    "file":
                        str(path),

                    "function":
                        node.name,

                    "line":
                        node.lineno,
                }
            )


        low=node.name.lower()

        if (
            "country" in low
            or any(
                "country"
                in x.lower()
                for x in strings
            )
        ):

            result[
                "country_candidates"
            ].append(
                {
                    "file":
                        str(path),

                    "function":
                        node.name,

                    "line":
                        node.lineno,
                }
            )


    result[
        "files"
    ][
        str(path)
    ]=file_data


# Find calls between functions in the
# two focused modules.
for path,data in result[
    "files"
].items():

    for fn in data[
        "functions"
    ]:

        for call in fn[
            "calls"
        ]:

            tail=(
                call["name"]
                .split(".")[-1]
            )

            if tail in all_functions:

                result[
                    "cross_file_calls"
                ].append(
                    {
                        "from_file":
                            path,

                        "from_function":
                            fn["name"],

                        "to_function":
                            tail,

                        "line":
                            call["line"],
                    }
                )


Path(
    sys.argv[1]
).write_text(
    json.dumps(
        result,
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)


print(
    json.dumps(
        {
            "sub_all_candidates":
                result[
                    "sub_all_candidates"
                ],

            "country_candidates":
                result[
                    "country_candidates"
                ],

            "cross_file_calls":
                result[
                    "cross_file_calls"
                ],
        },
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 5 FUNCTION BODY SUMMARY
################################################

echo
echo "========== [5/10] FUNCTION SUMMARY =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

project=Path(
    os.environ["PROJECT"]
)

for rel in (
    "app/publish/http.py",
    "app/panel/publish_read_model.py",
):

    path=project/rel

    tree=ast.parse(
        path.read_text(
            encoding="utf-8",
            errors="replace",
        )
    )

    print()
    print(
        "################################################"
    )
    print("FILE:",path)
    print(
        "################################################"
    )

    for node in tree.body:

        if isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
            ),
        ):

            print(
                f"{node.lineno:5d}-"
                f"{getattr(node,'end_lineno',node.lineno):5d} "
                f"{node.name}("
                + ",".join(
                    x.arg
                    for x
                    in node.args.args
                )
                + ")"
            )
PY


################################################
# 6 DIRECT CALL GRAPH GREP
################################################

echo
echo "========== [6/10] DIRECT CALL GRAPH =========="

grep -nE \
  'publish_read_model|publishable_config_ids|subscription|country|sub_all|sub/all|render|serialize|config_ids|return ' \
  "$HTTP" \
  "$READMODEL" \
  2>/dev/null || true


################################################
# 7 LIVE REGRESSION BASELINE
################################################

echo
echo "========== [7/10] LIVE REGRESSION BASELINE =========="

OUT="/tmp/phase5-pass6d2-suball.txt"

HTTP_CODE="$(
curl \
  -sS \
  --max-time 15 \
  -o "$OUT" \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  || true
)"

echo "HTTP_CODE=$HTTP_CODE"

[ "$HTTP_CODE" = "200" ] || {
    fail "/sub/all is not healthy"
    exit 1
}

echo "SIZE=$(stat -c '%s' "$OUT")"
echo "SHA256=$(sha256sum "$OUT" | awk '{print $1}')"

echo "SUB_ALL_BASELINE_OK"


################################################
# 8 SERVICES
################################################

echo
echo "========== [8/10] SERVICES =========="

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

echo "SERVICE_BASELINE_OK"


################################################
# 9 VALIDATE DISCOVERY
################################################

echo
echo "========== [9/10] VALIDATE =========="

test -s "$DISCOVERY" || {
    fail "discovery missing"
    exit 1
}

test -s "$SUMMARY" || {
    fail "summary missing"
    exit 1
}

grep -q \
  'PHASE5_PASS6D2_DISCOVERY_COMPLETE' \
  "$DISCOVERY" || {
    fail "discovery incomplete"
    exit 1
}

"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert d["read_only"] is True
assert d["production_mutation"] is False
assert d["service_restart"] is False

assert len(
    d["files"]
) == 2

print(
    "CALL_GRAPH_SUMMARY_VALID"
)

print(
    "SUB_ALL_CANDIDATE_COUNT=",
    len(
        d[
            "sub_all_candidates"
        ]
    ),
)

print(
    "COUNTRY_CANDIDATE_COUNT=",
    len(
        d[
            "country_candidates"
        ]
    ),
)

print(
    "CROSS_FILE_CALL_COUNT=",
    len(
        d[
            "cross_file_calls"
        ]
    ),
)
PY

echo "DISCOVERY_VALID"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "EXACT_SOURCE_CAPTURED=YES"
echo "AST_CALL_GRAPH_CAPTURED=YES"
echo "SUB_ALL_BASELINE=HEALTHY"
echo "SERVICE_BASELINE=HEALTHY"

echo "PRODUCTION_MUTATION=NO"
echo "PUBLISH_MUTATION=NO"
echo "PANEL_MUTATION=NO"
echo "ENDPOINT_MUTATION=NO"
echo "SERVICE_RESTART=NO"

echo
echo "PHASE5_PASS6D2_SUCCESS"

RESULT="SUCCESS"
