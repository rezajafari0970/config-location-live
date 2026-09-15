#!/usr/bin/env bash
set -Eeuo pipefail

echo "======================================================"
echo "XRAY_RETENTION_SOURCE_DUMP"
echo "======================================================"

echo
echo "=== SANDBOX.PY FULL ==="
cat /opt/config-location/app/health/runtime/sandbox.py

echo
echo "=== LAUNCHER.PY FULL ==="
cat /opt/config-location/app/health/runtime/launcher.py

echo
echo "======================================================"
echo "XRAY_RETENTION_SOURCE_DUMP=PASS"
echo "======================================================"
