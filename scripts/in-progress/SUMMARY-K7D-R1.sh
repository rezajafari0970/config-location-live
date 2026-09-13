#!/usr/bin/env bash
set -Eeuo pipefail

echo "SOURCE_LOG=/var/log/config-location/chatgpt/stages/FIX22K7D-R1-CANONICAL-STORE-DIAG-RESULT-20260901-165741.log"

grep -E 'FUNCTION=|ROOT=|TOTAL=|STATES=|COUNTRY_KNOWN=|COUNTRY_MISSING=|HARD_UNRESOLVED=|CONFIG_ID=|pipeline/latest|country/latest|country/results|save_country_result|FIX22K7D_R1_DIAG=' "/var/log/config-location/chatgpt/stages/FIX22K7D-R1-CANONICAL-STORE-DIAG-RESULT-20260901-165741.log" | tail -n 1200

echo "K7D_R1_SUMMARY=PASS"
