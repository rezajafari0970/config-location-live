#!/usr/bin/env bash
set -Eeuo pipefail

STAGE="HT17-FINAL"
PROJECT="/opt/config-location"
SERVER="$PROJECT/app/panel/server.py"
ADAPTIVE="$PROJECT/app/health/panel_adaptive.py"

BACKUP_ROOT="/root/config-location-stage-backups"
TS="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/$STAGE-$TS"

LOG_DIR="/var/log/config-location/chatgpt/stages"
LOG="$LOG_DIR/$STAGE-$TS.log"

mkdir -p "$BACKUP" "$LOG_DIR"

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo " CONFIG_LOCATION_DEVLOG"
echo " STAGE=$STAGE"
echo " START=$(date -u --iso-8601=seconds)"
echo "============================================================"

echo
echo "===== 1. PRECHECK ====="

test -f "$SERVER"
test -f "$ADAPTIVE"

echo "[PASS] server.py exists"
echo "[PASS] panel_adaptive.py exists"

echo
echo "===== 2. BACKUP ====="

cp -a "$SERVER" "$BACKUP/server.py"
cp -a "$ADAPTIVE" "$BACKUP/panel_adaptive.py"

echo "BACKUP=$BACKUP"
echo "[PASS] Backup created"

echo
echo "===== 3. PATCH SERVER ====="

python3 - "$SERVER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])

text = path.read_text(
    encoding="utf-8"
)

original = text

IMPORT_LINE = (
    "from app.health.panel_adaptive import "
    "install_aiohttp_routes"
)

# ---------------------------------------------------------
# 1. Import integration
# ---------------------------------------------------------

if IMPORT_LINE not in text:

    anchor = (
        "from app.devlog.endpoint "
        "import devlog_handler"
    )

    if anchor not in text:
        raise SystemExit(
            "[FAIL] devlog import anchor not found"
        )

    text = text.replace(
        anchor,
        anchor
        + "\n\n"
        + IMPORT_LINE,
        1,
    )

# ---------------------------------------------------------
# 2. Locate create_app
# ---------------------------------------------------------

lines = text.splitlines()

create_index = None
main_index = None

for i, line in enumerate(lines):

    if line.strip() == "def create_app():":
        create_index = i
        continue

    if (
        create_index is not None
        and line.startswith(
            'if __name__ == "__main__":'
        )
    ):
        main_index = i
        break


if create_index is None:
    raise SystemExit(
        "[FAIL] create_app() not found"
    )

if main_index is None:
    main_index = len(lines)

# ---------------------------------------------------------
# 3. Fix return app indentation if needed
# ---------------------------------------------------------

return_indexes = []

for i in range(
    create_index + 1,
    main_index,
):

    if lines[i].strip() == "return app":

        lines[i] = "    return app"

        return_indexes.append(i)


if not return_indexes:
    raise SystemExit(
        "[FAIL] return app not found"
    )

# Use final return app belonging to create_app.
return_index = return_indexes[-1]

# ---------------------------------------------------------
# 4. Remove previous installer calls from create_app section
#    to guarantee exactly one installation.
# ---------------------------------------------------------

cleaned = []

for i, line in enumerate(lines):

    if (
        create_index < i < main_index
        and
        line.strip()
        == "install_aiohttp_routes(app)"
    ):
        continue

    cleaned.append(line)

lines = cleaned

# Recalculate indexes after cleanup.
create_index = None
main_index = None
return_index = None

for i, line in enumerate(lines):

    if line.strip() == "def create_app():":
        create_index = i
        continue

    if (
        create_index is not None
        and line.startswith(
            'if __name__ == "__main__":'
        )
    ):
        main_index = i
        break

if main_index is None:
    main_index = len(lines)

for i in range(
    create_index + 1,
    main_index,
):

    if lines[i].strip() == "return app":
        return_index = i


if return_index is None:
    raise SystemExit(
        "[FAIL] return app disappeared"
    )

# ---------------------------------------------------------
# 5. Install Adaptive routes immediately before return app
# ---------------------------------------------------------

block = [
    "",
    "    # ============================================",
    "    # HT17 - Adaptive Health Panel Integration",
    "    # ============================================",
    "",
    "    install_aiohttp_routes(",
    "        app",
    "    )",
    "",
]

lines[
    return_index:return_index
] = block

text = "\n".join(lines) + "\n"

path.write_text(
    text,
    encoding="utf-8",
)

print(
    "[PASS] Adaptive import installed"
)

print(
    "[PASS] install_aiohttp_routes(app) integrated"
)

print(
    "[PASS] return app normalized"
)

print(
    "[PASS] server.py patched"
)
PY

echo
echo "===== 4. COMPILE ====="

cd "$PROJECT"

"$PROJECT/venv/bin/python" \
    -m py_compile \
    app/panel/server.py \
    app/health/panel_adaptive.py

echo "[PASS] Python compile"

echo
echo "===== 5. IMPORT TEST ====="

"$PROJECT/venv/bin/python" <<'PY'
from app.panel.server import create_app

app = create_app()

print("[PASS] create_app() executed")

routes = []

for route in app.router.routes():

    try:
        method = route.method
    except Exception:
        method = "?"

    try:
        resource = route.resource.canonical
    except Exception:
        resource = str(route.resource)

    routes.append(
        (
            method,
            resource,
        )
    )


required = {
    (
        "GET",
        "/api/health/adaptive",
    ),

    (
        "POST",
        "/api/health/adaptive",
    ),

    (
        "GET",
        "/health/adaptive",
    ),
}


actual = set(routes)

missing = (
    required
    - actual
)

if missing:

    print(
        "ROUTES:"
    )

    for method, path in sorted(
        routes
    ):
        print(
            method,
            path,
        )

    raise SystemExit(
        "[FAIL] Missing adaptive routes: "
        + repr(
            sorted(
                missing
            )
        )
    )


print(
    "[PASS] GET /api/health/adaptive"
)

print(
    "[PASS] POST /api/health/adaptive"
)

print(
    "[PASS] GET /health/adaptive"
)


count_api_get = sum(
    1
    for method, path in routes
    if (
        method == "GET"
        and
        path
        == "/api/health/adaptive"
    )
)

count_api_post = sum(
    1
    for method, path in routes
    if (
        method == "POST"
        and
        path
        == "/api/health/adaptive"
    )
)

count_page = sum(
    1
    for method, path in routes
    if (
        method == "GET"
        and
        path
        == "/health/adaptive"
    )
)


if (
    count_api_get != 1
    or count_api_post != 1
    or count_page != 1
):

    raise SystemExit(
        "[FAIL] Duplicate adaptive routes"
    )


print(
    "[PASS] No duplicate adaptive routes"
)

print(
    "[PASS] HT17 application integration"
)
PY

echo
echo "===== 6. SHOW INTEGRATION ====="

grep -n \
    -E \
    'panel_adaptive|install_aiohttp_routes|return app' \
    "$SERVER" \
    | tail -n 20

echo
echo "===== 7. RESTART PANEL ONLY ====="

systemctl restart \
    config-location-panel.service

sleep 2

if ! systemctl is-active \
    --quiet \
    config-location-panel.service
then

    echo "[FAIL] Panel did not restart"

    echo
    echo "===== PANEL STATUS ====="

    systemctl status \
        config-location-panel.service \
        --no-pager \
        -l \
        || true

    echo
    echo "===== ROLLBACK ====="

    cp -a \
        "$BACKUP/server.py" \
        "$SERVER"

    systemctl restart \
        config-location-panel.service \
        || true

    echo "[ROLLBACK] Original server.py restored"

    exit 1
fi

echo "[PASS] Panel service active"

echo
echo "===== 8. PORT CHECK ====="

if ss -lntp \
    | grep -q \
    ':4040[[:space:]]'
then
    echo "[PASS] Port 4040 listening"
else
    echo "[FAIL] Port 4040 not listening"
    exit 1
fi

echo
echo "===== 9. PANEL HEALTH ====="

HEALTH="$(
    curl \
        -fsS \
        --max-time 5 \
        http://127.0.0.1:4040/health
)"

echo "$HEALTH"

python3 - "$HEALTH" <<'PY'
import json
import sys

obj = json.loads(
    sys.argv[1]
)

assert obj.get(
    "status"
) == "ok"

assert obj.get(
    "project"
) == "config-location"

print(
    "[PASS] Panel health endpoint"
)
PY

echo
echo "===== 10. AUTH PROTECTION TEST ====="

CODE="$(
    curl \
        -sS \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 5 \
        http://127.0.0.1:4040/api/health/adaptive
)"

echo "HTTP_CODE=$CODE"

if [ "$CODE" = "302" ]; then
    echo "[PASS] Adaptive API protected by panel authentication"
else
    echo "[FAIL] Expected unauthenticated HTTP 302, got $CODE"
    exit 1
fi

echo
echo "===== 11. SERVICE ISOLATION CHECK ====="

for SERVICE in \
    config-location-panel.service \
    config-location-fetcher.service \
    config-location-health-adaptive.service
do

    STATE="$(
        systemctl is-active \
        "$SERVICE" \
        2>/dev/null \
        || true
    )"

    echo "$SERVICE=$STATE"

done

test "$(
    systemctl is-active \
    config-location-fetcher.service
)" = "active"

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = "active"

echo "[PASS] Fetcher unaffected"
echo "[PASS] Adaptive daemon unaffected"

echo
echo "===== 12. ADAPTIVE RUNTIME STATE ====="

python3 <<'PY'
import json
from pathlib import Path

paths = {
    "daemon":
        Path(
            "/var/lib/config-location/"
            "health-adaptive/"
            "daemon-status.json"
        ),

    "effective":
        Path(
            "/var/lib/config-location/"
            "health-adaptive/"
            "effective-runtime.json"
        ),
}

for name, path in paths.items():

    if not path.exists():

        raise SystemExit(
            f"[FAIL] Missing {path}"
        )

    obj = json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    print(
        f"{name.upper()}={json.dumps(obj, ensure_ascii=False)}"
    )


print(
    "[PASS] Adaptive runtime files readable"
)
PY

echo
echo "============================================================"
echo " HT17-FINAL PASS"
echo "============================================================"
echo "ADAPTIVE_PANEL=/health/adaptive"
echo "ADAPTIVE_API=/api/health/adaptive"
echo "PANEL_PORT=4040"
echo "PANEL_AUTH=ENFORCED"
echo "HOT_POLICY_RELOAD=AVAILABLE"
echo "BACKUP=$BACKUP"
echo "LOG=$LOG"
echo "END=$(date -u --iso-8601=seconds)"
echo "============================================================"
