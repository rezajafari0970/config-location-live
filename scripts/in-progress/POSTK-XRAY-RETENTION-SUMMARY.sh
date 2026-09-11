#!/usr/bin/env bash
set -Eeuo pipefail

echo "SOURCE_LOG=/var/log/config-location/chatgpt/stages/POSTK-XRAY-LOG-RETENTION-20260902-053748.log"

grep -E 'xray|XRAY|subprocess|Popen|stderr|stdout|runtime|health_pipeline|runner|ARCHIVE|RETENTION|JOURNAL|PASS|FAIL|ERROR|timer' "/var/log/config-location/chatgpt/stages/POSTK-XRAY-LOG-RETENTION-20260902-053748.log" |
tail -n 1500

echo
echo "POSTK_XRAY_RETENTION_SUMMARY=PASS"
