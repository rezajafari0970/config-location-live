#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass0-country-detection-resolution-discovery"
PROJECT="/opt/config-location"
REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
DISCOVERY="$DISCOVERY_DIR/${PHASE}-${TS}.txt"

mkdir -p "$RUN_DIR" "$REPORT_DIR" "$DISCOVERY_DIR"

RESULT="SUCCESS"
ERRORS=""

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

finish() {
    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
        ERRORS="${ERRORS}\nexit code $CODE"
    fi

    cat > "$REPORT" <<REPORT
CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Mode:
READ ONLY DISCOVERY

Country mutation:
NONE

Config mutation:
NONE

GeoIP mutation:
NONE

Service restart:
NONE

Discovery:
$DISCOVERY

Log:
$LOG

Errors:
$ERRORS
REPORT

    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$REPO" || exit 1

    git add "$LOG" "$REPORT" "$DISCOVERY" >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit -m "Phase execution $PHASE $TS" >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT

echo "================================================"
echo " PHASE 5 PASS 0"
echo " COUNTRY DETECTION / RESOLUTION DISCOVERY"
echo "================================================"

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -d "$PROJECT/app" || {
    fail "project app missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

{
echo "================================================"
echo " CONFIG LOCATION"
echo " PHASE 5 PASS 0"
echo " COUNTRY DETECTION / RESOLUTION DISCOVERY"
echo "================================================"
echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"

echo
echo "========== [1] COUNTRY FILES =========="
find "$PROJECT/app" -type f -name '*.py' \
| grep -Ei 'country|geo|location|resolver|unknown|flag|region' \
| sort | head -n 500 || true

echo
echo "========== [2] COUNTRY REFERENCES =========="
grep -RnsI --include='*.py' \
-E 'country|geoip|location|unknown|ناشناس|flag|browserleaks|whatismyipaddress|post_connect|post-connect' \
"$PROJECT/app" 2>/dev/null | head -n 2500 || true

echo
echo "========== [3] COUNTRY SYMBOL MAP =========="
PROJECT="$PROJECT" "$PROJECT/venv/bin/python" - <<'PY'
import ast, os
from pathlib import Path

root = Path(os.environ["PROJECT"]) / "app"
terms = ("country","geo","location","resolve","unknown","flag","region","fallback")

for path in sorted(root.rglob("*.py")):
    try:
        tree = ast.parse(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        continue

    rows = []

    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if any(term in node.name.lower() for term in terms):
                rows.append(
                    (
                        node.lineno,
                        getattr(node, "end_lineno", node.lineno),
                        type(node).__name__,
                        node.name,
                    )
                )

    if rows:
        print()
        print("FILE:", path)
        for row in rows:
            print(f"{row[0]:5d} {row[1]:5d} {row[2]:18s} {row[3]}")
PY

echo
echo "========== [4] CENTRAL SETTINGS =========="
cd "$PROJECT"

PYTHONPATH="$PROJECT" "$PROJECT/venv/bin/python" - <<'PY'
import json
from app.settings.engine import get_settings

s = get_settings()

wanted = {}

for key in (
    "country",
    "country_detection",
    "location",
    "geoip",
    "unknown",
    "features",
    "publish",
):
    if key in s:
        wanted[key] = s[key]

print(json.dumps(wanted, ensure_ascii=False, indent=2))
PY

echo
echo "========== [5] GEOIP DATABASES =========="
find "$PROJECT" /var/lib/config-location /usr/share /usr/local/share \
-type f \
\( -iname '*.mmdb' -o -iname 'geoip.dat' -o -iname 'geosite.dat' -o -iname '*geoip*' \) \
-printf '%s %p\n' 2>/dev/null | sort -nr | head -n 200 || true

echo
echo "========== [6] COUNTRY RUNTIME =========="
for DIR in \
  /var/lib/config-location/country \
  /var/lib/config-location/countries \
  /var/lib/config-location/location \
  /var/lib/config-location/unknown
do
    echo
    echo "--- $DIR ---"

    if [ -d "$DIR" ]; then
        du -sh "$DIR" 2>/dev/null || true
        find "$DIR" -maxdepth 2 -type f -printf '%s %p\n' 2>/dev/null | head -n 250
    else
        echo "MISSING"
    fi
done

echo
echo "========== [7] UNKNOWN CONFIG COUNT =========="
"$PROJECT/venv/bin/python" - <<'PY'
import json
from pathlib import Path

root = Path("/var/lib/config-location/configs")

total = 0
unknown = 0
known = 0
sample = []

unknown_values = {
    "",
    "unknown",
    "Unknown",
    "UNKNOWN",
    "ناشناس",
    "none",
    "null",
    "--",
}

if not root.exists():
    print("CONFIG_ROOT_MISSING")
    raise SystemExit

for path in root.glob("*.json"):
    try:
        d = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        continue

    if not isinstance(d, dict):
        continue

    total += 1

    country = None

    for key in ("country", "country_name", "location"):
        if key in d:
            country = d.get(key)
            break

    value = "" if country is None else str(country).strip()

    if value in unknown_values:
        unknown += 1

        if len(sample) < 25:
            sample.append(
                {
                    "config_id": d.get("config_id", path.stem),
                    "type": d.get("type"),
                    "host": d.get("host", d.get("address")),
                    "country": country,
                }
            )
    else:
        known += 1

print("TOTAL_CONFIGS=", total)
print("KNOWN_COUNTRY=", known)
print("UNKNOWN_COUNTRY=", unknown)

if total:
    print("UNKNOWN_PERCENT=", round(unknown * 100 / total, 3))

print("UNKNOWN_SAMPLE=")
print(json.dumps(sample, ensure_ascii=False, indent=2))
PY

echo
echo "========== [8] NETWORK FALLBACK =========="
grep -RnsI --include='*.py' \
-E 'browserleaks|whatismyipaddress|ip-api|ipinfo|ipapi|httpx|requests\.|urllib|proxy.*country|country.*proxy|public.*ip' \
"$PROJECT/app" 2>/dev/null | head -n 1800 || true

echo
echo "========== [9] PUBLISH / ENDPOINTS =========="
grep -RnsI --include='*.py' \
-E 'country|countries|unknown|ناشناس|flag|sub/all|/sub/' \
"$PROJECT/app/publish" "$PROJECT/app/panel" "$PROJECT/app" \
2>/dev/null | head -n 2000 || true

echo
echo "========== [10] SYSTEMD =========="
systemctl list-unit-files --no-pager \
| grep -Ei 'config-location.*(country|geo|location)|(?:country|geo|location).*config-location' \
|| true

echo
echo "========== [11] CONTRACT QUESTIONS =========="
cat <<'QUESTIONS'
Q1. What is the canonical country resolver?
Q2. What is the canonical country state/storage?
Q3. Which config field is used for address/host?
Q4. Is DNS resolved before GeoIP?
Q5. What GeoIP database/provider is canonical?
Q6. What exact value represents UNKNOWN?
Q7. Is UNKNOWN persisted or recalculated?
Q8. Is post-connect fallback implemented?
Q9. Does post-connect run only for UNKNOWN?
Q10. Does it use the config tunnel itself?
Q11. Are browserleaks/whatismyipaddress wired?
Q12. Is detection restricted to healthy configs?
Q13. Is source/confidence stored?
Q14. How are names and flags normalized?
Q15. How does Publish create per-country outputs?
Q16. Is UNKNOWN exposed separately?
Q17. How is country state cleaned after config removal?
Q18. Is there a permanent country worker?
Q19. Are timeout/retry/concurrency protections present?
Q20. What is the safest Phase 5 Pass 1 insertion point?
QUESTIONS

echo
echo "READ_ONLY=true"
echo "COUNTRY_MUTATION=false"
echo "CONFIG_MUTATION=false"
echo "GEOIP_MUTATION=false"
echo "SERVICE_RESTART=false"
echo "PHASE5_PASS0_DISCOVERY_COMPLETE"

} > "$DISCOVERY"

echo
echo "========== VALIDATE =========="

test -s "$DISCOVERY" || {
    fail "discovery empty"
    exit 1
}

SIZE="$(stat -c '%s' "$DISCOVERY")"

if [ "$SIZE" -gt $((20 * 1024 * 1024)) ]; then
    fail "discovery exceeded 20MB"
    exit 1
fi

grep -q 'PHASE5_PASS0_DISCOVERY_COMPLETE' "$DISCOVERY" || {
    fail "discovery incomplete"
    exit 1
}

du -h "$DISCOVERY"
wc -l "$DISCOVERY"

echo "DISCOVERY_VALID"
echo "PHASE5_PASS0_SUCCESS"

RESULT="SUCCESS"
