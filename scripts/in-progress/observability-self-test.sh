#!/usr/bin/env bash
set -Eeuo pipefail

echo "OBSERVABILITY_SELF_TEST_RUNNING"

test -d /opt/config-location
test -d /root/config-location-live-git

echo "OBSERVABILITY_SELF_TEST_OK"
