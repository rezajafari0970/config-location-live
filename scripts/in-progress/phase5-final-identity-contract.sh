#!/usr/bin/env bash
set -Eeu -o pipefail

PROJECT="/opt/config-location"

IDENTITY_PY="$PROJECT/app/country/country_identity.py"
IDENTITY_ROOT="/var/lib/config-location/country/country-identity"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/3245/phase5-identity-contract-$TS"

mkdir -p "$BACKUP"

echo "========== PRECHECK =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/country_identity.py

echo "BASELINE_COMPILE_OK"

cp -a \
  "$IDENTITY_PY" \
  "$BACKUP/country_identity.py.before"

echo "BACKUP=$BACKUP"


echo
echo "========== PATCH IDENTITY WRITER =========="

"$PROJECT/venv/bin/python" \
- "$IDENTITY_PY" <<'PY'
import ast
import sys
from pathlib import Path

path = Path(sys.argv[1])

source = path.read_text(
    encoding="utf-8"
)

tree = ast.parse(source)

patched = 0


for fn in ast.walk(tree):

    if not isinstance(
        fn,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):
        continue

    if "_CONFIGLOC_IDENTITY_GID" in ast.unparse(fn):
        continue


    for index, stmt in enumerate(
        list(fn.body)
    ):

        if not isinstance(
            stmt,
            ast.Try,
        ):
            continue


        for inner_index, inner in enumerate(
            list(stmt.body)
        ):

            if not isinstance(
                inner,
                ast.Assign,
            ):
                continue

            call = inner.value

            if not (
                isinstance(call, ast.Call)
                and isinstance(call.func, ast.Attribute)
                and isinstance(call.func.value, ast.Name)
                and call.func.value.id == "os"
                and call.func.attr == "open"
            ):
                continue


            # Confirm the os.open call contains mode 0o600.
            has_600 = any(
                isinstance(arg, ast.Constant)
                and arg.value == 0o600
                for arg in call.args
            )

            if not has_600:
                continue


            if not (
                inner.targets
                and isinstance(
                    inner.targets[0],
                    ast.Name,
                )
            ):
                continue

            fd_name = inner.targets[0].id


            extra = ast.parse(
                f'''
_CONFIGLOC_IDENTITY_GID = __import__("grp").getgrnam("configloc").gr_gid
os.fchown({fd_name}, -1, _CONFIGLOC_IDENTITY_GID)
os.fchmod({fd_name}, 0o640)
'''
            ).body


            for offset, node in enumerate(
                extra,
                start=1,
            ):

                stmt.body.insert(
                    inner_index + offset,
                    node,
                )


            patched += 1
            break


        if patched:
            break


if patched != 1:

    raise SystemExit(
        f"EXPECTED_ONE_IDENTITY_WRITER:"
        f"patched={patched}"
    )


ast.fix_missing_locations(tree)

result = ast.unparse(tree) + "\n"

check = ast.parse(result)

# Preserve future import position.
if not (
    check.body
    and isinstance(
        check.body[0],
        ast.ImportFrom,
    )
    and check.body[0].module
    == "__future__"
):

    raise SystemExit(
        "FUTURE_IMPORT_POSITION_INVALID"
    )


path.write_text(
    result,
    encoding="utf-8",
)


print(
    "IDENTITY_WRITER_PATCHED=YES"
)
PY


echo
echo "========== COMPILE =========="

if ! PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/country_identity.py
then

    cp -a \
      "$BACKUP/country_identity.py.before" \
      "$IDENTITY_PY"

    echo "ROLLBACK_DONE"
    exit 1
fi


grep -nE \
'_CONFIGLOC_IDENTITY_GID|fchown|fchmod' \
"$IDENTITY_PY"

echo "PATCH_COMPILE_OK"


echo
echo "========== RECONCILE EXISTING IDENTITY FILES =========="

GROUP="$(id -gn configloc)"

find "$IDENTITY_ROOT" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  -exec chgrp "$GROUP" {} +

find "$IDENTITY_ROOT" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  -exec chmod 0640 {} +

echo "EXISTING_IDENTITY_FILES_RECONCILED=YES"


echo
echo "========== CONFIGLOC READ CHECK =========="

TOTAL=0
BAD=0

while IFS= read -r FILE; do

    [ -n "$FILE" ] || continue

    TOTAL=$((TOTAL+1))

    if ! sudo -u configloc test -r "$FILE"; then
        echo "UNREADABLE=$FILE"
        BAD=$((BAD+1))
    fi

done < <(
    find "$IDENTITY_ROOT" \
      -maxdepth 1 \
      -type f \
      -name '*.json' \
      -print
)

echo "IDENTITY_FILES=$TOTAL"
echo "UNREADABLE_IDENTITY_FILES=$BAD"

[ "$BAD" -eq 0 ]

echo "IDENTITY_READ_CONTRACT=PASS"


echo
echo "========== RESTART COUNTRY SERVICES =========="

systemctl restart \
  config-location-country-worker.service

systemctl restart \
  config-location-country-event-consumer.service

systemctl restart \
  config-location-panel.service

sleep 5

for UNIT in \
  config-location-country-worker.service \
  config-location-country-event-consumer.service \
  config-location-panel.service
do

    ACTIVE="$(
        systemctl is-active \
          "$UNIT" \
          2>/dev/null || true
    )"

    echo "$UNIT=$ACTIVE"

    [ "$ACTIVE" = "active" ]
done

echo "SERVICES_OK"


echo
echo "========== ROOT / CONFIGLOC COUNTRY PARITY =========="

ROOT_JSON="/tmp/phase5-id-root.json"
USER_JSON="/tmp/phase5-id-user.json"

cat > /tmp/phase5-id-parity.py <<'PY'
import json
import sys

from collections import Counter

from app.publish.filter import (
    build_publish_snapshot,
)

from app.country.projection import (
    build_projection,
)


snapshot = build_publish_snapshot()
projection = build_projection()

ids = {
    str(x["id"])
    for x in snapshot.configs
    if isinstance(x, dict)
    and x.get("id")
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

    code = row.get(
        "country_code"
    )

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


json.dump(
    {
        "publishable":
            snapshot.publishable,

        "unknown":
            unknown,

        "conflict":
            conflict,

        "countries":
            dict(
                sorted(
                    counts.items()
                )
            ),
    },
    open(
        sys.argv[1],
        "w",
        encoding="utf-8",
    ),
    ensure_ascii=False,
    sort_keys=True,
)
PY


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
/tmp/phase5-id-parity.py \
"$ROOT_JSON"


sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
/tmp/phase5-id-parity.py \
"$USER_JSON"


"$PROJECT/venv/bin/python" \
- "$ROOT_JSON" "$USER_JSON" <<'PY'
import json
import sys

root = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

user = json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)

print(
    "ROOT=",
    root,
)

print(
    "CONFIGLOC=",
    user,
)

if root != user:

    raise SystemExit(
        "ROOT_CONFIGLOC_PARITY_FAILED"
    )

print(
    "ROOT_CONFIGLOC_PARITY=PASS"
)
PY


echo
echo "========== ENDPOINT CHECK =========="

for C in DE KR NL GB US AU; do

    printf '%s ' "$C"

    curl \
      -sS \
      --max-time 20 \
      -D - \
      -o /dev/null \
      "http://127.0.0.1:4040/sub/country/$C" \
    | awk -F': ' '
      BEGIN {IGNORECASE=1}
      /^X-Config-Country-Count:/ {
        gsub("\r","",$2)
        print $2
      }
    '

done


ALL_HTTP="$(
curl \
  -sS \
  --max-time 20 \
  -o /tmp/phase5-id-all \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all
)"

INVALID_HTTP="$(
curl \
  -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/INVALID \
  || true
)"


echo "SUB_ALL_HTTP=$ALL_HTTP"
echo "INVALID_HTTP=$INVALID_HTTP"

[ "$ALL_HTTP" = "200" ]
[ "$INVALID_HTTP" = "404" ]


echo
echo "COUNTRY_IDENTITY_WRITER_CONTRACT=PASS"
echo "IDENTITY_FILE_MODE=0640"
echo "CONFIGLOC_IDENTITY_READ=YES"

echo "ROOT_CONFIGLOC_PARITY=PASS"
echo "SUB_ALL_REGRESSION=PASS"
echo "INVALID_COUNTRY_FAIL_CLOSED=PASS"

echo
echo "READY_FOR_PHASE5_FINAL_CLOSURE=YES"
echo
echo "PHASE5_FINAL_IDENTITY_CONTRACT_SUCCESS"
