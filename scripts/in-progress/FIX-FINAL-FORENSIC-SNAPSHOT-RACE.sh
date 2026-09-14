#!/usr/bin/env bash
set -Eeuo pipefail

F=/root/MAKE-CONFIG-LOCATION-FINAL-FORENSIC-SNAPSHOT.sh
TS=$(date -u +%Y%m%d-%H%M%S)

test -f "$F"

cp -a "$F" "$F.before-race-fix-$TS"

export F

python3 <<'PY'
from pathlib import Path
import os

p=Path(os.environ["F"])
s=p.read_text()

old=r'''rsync -a \
--ignore-missing-args \
--exclude='*.tmp' \
--exclude='.*.tmp' \
--exclude='*.brk*.tmp' \
--exclude='*.lock' \
/var/lib/config-location/ \
"$WORK/state/config-location/"

echo "STATE_COPY_MODE=RSYNC_RACE_SAFE"
echo "TRANSIENT_TMP_EXCLUDED=YES"
'''

new=r'''# health-sandboxes are ephemeral runtime directories.
# They must not be part of a persistent forensic snapshot.
#
# rsync exit code 24 means source files vanished while
# being copied. In this live system that is expected for
# rotating health-results and is not snapshot corruption.

set +e

rsync -a \
--ignore-missing-args \
--exclude='health-sandboxes/' \
--exclude='*.tmp' \
--exclude='.*.tmp' \
--exclude='*.brk*.tmp' \
--exclude='*.lock' \
/var/lib/config-location/ \
"$WORK/state/config-location/"

RSYNC_RC=$?

set -e

echo "STATE_RSYNC_RC=$RSYNC_RC"

if [ "$RSYNC_RC" -ne 0 ] && \
   [ "$RSYNC_RC" -ne 24 ]
then
    echo "ERROR=STATE_RSYNC_FAILED"
    exit "$RSYNC_RC"
fi

echo "STATE_COPY_MODE=RSYNC_LIVE_RACE_SAFE"
echo "HEALTH_SANDBOXES_EXCLUDED=YES"
echo "TRANSIENT_TMP_EXCLUDED=YES"

if [ "$RSYNC_RC" -eq 24 ]; then
    echo "LIVE_VANISHED_FILES=ACCEPTED"
else
    echo "LIVE_VANISHED_FILES=NONE"
fi
'''

if old not in s:
    if "HEALTH_SANDBOXES_EXCLUDED=YES" in s:
        print("RACE_FIX_ALREADY_PRESENT=YES")
        raise SystemExit(0)

    raise SystemExit(
        "ERROR=STAGE3_BLOCK_NOT_FOUND"
    )

p.write_text(
    s.replace(old,new,1)
)

print("SNAPSHOT_RACE_FIX=PASS")
PY

bash -n "$F"

grep -q \
'HEALTH_SANDBOXES_EXCLUDED=YES' \
"$F"

echo "BASH_SYNTAX=PASS"
echo "RACE_FIX=PASS"
