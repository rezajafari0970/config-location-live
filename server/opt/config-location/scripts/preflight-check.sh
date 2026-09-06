#!/usr/bin/env bash
set -euo pipefail

echo "=== CONFIG LOCATION PREFLIGHT ==="

echo
echo "Python:"
"/opt/config-location/venv/bin/python" --version

echo
echo "Pip:"
"/opt/config-location/venv/bin/python" -m pip --version

echo
echo "Service user:"
id "configloc"

echo
echo "Directories:"
for d in "/opt/config-location" "/etc/config-location" "/var/lib/config-location" "/var/log/config-location" "/var/backups/config-location"
do
    if [[ -d "$d" ]]; then
        echo "[OK] $d"
    else
        echo "[MISSING] $d"
        exit 1
    fi
done

echo
echo "Python imports:"

"/opt/config-location/venv/bin/python" - <<'PY'
modules = [
    "aiohttp",
    "httpx",
    "anyio",
    "uvloop",
    "orjson",
    "pydantic",
    "psutil",
    "dns",
    "dateutil",
    "filelock"
]

for module in modules:
    __import__(module)
    print("[OK]", module)

print()
print("All Python dependencies loaded successfully.")
PY

echo
echo "=== PREFLIGHT PASSED ==="
