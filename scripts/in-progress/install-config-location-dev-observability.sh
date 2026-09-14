#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"
MIRROR="/root/config-location-live-git"

DEV_ROOT="/root/dev-scripts"
IN_PROGRESS="$DEV_ROOT/in-progress"
REPORT_ROOT="$DEV_ROOT/reports"

STATE_FILE="$PROJECT/PROJECT-STATE.md"
STATUS_FILE="/var/lib/config-location/dev-status.json"

BIN="/usr/local/sbin"

SERVICES=(
  config-location-panel.service
  config-location-country-worker.service
  config-location-country-event-consumer.service
)

echo "================================================"
echo " CONFIG LOCATION DEV OBSERVABILITY PACK"
echo "================================================"

[ "$(id -u)" -eq 0 ] || {
    echo "ERROR: run as root"
    exit 1
}

test -d "$PROJECT" || {
    echo "ERROR: project not found"
    exit 1
}

test -d "$MIRROR/.git" || {
    echo "ERROR: live mirror not found"
    exit 1
}

mkdir -p \
  "$IN_PROGRESS" \
  "$REPORT_ROOT" \
  "$(dirname "$STATUS_FILE")"


################################################
# HELPER: project status
################################################

cat > "$BIN/config-location-dev-status" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"
MIRROR="/root/config-location-live-git"
STATUS="/var/lib/config-location/dev-status.json"
STATE="$PROJECT/PROJECT-STATE.md"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cd "$MIRROR"

HEAD="$(
git rev-parse HEAD 2>/dev/null || echo unknown
)"

SHORT="$(
git rev-parse --short HEAD 2>/dev/null || echo unknown
)"

SYNC_DIRTY="$(
git status --porcelain | wc -l
)"

PANEL="$(
systemctl is-active config-location-panel.service 2>/dev/null || true
)"

WORKER="$(
systemctl is-active config-location-country-worker.service 2>/dev/null || true
)"

CONSUMER="$(
systemctl is-active config-location-country-event-consumer.service 2>/dev/null || true
)"

WATCH="$(
systemctl is-active config-location-live-watch.service 2>/dev/null || true
)"

TIMER="$(
systemctl is-active config-location-live-reconcile.timer 2>/dev/null || true
)"

SUB_ALL="$(
curl -sS \
  --max-time 5 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all \
  2>/dev/null || echo 000
)"

UNKNOWN="$(
curl -sS \
  --max-time 5 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/UNKNOWN \
  2>/dev/null || echo 000
)"

CONFLICT="$(
curl -sS \
  --max-time 5 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/CONFLICT \
  2>/dev/null || echo 000
)"

COUNTRY_COUNT="$(
PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY' 2>/dev/null || echo 0
try:
    from app.country.production_publish_projection import discovered_country_codes
    print(len(discovered_country_codes()))
except Exception:
    print(0)
PY
)"

PUBLISHABLE="$(
PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY' 2>/dev/null || echo 0
try:
    from app.publish.filter import build_publish_snapshot
    print(build_publish_snapshot().publishable)
except Exception:
    print(0)
PY
)"

python3 - \
  "$STATUS" \
  "$HEAD" \
  "$SHORT" \
  "$SYNC_DIRTY" \
  "$PANEL" \
  "$WORKER" \
  "$CONSUMER" \
  "$WATCH" \
  "$TIMER" \
  "$SUB_ALL" \
  "$UNKNOWN" \
  "$CONFLICT" \
  "$COUNTRY_COUNT" \
  "$PUBLISHABLE" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    _,
    status_file,
    head,
    short,
    dirty,
    panel,
    worker,
    consumer,
    watch,
    timer,
    sub_all,
    unknown,
    conflict,
    countries,
    publishable,
) = sys.argv

data = {
    "updated_at": datetime.now(timezone.utc).isoformat(),
    "project": "config-location",
    "git_commit": head,
    "git_short": short,
    "mirror_dirty_files": int(dirty),
    "services": {
        "panel": panel,
        "country_worker": worker,
        "country_event_consumer": consumer,
        "live_mirror_watch": watch,
        "live_mirror_timer": timer,
    },
    "endpoints": {
        "sub_all": int(sub_all) if sub_all.isdigit() else 0,
        "unknown": int(unknown) if unknown.isdigit() else 0,
        "conflict": int(conflict) if conflict.isdigit() else 0,
    },
    "country_count": int(countries),
    "publishable": int(publishable),
}

with open(status_file, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(json.dumps(data, ensure_ascii=False, indent=2))
PY

cat > "$STATE" <<EOF
# Config Location — Project State

Updated: $(date -Is)

## Current state

- Phase 5: PRODUCTION_COMPLETE
- Ready for Phase 6: YES
- Live Git mirror: $WATCH
- Reconcile timer: $TIMER

## Git

- Commit: \`$HEAD\`
- Short commit: \`$SHORT\`
- Mirror dirty files: $SYNC_DIRTY

## Core services

- Panel: $PANEL
- Country worker: $WORKER
- Country event consumer: $CONSUMER

## Endpoints

- /sub/all: $SUB_ALL
- /sub/country/UNKNOWN: $UNKNOWN
- /sub/country/CONFLICT: $CONFLICT

## Runtime

- Discovered countries: $COUNTRY_COUNT
- Publishable configs: $PUBLISHABLE

## Development workflow

Active development scripts:

\`\`\`
$(find /root/dev-scripts/in-progress -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null | sort)
\`\`\`

Latest development reports:

\`\`\`
$(find /root/dev-scripts/reports -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -10)
\`\`\`
