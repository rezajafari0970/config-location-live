#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
SERVER="$R/app/panel/server.py"

echo "======================================================"
echo " PANEL A8.1 - SECURITY + NAVIGATION AUDIT"
echo "======================================================"


echo
echo "=== 1. PANEL SERVICE ==="

systemctl status \
config-location-panel.service \
--no-pager \
-l \
| head -n 80


echo
echo "=== 2. ALL ROUTES ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import create_app

app=create_app()

rows=[]

for route in app.router.routes():

    try:
        path=route.resource.canonical
    except Exception:
        path=str(route.resource)

    rows.append(
        (
            route.method,
            path,
        )
    )

for method,path in sorted(rows):

    print(
        method.ljust(8),
        path,
    )

print()
print(
    "TOTAL_ROUTES=",
    len(rows),
)
PY


echo
echo "=== 3. POST ROUTES ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import create_app

app=create_app()

posts=[]

for route in app.router.routes():

    if route.method!="POST":
        continue

    try:
        path=route.resource.canonical
    except Exception:
        path=str(route.resource)

    posts.append(path)


for path in sorted(posts):
    print(path)

print(
    "POST_COUNT=",
    len(posts),
)
PY


echo
echo "=== 4. AUTH MIDDLEWARE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect
import app.panel.server as s

for name in [
    "auth_middleware",
    "is_authenticated",
    "make_signed_cookie",
    "verify_signed_cookie",
    "cleanup_sessions",
]:

    obj=getattr(
        s,
        name,
        None,
    )

    print()
    print(
        "OBJECT=",
        name,
    )

    if obj is None:
        print("MISSING")
        continue

    try:
        print(
            inspect.getsource(
                obj
            )
        )
    except Exception as exc:
        print(
            "SOURCE_ERROR=",
            type(exc).__name__,
            str(exc),
        )
PY


echo
echo "=== 5. COOKIE SET CALLS ==="

grep -nE \
'set_cookie|del_cookie|SESSION_COOKIE|httponly|samesite|secure=' \
"$SERVER" \
|| true


echo
echo "=== 6. CSRF REFERENCES ==="

grep -RIn \
--include='*.py' \
--include='*.html' \
--include='*.js' \
-E \
'csrf|CSRF|X-CSRF|csrf_token' \
"$R/app/panel" \
|| true


echo
echo "=== 7. HTML FORM INVENTORY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import re

root=Path(
    "/opt/config-location/app/panel"
)

for p in sorted(
    root.glob("*.py")
):

    try:
        s=p.read_text(
            encoding="utf-8",
            errors="replace",
        )
    except Exception:
        continue

    forms=len(
        re.findall(
            r"<form\b",
            s,
            flags=re.I,
        )
    )

    if forms:
        print(
            p.name,
            "FORMS=",
            forms,
        )
PY


echo
echo "=== 8. NAVIGATION LINKS BY PAGE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import re

root=Path(
    "/opt/config-location/app/panel"
)

targets=[
    "/",
    "/configs",
    "/country",
    "/operations",
    "/publish",
    "/logout",
]

for p in sorted(
    root.glob("*_ui.py")
):

    try:
        s=p.read_text()
    except Exception:
        continue

    print()
    print(
        "FILE=",
        p.name,
    )

    for target in targets:

        count=len(
            re.findall(
                r'href=["\']'
                +re.escape(target)
                +r'["\']',
                s,
            )
        )

        print(
            target,
            "=",
            count,
        )
PY


echo
echo "=== 9. PUBLIC PATHS FROM AUTH MIDDLEWARE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect
from app.panel.server import auth_middleware

src=inspect.getsource(
    auth_middleware
)

print(src)
PY


echo
echo "=== 10. LOGIN HANDLER ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect
import app.panel.server as s

names=[
    name
    for name in dir(s)
    if "login" in name.lower()
]

print(
    "LOGIN_SYMBOLS=",
    names,
)

for name in names:

    obj=getattr(
        s,
        name,
    )

    if not callable(obj):
        continue

    try:
        src=inspect.getsource(obj)
    except Exception:
        continue

    print()
    print(
        "====",
        name,
        "===="
    )

    print(src)
PY


echo
echo "=== 11. SECURITY ENV KEYS ONLY ==="

if [ -f /etc/config-location/panel.env ]; then

    sed -E \
    's/=(.*)$/=<REDACTED>/' \
    /etc/config-location/panel.env \
    | sort

else

    echo "PANEL_ENV=MISSING"
fi


echo
echo "=== 12. PANEL FILE INVENTORY ==="

find "$R/app/panel" \
-maxdepth 1 \
-type f \
-name '*.py' \
-printf '%f\n' \
| sort


echo
echo "=== 13. COMPILE ==="

find "$R/app/panel" \
-maxdepth 1 \
-type f \
-name '*.py' \
-print0 \
| xargs -0 -n1 "$PY" -m py_compile

echo "PANEL_COMPILE=PASS"


echo
echo "=== 14. CORE SERVICES ==="

for S in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$S" 2>/dev/null || true
    )

    echo "$S=$X"

    test "$X" = active

done


echo
echo "======================================================"
echo "PANEL_A8_1_AUDIT=PASS"
echo "PRODUCTION_MUTATION=NO"
echo "PANEL_RESTART=NO"
echo "NEXT=PANEL-A8-2-CSRF-SESSION-HARDENING"
echo "======================================================"
