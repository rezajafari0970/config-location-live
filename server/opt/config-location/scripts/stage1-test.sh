#!/usr/bin/env bash

set -euo pipefail

echo
echo "======================================"
echo " CONFIG LOCATION - STAGE 1 TEST"
echo "======================================"

echo
echo "[1] Python syntax..."

find /opt/config-location/app \
    -name '*.py' \
    -print0 |
xargs -0 \
    /opt/config-location/venv/bin/python \
    -m py_compile

echo "[OK] Python syntax"


echo
echo "[2] Service status..."

systemctl is-active \
    --quiet config-location-panel.service

echo "[OK] Panel service active"


echo
echo "[3] Port 4040..."

ss -lnt | grep -q ':4040 '

echo "[OK] Port 4040 listening"


echo
echo "[4] Public health endpoint..."

HEALTH="$(
    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 5 \
        http://127.0.0.1:4040/health
)"

echo "$HEALTH" | jq .

echo "$HEALTH" |
jq -e '.status == "ok"' >/dev/null

echo "[OK] Health endpoint"


echo
echo "[5] Source manager..."

sudo -u configloc \
    /opt/config-location/venv/bin/python \
    - <<'PY'
import sys

sys.path.insert(
    0,
    "/opt/config-location"
)

from app.core.source_manager import stats

result = stats()

assert isinstance(result, dict)
assert "total" in result

print(result)
PY

echo "[OK] Source manager"


echo
echo "======================================"
echo " STAGE 1 TEST PASSED"
echo "======================================"
