#!/usr/bin/env bash
set -Eeuo pipefail

SRC="/root/phase5-post-closure-hardening-v2.sh"
TMP="/tmp/phase5-hardening-v2-preflight-$$"
P="$TMP/config-location"
R="$TMP/project-log"
SCRIPT="$TMP/hardening-preflight.sh"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "=============================================="
echo " PHASE 5 HARDENING V2 — SAFE PREFLIGHT"
echo "=============================================="

test -f "$SRC"

mkdir -p \
  "$P/app/country" \
  "$P/app/panel" \
  "$P/app/publish" \
  "$P/venv/bin" \
  "$R"

echo
echo "========== [1/6] COPY BASELINE =========="

cp -a /opt/config-location/app/country/projection.py \
  "$P/app/country/"

cp -a /opt/config-location/app/country/storage.py \
  "$P/app/country/"

cp -a /opt/config-location/app/country/panel_projection_adapter.py \
  "$P/app/country/"

cp -a /opt/config-location/app/country/production_publish_projection.py \
  "$P/app/country/"

cp -a /opt/config-location/app/country/country_identity.py \
  "$P/app/country/"

cp -a /opt/config-location/app/country/publish_contract_guard.py \
  "$P/app/country/"

cp -a /opt/config-location/app/panel/read_model.py \
  "$P/app/panel/"

cp -a /opt/config-location/app/publish/http.py \
  "$P/app/publish/"

cp -a /opt/config-location/app/publish/filter.py \
  "$P/app/publish/"

# package files/import dependencies
find /opt/config-location/app \
  -maxdepth 2 \
  -name '__init__.py' \
  -print0 |
while IFS= read -r -d '' F; do
    REL="${F#/opt/config-location/}"
    mkdir -p "$P/$(dirname "$REL")"
    cp -a "$F" "$P/$REL"
done

ln -s \
  /opt/config-location/venv/bin/python \
  "$P/venv/bin/python"

echo "BASELINE_COPY=PASS"


echo
echo "========== [2/6] BUILD SAFE SCRIPT =========="

# Keep only sections through [10/13].
awk '
/^################################################$/ {
    block++
}
{
    print
}
/# 11 RUNTIME IMPORT \+ CONTROLLED RESTART/ {
    exit
}
' "$SRC" > "$SCRIPT.raw"

# The line above stops after the section title; remove the
# incomplete section 11 header and everything following it.
python3 - "$SCRIPT.raw" "$SCRIPT" "$TMP" "$P" "$R" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
tmp = sys.argv[3]
project = sys.argv[4]
repo = sys.argv[5]

marker = """################################################
# 11 RUNTIME IMPORT + CONTROLLED RESTART
"""

if marker in src:
    src = src.split(marker, 1)[0]

src = src.replace(
    'PROJECT="/opt/config-location"',
    f'PROJECT="{project}"',
    1,
)

# Source-contract Python block inside the generated
# hardening script also contains an absolute source root.
# Point it at the temporary preflight copy.
src = src.replace(
    '/opt/config-location/app',
    f'{project}/app',
)

src = src.replace(
    'REPO="/root/project-log"',
    f'REPO="{repo}"',
    1,
)

src = src.replace(
    'BACKUP="/root/3245/${{PHASE}}-${{TS}}"',
    f'BACKUP="{tmp}/backup-${{TS}}"',
)

src = src.replace(
    'LOG="/root/background-logs/${PHASE}-${TS}.log"',
    f'LOG="{tmp}/preflight.log"',
)

# Results reconciliation must also remain inside /tmp.
src = src.replace(
    'RESULTS_LATEST="/var/lib/config-location/country/results/latest"',
    f'RESULTS_LATEST="{tmp}/runtime/results/latest"',
)

# Never restart a real service from rollback during preflight.
src = src.replace(
    "systemctl restart \\\n",
    "true # PREFLIGHT_NO_SYSTEMCTL \\\n",
)

# Do not require the real runtime user/group during source simulation.
src = src.replace(
    'id configloc >/dev/null',
    'true # PREFLIGHT_CONFIGLOC',
)

# grp.getgrnam("configloc") is only embedded into generated source;
# it is not executed by py_compile, so that remains intact.

# Stop cleanly after source gate.
src += r'''

echo
echo "=============================================="
echo " PREFLIGHT V2 SUCCESS"
echo "=============================================="
echo "PATCH_APPLICATION=PASS"
echo "COMPILE_GATE=PASS"
echo "SOURCE_CONTRACT=PASS"
echo "PRODUCTION_MUTATION=NO"
echo "SERVICE_RESTART=NO"
echo "PREFLIGHT_PHASE5_HARDENING_V2_SUCCESS"

MUTATION_STARTED="NO"
trap - ERR
'''

out.write_text(src)
PY

chmod +x "$SCRIPT"

bash -n "$SCRIPT"

echo "SAFE_SCRIPT_BUILD=PASS"


echo
echo "========== [3/6] PREP TEMP RUNTIME =========="

mkdir -p "$TMP/runtime/results/latest"

echo "TEMP_RUNTIME=PASS"


echo
echo "========== [4/6] EXECUTE PATCHES ON COPY =========="

bash "$SCRIPT"

echo "TEMP_PATCH_EXECUTION=PASS"


echo
echo "========== [5/6] INDEPENDENT COMPILE =========="

PYTHONPATH="$P" \
/opt/config-location/venv/bin/python \
-m py_compile \
  "$P/app/country/projection.py" \
  "$P/app/country/storage.py" \
  "$P/app/country/panel_projection_adapter.py" \
  "$P/app/panel/read_model.py" \
  "$P/app/country/production_publish_projection.py" \
  "$P/app/publish/http.py" \
  "$P/app/country/country_identity.py" \
  "$P/app/publish/filter.py" \
  "$P/app/country/publish_contract_guard.py"

echo "INDEPENDENT_COMPILE=PASS"


echo
echo "========== [6/6] FINAL =========="

echo "PRODUCTION_FILES_TOUCHED=NO"
echo "PRODUCTION_SERVICES_RESTARTED=NO"
echo "PREFLIGHT_RESULT=PASS"
