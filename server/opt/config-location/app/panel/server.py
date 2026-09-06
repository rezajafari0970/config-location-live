from __future__ import annotations



import os
import html
import hmac
import hashlib
import secrets
import time
import json

from pathlib import Path
from urllib.parse import urlencode

from aiohttp import web
from app.control.api import install_control_routes

from app.panel.country_ui import (
    country_page,
)

from app.panel.config_detail_ui import (
    config_detail_page,
)

from app.panel.operations_ui import (
    operations_page,
)

from app.panel.publish_ui import (
    publish_page,
)

# PANEL_A7_PUBLISH_API

# PANEL_A6_OPERATIONS_API

# PANEL_A5_CONFIG_DETAIL_API

# PANEL_A4_COUNTRY_UI_ROUTE

from app.devlog.endpoint import devlog_handler

from app.publish.http import install_publish_routes
from app.observability.http import install_lifecycle_observability_routes

from app.health.panel_adaptive import install_aiohttp_routes

from app.panel.settings_ui import install_settings_routes

from app.core.source_manager import (
    list_sources,
    get_source,
    add_source,
    edit_source,
    delete_source,
    set_enabled,
    stats,
    add_sources_bulk,
    delete_sources,
    delete_all_sources,
)


# ============================================================
# CONFIG
# ============================================================

PORT = int(
    os.environ.get(
        "CONFIGLOC_PORT",
        "4040"
    )
)

ADMIN_USER = os.environ.get(
    "CONFIGLOC_ADMIN_USER",
    "admin"
)

ADMIN_PASSWORD = os.environ.get(
    "CONFIGLOC_ADMIN_PASSWORD",
    "admin"
)

SESSION_SECRET = os.environ.get(
    "CONFIGLOC_SESSION_SECRET",
    "change-me"
)

SESSION_COOKIE = "configloc_session"

SESSION_TTL = 86400

REMEMBER_TTL = (
    365 * 24 * 60 * 60
)

FETCH_STATUS_FILE = Path(
    "/var/lib/config-location/state/fetcher-status.json"
)

sessions = {}


# ============================================================
# HELPERS
# ============================================================

def esc(value):
    return html.escape(
        str(value or "")
    )


def redirect_home(
    message: str | None = None,
    error: str | None = None,
):
    params = {}

    if message:
        params["msg"] = message

    if error:
        params["error"] = error

    location = "/"

    if params:
        location += "?" + urlencode(params)

    raise web.HTTPFound(
        location=location
    )


def get_fetcher_status():
    default = {
        "status": "not_started",
        "running": False,
        "last_cycle_at": None,
        "last_success_at": None,
        "current_source": None,
        "cycle": 0,
    }

    try:
        if not FETCH_STATUS_FILE.exists():
            return default

        data = json.loads(
            FETCH_STATUS_FILE.read_text(
                encoding="utf-8"
            )
        )

        if not isinstance(
            data,
            dict
        ):
            return default

        result = default.copy()
        result.update(data)

        return result

    except Exception:
        return default


# ============================================================
# SESSION
# ============================================================

def cleanup_sessions():
    now = time.time()

    expired = [
        token
        for token, info
        in sessions.items()
        if now > info["expires"]
    ]

    for token in expired:
        sessions.pop(
            token,
            None
        )


def create_signed_cookie(
    token: str,
    expires: int
):
    payload = (
        f"{token}:{expires}"
    )

    signature = hmac.new(
        SESSION_SECRET.encode(),
        payload.encode(),
        hashlib.sha256
    ).hexdigest()

    return (
        f"{token}:"
        f"{expires}:"
        f"{signature}"
    )


def verify_signed_cookie(
    value: str
):
    try:
        token, expires_text, signature = (
            value.split(":", 2)
        )

        expires = int(
            expires_text
        )

        if time.time() > expires:
            return None

        payload = (
            f"{token}:{expires}"
        )

        expected = hmac.new(
            SESSION_SECRET.encode(),
            payload.encode(),
            hashlib.sha256
        ).hexdigest()

        if not hmac.compare_digest(
            signature,
            expected
        ):
            return None

        return (
            token,
            expires
        )

    except Exception:
        return None


def is_authenticated(
    request
):
    cleanup_sessions()

    cookie = request.cookies.get(
        SESSION_COOKIE
    )

    if not cookie:
        return False

    verified = verify_signed_cookie(
        cookie
    )

    if not verified:
        return False

    token, expires = verified

    if token not in sessions:
        sessions[token] = {
            "expires": expires
        }

    return True


@web.middleware
async def auth_middleware(
    request,
    handler
):
    if (
        request.path in {
            "/login",
            "/health",
            "/api/publish/status",
            "/api/countries",
        }
        or request.path.startswith(
            "/devlog/"
        )
        or request.path.startswith(
            "/sub/"
        )
    ):
        return await handler(
            request
        )

    if not is_authenticated(
        request
    ):
        raise web.HTTPFound(
            "/login"
        )

    return await handler(
        request
    )


# ============================================================
# HTML
# ============================================================

def page(
    title,
    content,
    show_header=True
):
    header = ""

    if show_header:
        header = f"""
<div class="header">

<div>
<h1>Config Location</h1>
<small>
Management Panel • Port {PORT}
</small>
</div>

<a
 class="button secondary"
 href="/logout"
>
خروج
</a>

</div>
"""

    return web.Response(
        content_type="text/html",
        charset="utf-8",
        text=f"""<!doctype html>

<html
 lang="fa"
 dir="rtl"
>

<head>

<meta charset="utf-8">

<meta
 name="viewport"
 content="width=device-width,initial-scale=1"
>

<title>
{esc(title)}
</title>

<style>

* {{
    box-sizing:border-box;
}}

:root {{
    --orange:#f97316;
    --orange-dark:#ea580c;
    --orange-soft:#fff7ed;

    --bg:#f8fafc;
    --card:#ffffff;

    --border:#e2e8f0;

    --text:#1e293b;
    --muted:#64748b;

    --green:#16a34a;
    --red:#dc2626;
    --gray:#64748b;
}}

body {{
    margin:0;
    background:var(--bg);
    color:var(--text);
    font-family:Tahoma,Arial,sans-serif;
}}

.header {{
    padding:16px 20px;
    background:#fff;
    border-bottom:3px solid var(--orange);

    display:flex;
    justify-content:space-between;
    align-items:center;

    box-shadow:
        0 2px 8px
        rgba(0,0,0,.05);
}}

.header h1 {{
    margin:0;
    color:var(--orange-dark);
    font-size:22px;
}}

.header small {{
    color:var(--muted);
}}

.container {{
    max-width:1300px;
    margin:18px auto;
    padding:0 10px;
}}

.card {{
    background:#fff;
    border:1px solid var(--border);
    border-radius:14px;
    padding:16px;
    margin-bottom:15px;

    box-shadow:
        0 3px 12px
        rgba(15,23,42,.05);
}}

.grid {{
    display:grid;

    grid-template-columns:
        repeat(
            auto-fit,
            minmax(150px,1fr)
        );

    gap:9px;

    margin-bottom:15px;
}}

.stat {{
    background:var(--orange-soft);
    border:1px solid #fed7aa;
    border-radius:12px;
    padding:14px;
}}

.stat strong {{
    color:var(--orange-dark);
    display:block;
    font-size:22px;
}}

input,
select,
textarea {{
    width:100%;
    border:1px solid #cbd5e1;
    border-radius:9px;
    padding:10px;
    background:#fff;
    color:var(--text);
}}

input:focus,
select:focus,
textarea:focus {{
    outline:none;
    border-color:var(--orange);

    box-shadow:
        0 0 0 3px
        rgba(249,115,22,.12);
}}

textarea {{
    min-height:200px;
    resize:vertical;
    direction:ltr;
    font-family:monospace;
}}

label {{
    display:block;
    margin-bottom:6px;
}}

button,
.button {{
    background:var(--orange);
    color:#fff;

    border:0;
    border-radius:8px;

    padding:9px 13px;

    text-decoration:none;
    cursor:pointer;

    display:inline-block;
}}

button:hover,
.button:hover {{
    opacity:.9;
}}

.secondary {{
    background:var(--gray);
}}

.red {{
    background:var(--red);
}}

.green {{
    background:var(--green);
}}

.msg {{
    padding:11px;
    margin-bottom:12px;

    background:#f0fdf4;
    border:1px solid #86efac;
    border-radius:9px;

    color:#166534;
}}

.error {{
    background:#fef2f2;
    border-color:#fecaca;
    color:#991b1b;
}}

.table-wrap {{
    overflow-x:auto;
}}

table {{
    width:100%;
    border-collapse:collapse;
    min-width:950px;
}}

th,
td {{
    border-bottom:
        1px solid
        var(--border);

    padding:10px 8px;
    text-align:right;
    vertical-align:middle;
}}

th {{
    background:var(--orange-soft);
    color:#9a3412;
}}

.url {{
    direction:ltr;
    text-align:left;
    word-break:break-all;
}}

.actions {{
    white-space:nowrap;
}}

.actions button,
.actions a {{
    margin:2px;
}}

.source-tools {{
    display:flex;
    gap:7px;
    flex-wrap:wrap;
    margin-bottom:12px;
}}

.select-box {{
    width:18px;
    height:18px;
    accent-color:var(--orange);
}}

.login-wrap {{
    min-height:100vh;

    display:flex;
    align-items:center;
    justify-content:center;

    padding:20px;
}}

.login-card {{
    width:100%;
    max-width:420px;

    background:#fff;

    border:
        1px solid
        #fed7aa;

    border-top:
        5px solid
        var(--orange);

    border-radius:17px;

    padding:24px;

    box-shadow:
        0 12px 35px
        rgba(249,115,22,.12);
}}

.login-card h2 {{
    color:var(--orange-dark);
}}

.remember {{
    display:flex;
    gap:8px;
    align-items:center;
    margin:15px 0;
}}

.remember input {{
    width:18px;
    height:18px;
    accent-color:var(--orange);
}}

.notice {{
    color:#9a3412;
    background:#fff7ed;
    border:1px solid #fed7aa;
    padding:10px;
    border-radius:9px;
}}

@media(max-width:600px) {{

    .container {{
        padding:0 8px;
    }}

    .card {{
        padding:12px;
    }}

}}



/* =========================================================
   UI19.2 SAFE CSS
   Existing Panel style / f-string escaped
   ========================================================= */

.health-ui-status-card {{
    position:relative;
    overflow:hidden;
}}

.health-ui-title {{
    font-size:13px;
    color:#64748b;
    margin-bottom:9px;
}}

.health-ui-line {{
    display:flex;
    align-items:center;
    gap:9px;
}}

.health-ui-dot {{
    width:12px;
    height:12px;
    min-width:12px;
    border-radius:50%;
}}

.health-ui-value {{
    font-size:16px !important;
    margin:0;
}}

.health-ui-ok {{
    background:#f0fdf4 !important;
    border-color:#86efac !important;
}}

.health-ui-ok .health-ui-dot {{
    background:#16a34a;
    box-shadow:
        0 0 0 5px
        rgba(22,163,74,.12);
}}

.health-ui-ok .health-ui-value {{
    color:#15803d;
}}

.health-ui-warning {{
    background:#fff7ed !important;
    border-color:#fdba74 !important;
}}

.health-ui-warning .health-ui-dot {{
    background:#f97316;
    box-shadow:
        0 0 0 5px
        rgba(249,115,22,.12);
}}

.health-ui-warning .health-ui-value {{
    color:#c2410c;
}}

.health-ui-error {{
    background:#fef2f2 !important;
    border-color:#fca5a5 !important;
}}

.health-ui-error .health-ui-dot {{
    background:#dc2626;
    box-shadow:
        0 0 0 5px
        rgba(220,38,38,.12);
}}

.health-ui-error .health-ui-value {{
    color:#b91c1c;
}}

.health-ui-unknown {{
    background:#f8fafc !important;
    border-color:#cbd5e1 !important;
}}

.health-ui-unknown .health-ui-dot {{
    background:#64748b;
    box-shadow:
        0 0 0 5px
        rgba(100,116,139,.12);
}}

.health-ui-unknown .health-ui-value {{
    color:#475569;
}}


/* =========================================================
   UI19.4 RESPONSIVE POLISH
   ========================================================= */

.health-ui-title {{
    text-align:center;
}}

.health-ui-line {{
    justify-content:center;
}}

.health-ui-status-card {{
    min-height:72px;
    display:flex;
    flex-direction:column;
    justify-content:center;
}}

@media (max-width: 720px) {{

    .grid {{
        gap:7px;
    }}

    .stat {{
        min-width:0;
        padding:10px 7px;
        font-size:12px;
    }}

    .stat strong {{
        font-size:17px;
    }}

    .health-ui-title {{
        font-size:11px;
        margin-bottom:5px;
    }}

    .health-ui-value {{
        font-size:14px !important;
    }}

    .health-ui-dot {{
        width:9px;
        height:9px;
        min-width:9px;
    }}

    .source-tools {{
        gap:6px;
        flex-wrap:wrap;
    }}

    .source-tools .button {{
        flex:1 1 auto;
        min-width:95px;
        text-align:center;
    }}

}}

/* =========================================================
   FETCH STATUS UI
   ========================================================= */

.fetch-status-card {{
    position: relative;
    overflow: hidden;
    transition: .2s ease;
}}

.fetch-status-title {{
    font-size: 13px;
    color: #64748b;
    margin-bottom: 9px;
}}

.fetch-status-line {{
    display: flex;
    align-items: center;
    gap: 9px;
}}

.fetch-status-dot {{
    width: 12px;
    height: 12px;
    min-width: 12px;
    border-radius: 50%;
}}

.fetch-status-label {{
    font-size: 16px;
    font-weight: bold;
}}


/* RUNNING */

.fetch-running {{
    background: #f0fdf4 !important;
    border-color: #86efac !important;
}}

.fetch-running .fetch-status-dot {{
    background: #16a34a;
    box-shadow:
        0 0 0 5px rgba(22,163,74,.12);
}}

.fetch-running .fetch-status-label {{
    color: #15803d;
}}


/* WARNING */

.fetch-warning {{
    background: #fff7ed !important;
    border-color: #fdba74 !important;
}}

.fetch-warning .fetch-status-dot {{
    background: #f97316;
    box-shadow:
        0 0 0 5px rgba(249,115,22,.12);
}}

.fetch-warning .fetch-status-label {{
    color: #c2410c;
}}


/* ERROR */

.fetch-error {{
    background: #fef2f2 !important;
    border-color: #fca5a5 !important;
}}

.fetch-error .fetch-status-dot {{
    background: #dc2626;
    box-shadow:
        0 0 0 5px rgba(220,38,38,.12);
}}

.fetch-error .fetch-status-label {{
    color: #b91c1c;
}}


/* STOPPED */

.fetch-stopped {{
    background: #f8fafc !important;
    border-color: #cbd5e1 !important;
}}

.fetch-stopped .fetch-status-dot {{
    background: #64748b;
    box-shadow:
        0 0 0 5px rgba(100,116,139,.12);
}}

.fetch-stopped .fetch-status-label {{
    color: #475569;
}}


/* UNKNOWN */

.fetch-unknown {{
    background: #f8fafc !important;
    border-color: #e2e8f0 !important;
}}

.fetch-unknown .fetch-status-dot {{
    background: #94a3b8;
    box-shadow:
        0 0 0 5px rgba(148,163,184,.10);
}}

.fetch-unknown .fetch-status-label {{
    color: #64748b;
}}




/* PANEL V2 RESPONSIVE SAFE */

/* Desktop */

.source-table {{
    width:100%;
}}

.source-table .source-url-cell {{
    direction:ltr;
    text-align:left;
    word-break:normal;
    overflow-wrap:anywhere;
    min-width:260px;
    max-width:500px;
}}

.source-main-actions {{
    display:flex;
    gap:6px;
    flex-wrap:wrap;
    align-items:center;
}}

.source-runtime-details {{
    margin-top:10px;
    border:1px solid #e5e7eb;
    border-radius:10px;
    padding:8px 10px;
    background:#fafafa;
    white-space:normal;
}}

.source-runtime-details summary {{
    cursor:pointer;
    font-weight:700;
    color:#c86613;
}}

.source-runtime-grid {{
    margin-top:10px;
    display:grid;
    grid-template-columns:
        repeat(
            auto-fit,
            minmax(125px,1fr)
        );
    gap:8px;
}}

.source-runtime-item {{
    border:1px solid #ececec;
    border-radius:8px;
    background:#fff;
    padding:8px;
    min-width:0;
}}

.source-runtime-item .label {{
    display:block;
    font-size:10px;
    color:#94a3b8;
    margin-bottom:3px;
}}

.source-runtime-item .value {{
    display:block;
    font-size:13px;
    font-weight:600;
    overflow-wrap:anywhere;
}}

.source-error-value {{
    direction:ltr;
    text-align:left;
    white-space:pre-wrap;
    font-family:monospace;
    font-size:11px !important;
    max-height:120px;
    overflow:auto;
}}


/* ==========================================================
   MOBILE SOURCE CARDS
   ========================================================== */

@media (max-width:800px) {{

    .table-wrap {{
        overflow:visible !important;
    }}

    table.source-table {{
        min-width:0 !important;
        width:100% !important;
        display:block !important;
    }}

    .source-table thead {{
        display:none !important;
    }}

    .source-table tbody {{
        display:block !important;
        width:100% !important;
    }}

    .source-table tr {{
        display:block !important;
        width:100% !important;

        margin:0 0 14px 0;

        padding:12px;

        border:
            1px solid
            #e5e7eb;

        border-top:
            3px solid
            var(--orange);

        border-radius:12px;

        background:#fff;

        box-sizing:border-box;
    }}

    .source-table td {{
        display:block !important;

        width:100% !important;
        max-width:none !important;
        min-width:0 !important;

        box-sizing:border-box;

        border:0 !important;

        border-bottom:
            1px solid
            #f1f5f9 !important;

        padding:
            8px 2px !important;

        text-align:right !important;

        white-space:normal !important;
    }}

    .source-table td:last-child {{
        border-bottom:0 !important;
    }}

    .source-table td::before {{
        content:attr(data-label);

        display:block;

        margin-bottom:4px;

        color:#94a3b8;

        font-size:10px;

        font-weight:600;
    }}

    .source-table .select-cell {{
        display:flex !important;
        align-items:center;
        justify-content:space-between;
    }}

    .source-table .select-cell::before {{
        margin:0;
    }}

    .source-table .source-url-cell {{
        direction:ltr !important;
        text-align:left !important;

        min-width:0 !important;
        max-width:none !important;

        word-break:break-word !important;
        overflow-wrap:anywhere !important;

        font-size:12px;
        line-height:1.6;

        background:#f8fafc;

        border-radius:7px;

        padding:8px !important;
    }}

    .source-table .desktop-runtime-column {{
        display:none !important;
    }}

    .source-main-actions {{
        display:grid !important;

        grid-template-columns:
            repeat(2,minmax(0,1fr));

        gap:7px;

        width:100%;
    }}

    .source-main-actions button,
    .source-main-actions a {{
        display:block;

        width:100% !important;

        box-sizing:border-box;

        margin:0 !important;

        text-align:center;
    }}

    .source-runtime-details {{
        width:100%;

        box-sizing:border-box;

        margin-top:10px;
    }}

    .source-runtime-grid {{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }}

    .source-runtime-item {{
        text-align:center;
    }}

    .source-error-value {{
        text-align:left;
    }}

}}




/* PANEL V3 REAL SOURCE CARDS */

.source-card-grid {{
    display:grid;
    grid-template-columns:
        repeat(
            auto-fit,
            minmax(420px,1fr)
        );
    gap:14px;
    width:100%;
    margin-top:14px;
}}

.source-card-item {{
    border:1px solid #e2e8f0;
    border-top:4px solid var(--orange);
    border-radius:14px;
    background:#fff;
    padding:14px;
    min-width:0;
    box-sizing:border-box;

    box-shadow:
        0 3px 12px
        rgba(15,23,42,.04);
}}

.source-card-head {{
    display:flex;
    justify-content:space-between;
    align-items:flex-start;
    gap:12px;
    margin-bottom:12px;
}}

.source-card-head-right {{
    display:flex;
    align-items:flex-start;
    gap:10px;
    min-width:0;
    flex:1;
}}

.source-card-select {{
    flex:0 0 auto;
    padding-top:3px;
}}

.source-card-title-wrap {{
    min-width:0;
    flex:1;
}}

.source-card-name {{
    font-size:15px;
    font-weight:700;
    color:#1e293b;
    overflow-wrap:anywhere;
}}

.source-card-id {{
    direction:ltr;
    text-align:left;
    font-size:9px;
    color:#94a3b8;
    margin-top:3px;
    overflow-wrap:anywhere;
}}

.source-card-url {{
    direction:ltr;
    text-align:left;
    width:100%;
    box-sizing:border-box;

    background:#f8fafc;
    border:1px solid #e2e8f0;
    border-radius:9px;

    padding:9px 10px;
    margin-bottom:12px;

    font-size:12px;
    line-height:1.65;

    word-break:break-word;
    overflow-wrap:anywhere;
}}

.source-card-summary {{
    display:grid;
    grid-template-columns:
        repeat(4,minmax(0,1fr));
    gap:8px;
    margin-bottom:12px;
}}

.source-card-stat {{
    background:#fafafa;
    border:1px solid #f1f5f9;
    border-radius:9px;
    padding:7px;
    min-width:0;
    text-align:center;
}}

.source-card-stat-label {{
    display:block;
    font-size:9px;
    color:#94a3b8;
    margin-bottom:3px;
}}

.source-card-stat-value {{
    display:block;
    color:#334155;
    font-weight:600;
    font-size:11px;
    overflow-wrap:anywhere;
}}

.source-card-actions {{
    display:grid;
    grid-template-columns:
        repeat(4,minmax(0,1fr));
    gap:7px;
    margin-top:12px;
}}

.source-card-actions button,
.source-card-actions a {{
    width:100%;
    box-sizing:border-box;
    margin:0 !important;
    text-align:center;
    white-space:normal;
}}

.source-card-runtime {{
    margin-top:12px;
    border:1px solid #fed7aa;
    border-radius:10px;
    background:#fffaf5;
    padding:9px;
}}

.source-card-runtime summary {{
    cursor:pointer;
    color:#c2410c;
    font-weight:700;
    font-size:12px;
    user-select:none;
}}

.source-card-runtime-grid {{
    margin-top:10px;
    display:grid;
    grid-template-columns:
        repeat(4,minmax(0,1fr));
    gap:7px;
}}

.source-card-runtime-item {{
    background:#fff;
    border:1px solid #f1f5f9;
    border-radius:8px;
    padding:7px;
    min-width:0;
    text-align:center;
}}

.source-card-runtime-item .label {{
    display:block;
    font-size:9px;
    color:#94a3b8;
    margin-bottom:3px;
}}

.source-card-runtime-item .value {{
    display:block;
    font-size:11px;
    font-weight:600;
    color:#334155;
    overflow-wrap:anywhere;
}}

.source-card-error {{
    grid-column:1/-1;
    text-align:right;
}}

.source-card-error .value {{
    direction:ltr;
    text-align:left;
    white-space:pre-wrap;
    font-family:monospace;
    font-size:10px;
    max-height:130px;
    overflow:auto;
}}

.source-card-empty {{
    padding:25px 15px;
    text-align:center;
    color:#64748b;
    background:#f8fafc;
    border:1px dashed #cbd5e1;
    border-radius:12px;
}}


@media(max-width:700px) {{

    .source-card-grid {{
        display:block;
        width:100%;
        margin-top:12px;
    }}

    .source-card-item {{
        width:100%;
        margin-bottom:13px;
        padding:12px;
    }}

    .source-card-summary {{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }}

    .source-card-runtime-grid {{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }}

    .source-card-actions {{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }}

    .source-card-name {{
        font-size:14px;
    }}

    .source-card-url {{
        font-size:11px;
    }}

}}


@media(max-width:380px) {{

    .source-card-actions {{
        grid-template-columns:1fr;
    }}

    .source-card-summary {{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }}

}}

</style>

</head>

<body>

{header}

<div class="container">
{content}
</div>

</body>

</html>"""
    )


# ============================================================
# LOGIN
# ============================================================

async def login_page(
    request
):
    if is_authenticated(
        request
    ):
        raise web.HTTPFound(
            "/"
        )

    error = request.query.get(
        "error",
        ""
    )

    error_html = ""

    if error:
        error_html = f"""
<div class="msg error">
{esc(error)}
</div>
"""

    content = f"""

<div class="login-wrap">

<div class="login-card">

<h2>
ورود به پنل
</h2>

<p style="color:#64748b">
Config Location Management Panel
</p>

{error_html}

<form
 method="post"
 action="/login"
>

<p>
<label>
نام کاربری
</label>

<input
 name="username"
 required
 autocomplete="username"
>
</p>

<p>
<label>
رمز عبور
</label>

<input
 type="password"
 name="password"
 required
 autocomplete="current-password"
>
</p>

<label class="remember">

<input
 type="checkbox"
 name="remember"
 value="1"
 checked
>

<span>
مرا به خاطر بسپار
</span>

</label>

<button
 type="submit"
 style="width:100%"
>
ورود
</button>

</form>

</div>

</div>
"""

    return page(
        "ورود",
        content,
        False
    )


async def login_post(
    request
):
    data = await request.post()

    username = str(
        data.get(
            "username",
            ""
        )
    )

    password = str(
        data.get(
            "password",
            ""
        )
    )

    remember = (
        data.get(
            "remember"
        )
        == "1"
    )

    if not (
        hmac.compare_digest(
            username,
            ADMIN_USER
        )
        and
        hmac.compare_digest(
            password,
            ADMIN_PASSWORD
        )
    ):
        raise web.HTTPFound(
            "/login?"
            + urlencode({
                "error":
                "نام کاربری یا رمز عبور اشتباه است."
            })
        )

    ttl = (
        REMEMBER_TTL
        if remember
        else
        SESSION_TTL
    )

    expires = int(
        time.time()
        + ttl
    )

    token = secrets.token_urlsafe(
        32
    )

    sessions[token] = {
        "expires": expires
    }

    response = web.HTTPFound(
        "/"
    )

    response.set_cookie(
        SESSION_COOKIE,
        create_signed_cookie(
            token,
            expires
        ),
        httponly=True,
        samesite="Lax",
        max_age=ttl,
        path="/",
    )

    raise response


async def logout(
    request
):
    cookie = request.cookies.get(
        SESSION_COOKIE
    )

    if cookie:
        verified = verify_signed_cookie(
            cookie
        )

        if verified:
            token, _ = verified

            sessions.pop(
                token,
                None
            )

    response = web.HTTPFound(
        "/login"
    )

    response.del_cookie(
        SESSION_COOKIE,
        path="/"
    )

    raise response


def format_time(value):
    if not value:
        return "-"

    try:
        from datetime import datetime

        value = str(value)

        dt = datetime.fromisoformat(
            value.replace("Z", "+00:00")
        )

        return dt.strftime(
            "%Y-%m-%d %H:%M:%S"
        )

    except Exception:
        return str(value)


def build_source_ownership_index():
    """
    Build ownership statistics ONCE for the dashboard.

    owned:
        source appears in source_ids.

    exclusive:
        this source is the only owner.

    shared:
        config has this source plus another source.

    snapshot:
        filled separately from source snapshot.
    """

    index = {}

    try:
        from app.core.config_store import list_configs

        configs = list_configs()

        for record in configs:

            if not isinstance(record, dict):
                continue

            source_ids = record.get(
                "source_ids",
                []
            )

            if not isinstance(
                source_ids,
                list
            ):
                continue

            owners = []

            seen = set()

            for value in source_ids:

                sid = str(
                    value or ""
                ).strip()

                if not sid:
                    continue

                if sid in seen:
                    continue

                seen.add(sid)
                owners.append(sid)

            if not owners:
                continue

            shared = (
                len(owners) > 1
            )

            for sid in owners:

                item = index.setdefault(
                    sid,
                    {
                        "owned": 0,
                        "exclusive": 0,
                        "shared": 0,
                    },
                )

                item["owned"] += 1

                if shared:
                    item["shared"] += 1
                else:
                    item["exclusive"] += 1

    except Exception:
        pass

    return index


def get_source_snapshot_count(
    source_id
):
    try:
        from app.core.config_store import (
            read_source_snapshot,
        )

        snapshot = read_source_snapshot(
            source_id
        )

        if snapshot is None:
            return 0

        return len(snapshot)

    except Exception:
        return 0


def trigger_one_source_fetch(
    source_id
):
    """
    Wake only ONE source worker.

    Does not restart the fetcher service and does not trigger
    any other source.
    """

    source_id = str(
        source_id or ""
    ).strip()

    if not source_id:
        raise ValueError(
            "empty source id"
        )

    trigger_dir = Path(
        "/var/lib/config-location/source-triggers"
    )

    trigger_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    trigger = (
        trigger_dir
        / f"{source_id}.trigger"
    )

    tmp = trigger.with_suffix(
        ".tmp"
    )

    tmp.write_text(
        str(time.time()),
        encoding="utf-8",
    )

    os.replace(
        tmp,
        trigger,
    )

    return str(trigger)


def clear_source_owned_data(
    source_id
):
    """
    Clear data belonging to ONE source only.

    Behaviour:
      - Source definition remains.
      - Source enabled/disabled state remains.
      - URL and interval remain.
      - Exclusive configs may be deleted.
      - Shared configs remain and only this source ownership
        is detached.
      - Snapshot for this source is removed.
      - Other sources are untouched.
    """

    source_id = str(
        source_id or ""
    ).strip()

    if not source_id:
        raise ValueError(
            "empty source id"
        )

    from app.core.config_store import (
        detach_source_from_configs,
        remove_source_snapshot,
    )

    detach_result = (
        detach_source_from_configs(
            source_id
        )
    )

    snapshot_removed = False

    try:
        remove_source_snapshot(
            source_id
        )

        snapshot_removed = True

    except FileNotFoundError:
        snapshot_removed = False

    return {
        "source_id": source_id,
        "detach_result": detach_result,
        "snapshot_removed": snapshot_removed,
    }


def reset_source_runtime_state(
    source_id
):
    """
    Reset ONLY transient runtime state for one source.

    This does NOT:
      - delete configs
      - detach ownership
      - delete source snapshot
      - disable source
      - affect any other worker
    """

    source_id = str(
        source_id or ""
    ).strip()

    if not source_id:
        raise ValueError(
            "empty source id"
        )

    from app.core.source_runtime import (
        update_runtime,
    )

    now = time.time()

    update_runtime(
        source_id,

        state="idle",
        worker_state="idle",

        last_error=None,

        consecutive_failures=0,
        current_backoff_seconds=0,
        backoff_until_epoch=0,

        last_reset_epoch=now,
    )

    return True


def get_source_runtime(source_id):
    try:
        from app.core.source_runtime import read_runtime

        data = read_runtime(
            source_id
        )

        if isinstance(data, dict):
            return data

    except Exception:
        pass

    return {}


def runtime_state_badge(runtime):
    state = str(
        runtime.get("worker_state")
        or runtime.get("state")
        or "unknown"
    ).strip().lower()

    labels = {
        "fetching": "در حال دریافت",
        "sleeping": "منتظر",
        "idle": "آماده",
        "error": "خطا",
        "disabled": "غیرفعال",
        "stopped": "متوقف",
        "starting": "در حال شروع",
        "unknown": "نامشخص",
    }

    classes = {
        "fetching": "green",
        "sleeping": "secondary",
        "idle": "secondary",
        "error": "red",
        "disabled": "secondary",
        "stopped": "secondary",
        "starting": "green",
        "unknown": "secondary",
    }

    return (
        labels.get(
            state,
            esc(state),
        ),
        classes.get(
            state,
            "secondary",
        ),
    )


def runtime_next_fetch(
    runtime,
    source,
):
    try:
        backoff_until = float(
            runtime.get(
                "backoff_until_epoch",
                0,
            )
            or 0
        )
    except Exception:
        backoff_until = 0

    try:
        last_epoch = float(
            runtime.get(
                "last_fetch_epoch",
                0,
            )
            or 0
        )
    except Exception:
        last_epoch = 0

    try:
        interval = max(
            1,
            int(
                source.get(
                    "fetch_interval_seconds",
                    60,
                )
                or 60
            ),
        )
    except Exception:
        interval = 60

    due_at = max(
        (
            last_epoch
            + interval
            if last_epoch
            else 0
        ),
        backoff_until,
    )

    if not due_at:
        return "-"

    remaining = int(
        max(
            0,
            due_at - time.time(),
        )
    )

    if remaining <= 0:
        return "الان"

    if remaining < 60:
        return (
            f"{remaining} ثانیه"
        )

    minutes, seconds = divmod(
        remaining,
        60,
    )

    if minutes < 60:
        return (
            f"{minutes}د {seconds}ث"
        )

    hours, minutes = divmod(
        minutes,
        60,
    )

    return (
        f"{hours}س {minutes}د"
    )



# ============================================================
# DASHBOARD
# ============================================================

async def dashboard(
    request
):
    sources = list_sources()

    source_stats = stats()

    fetcher = get_fetcher_status()

    ownership_index = (
        build_source_ownership_index()
    )

    msg = request.query.get(
        "msg",
        ""
    )

    error = request.query.get(
        "error",
        ""
    )

    notice = ""

    if msg:
        notice += f"""
<div class="msg">
{esc(msg)}
</div>
"""

    if error:
        notice += f"""
<div class="msg error">
{esc(error)}
</div>
"""

    rows = []

    for src in sources:

        runtime = get_source_runtime(
            src.get("id")
        )

        enabled = bool(
            src.get(
                "enabled"
            )
        )

        state_text = (
            "فعال"
            if enabled
            else
            "غیرفعال"
        )

        state_class = (
            "green"
            if enabled
            else
            "secondary"
        )

        raw_source_id = str(
            src.get(
                "id"
            )
            or ""
        )

        ownership_stats = (
            ownership_index.get(
                raw_source_id,
                {}
            )
        )

        owned_count = int(
            ownership_stats.get(
                "owned",
                0,
            )
            or 0
        )

        exclusive_count = int(
            ownership_stats.get(
                "exclusive",
                0,
            )
            or 0
        )

        shared_count = int(
            ownership_stats.get(
                "shared",
                0,
            )
            or 0
        )

        snapshot_count = (
            get_source_snapshot_count(
                raw_source_id
            )
        )

        source_id = esc(
            raw_source_id
        )

        (
            worker_label,
            worker_class,
        ) = runtime_state_badge(
            runtime
        )

        inferred_mode = str(
            runtime.get(
                "inferred_mode"
            )
            or src.get(
                "fetch_mode"
            )
            or "auto"
        )

        try:
            configs_last = int(
                runtime.get(
                    "configs_last_cycle",
                    0,
                )
                or 0
            )
        except Exception:
            configs_last = 0

        try:
            new_last = int(
                runtime.get(
                    "new_configs_last_cycle",
                    0,
                )
                or 0
            )
        except Exception:
            new_last = 0

        http_status = (
            runtime.get(
                "last_http_status"
            )
            or runtime.get(
                "last_status_code"
            )
            or "-"
        )

        try:
            backoff_seconds = float(
                runtime.get(
                    "current_backoff_seconds",
                    0,
                )
                or 0
            )
        except Exception:
            backoff_seconds = 0

        try:
            failures = int(
                runtime.get(
                    "consecutive_failures",
                    0,
                )
                or 0
            )
        except Exception:
            failures = 0

        last_error = str(
            runtime.get(
                "last_error"
            )
            or ""
        )

        next_fetch = (
            runtime_next_fetch(
                runtime,
                src,
            )
        )

        rows.append(
f"""
<div class="source-card-item">

<div class="source-card-head">

<div class="source-card-head-right">

<div class="source-card-select">

<input
 class="select-box source-checkbox"
 type="checkbox"
 name="source_ids"
 value="{source_id}"
>

</div>

<div class="source-card-title-wrap">

<div class="source-card-name">
{esc(src.get("name") or "بدون نام")}
</div>

<div class="source-card-id">
{source_id}
</div>

</div>

</div>


<span
 class="button {state_class}"
 style="cursor:default"
>
{state_text}
</span>

</div>


<div class="source-card-url">
{esc(src.get("url"))}
</div>


<div class="source-card-summary">


<div class="source-card-stat">

<span class="source-card-stat-label">
Interval
</span>

<span class="source-card-stat-value">

{esc(
    src.get(
        "fetch_interval_seconds",
        60
    )
)}
ثانیه

</span>

</div>


<div class="source-card-stat">

<span class="source-card-stat-label">
آخرین Fetch
</span>

<span class="source-card-stat-value">

{esc(
    format_time(
        runtime.get("last_fetch_at")
        or
        src.get("last_fetch_at")
    )
)}

</span>

</div>


<div class="source-card-stat">

<span class="source-card-stat-label">
Owned
</span>

<span class="source-card-stat-value">
{owned_count}
</span>

</div>


<div class="source-card-stat">

<span class="source-card-stat-label">
Worker
</span>

<span class="source-card-stat-value">

<span
 class="button {worker_class}"
 style="
    cursor:default;
    padding:3px 7px;
    font-size:10px;
 "
>
{esc(worker_label)}
</span>

</span>

</div>


</div>


<details class="source-card-runtime">

<summary>
جزئیات Runtime
</summary>


<div class="source-card-runtime-grid">


<div class="source-card-runtime-item">

<span class="label">
Mode
</span>

<span class="value">
{esc(inferred_mode)}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
HTTP
</span>

<span class="value">
{esc(http_status)}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Configs
</span>

<span class="value">
{configs_last}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
New
</span>

<span
 class="value"
 style="color:#16a34a"
>
+{new_last}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Fetch بعدی
</span>

<span class="value">
{esc(next_fetch)}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Failures
</span>

<span class="value">
{failures}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Backoff
</span>

<span class="value">
{int(backoff_seconds)}s
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Status
</span>

<span class="value">
{state_text}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Owned
</span>

<span class="value">
{owned_count}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Exclusive
</span>

<span class="value">
{exclusive_count}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Shared
</span>

<span class="value">
{shared_count}
</span>

</div>


<div class="source-card-runtime-item">

<span class="label">
Snapshot
</span>

<span class="value">
{snapshot_count}
</span>

</div>


<div
 class="
    source-card-runtime-item
    source-card-error
 "
>

<span class="label">
آخرین خطا
</span>

<span class="value">
{esc(last_error) if last_error else "-"}
</span>

</div>


</div>

</details>


<div class="source-card-actions">


<button
 type="submit"
 class="green"

 formaction="/source/{source_id}/fetch-now"
 formmethod="post"
>
Fetch Now
</button>


<button
 type="submit"
 class="secondary"

 formaction="/source/{source_id}/reset-runtime"
 formmethod="post"

 onclick="
    return confirm(
        'Runtime فقط برای همین Source ریست شود؟'
    );
 "
>
Reset Runtime
</button>


<button
 type="submit"
 class="green"

 formaction="/source/{source_id}/rebuild"
 formmethod="post"

 onclick="
    return confirm(
        'Rebuild کامل همین Source انجام شود؟\\n\\n'
        +
        'Ownership این Source پاک می‌شود.\\n'
        +
        'Exclusive ها حذف می‌شوند.\\n'
        +
        'Shared ها برای Source های دیگر باقی می‌مانند.\\n'
        +
        'Snapshot و Runtime ریست می‌شوند.\\n'
        +
        'سپس فقط همین Source دوباره Fetch می‌شود.'
    );
 "
>
Rebuild
</button>


<button
 type="submit"
 class="red"

 formaction="/source/{source_id}/clear-data"
 formmethod="post"

 onclick="
    return confirm(
        'هشدار: تمام داده‌های متعلق به همین Source پاک شوند؟\\n\\n'
        +
        'Exclusive ها حذف می‌شوند.\\n'
        +
        'Shared ها برای Source های دیگر باقی می‌مانند.\\n'
        +
        'خود Source حذف نمی‌شود.'
    );
 "
>
Clear Data
</button>


<a
 class="button"
 href="/source/{source_id}/edit"
>
ویرایش
</a>


<button
 type="submit"
 class="secondary"

 formaction="/source/{source_id}/toggle"
 formmethod="post"

 onclick="
    return confirm(
        'وضعیت این Source تغییر کند؟'
    );
 "
>
روشن/خاموش
</button>


<button
 type="submit"
 class="red"

 formaction="/source/{source_id}/delete"
 formmethod="post"

 onclick="
    return confirm(
        'این Source حذف شود؟'
    );
 "
>
حذف
</button>


</div>

</div>
"""
        )


    rows_html = (
        "\n".join(
            rows
        )
        if rows
        else
        """
<div class="source-card-empty">
هیچ Source ثبت نشده است.
</div>
"""
    )


    fetch_running = bool(
        fetcher.get("running")
    )

    raw_status = str(
        fetcher.get("status")
        or ""
    ).strip().lower()

    if fetch_running:
        fetch_status = "فعال"
        fetch_status_class = "fetch-running"

    elif raw_status in {
        "warning",
        "degraded",
        "partial",
        "incomplete",
        "unstable",
    }:
        fetch_status = "ناقص"
        fetch_status_class = "fetch-warning"

    elif raw_status in {
        "error",
        "failed",
        "failure",
        "problem",
        "crashed",
    }:
        fetch_status = "مشکل‌دار"
        fetch_status_class = "fetch-error"

    elif raw_status in {
        "not_started",
        "unknown",
        "",
    }:
        fetch_status = "هنوز شروع نشده"
        fetch_status_class = "fetch-unknown"

    else:
        fetch_status = "متوقف"
        fetch_status_class = "fetch-stopped"


    # UI19.2 SAFE HEALTH SUMMARY
    # Read-only. Any observability failure falls back
    # to unknown and must not break the main dashboard.
    try:
        from app.observability.lifecycle import (
            build_lifecycle_observability,
        )

        lifecycle_ui = (
            build_lifecycle_observability()
        )

    except Exception:
        lifecycle_ui = {
            "state": "unknown",
            "policy": {},
            "sync": {
                "state": "unknown",
            },
            "watchdog": {
                "state": "unknown",
            },
        }


    lifecycle_policy = (
        lifecycle_ui.get(
            "policy",
            {},
        )
    )


    def _ui19_status(
        value,
    ):
        value = str(
            value
        ).strip().lower()

        if value in {
            "healthy",
            "synced",
            "idle",
            "active",
            "running",
        }:
            return (
                "سالم",
                "health-ui-ok",
            )

        if value in {
            "warning",
            "recover",
            "degraded",
        }:
            return (
                "هشدار",
                "health-ui-warning",
            )

        if value in {
            "error",
            "stale",
            "critical",
            "failed",
        }:
            return (
                "مشکل‌دار",
                "health-ui-error",
            )

        return (
            "نامشخص",
            "health-ui-unknown",
        )


    (
        lifecycle_state_fa,
        lifecycle_state_class,
    ) = _ui19_status(
        lifecycle_ui.get(
            "state",
            "unknown",
        )
    )


    (
        lifecycle_sync_fa,
        lifecycle_sync_class,
    ) = _ui19_status(
        lifecycle_ui.get(
            "sync",
            {},
        ).get(
            "state",
            "unknown",
        )
    )


    (
        lifecycle_watchdog_fa,
        lifecycle_watchdog_class,
    ) = _ui19_status(
        lifecycle_ui.get(
            "watchdog",
            {},
        ).get(
            "state",
            "unknown",
        )
    )


    # UI19.5 FRESHNESS SUMMARY
    lifecycle_freshness = (
        lifecycle_ui.get(
            "freshness",
            {}
        )
    )

    lifecycle_warnings = (
        lifecycle_ui.get(
            "warnings"
        )
        or []
    )

    lifecycle_safety = (
        lifecycle_ui.get(
            "safety",
            {}
        )
    )


    def _ui19_age_state(
        value,
        warning_at,
        error_at,
    ):
        try:
            age = float(value)
        except Exception:
            return (
                "نامشخص",
                "health-ui-unknown",
            )

        if age >= error_at:
            return (
                f"{age:.0f}s",
                "health-ui-error",
            )

        if age >= warning_at:
            return (
                f"{age:.0f}s",
                "health-ui-warning",
            )

        return (
            f"{age:.0f}s",
            "health-ui-ok",
        )


    (
        policy_age_text,
        policy_age_class,
    ) = _ui19_age_state(
        lifecycle_freshness.get(
            "policy_seconds"
        ),
        45,
        90,
    )


    (
        tracker_age_text,
        tracker_age_class,
    ) = _ui19_age_state(
        lifecycle_freshness.get(
            "tracker_seconds"
        ),
        45,
        90,
    )


    (
        sync_age_text,
        sync_age_class,
    ) = _ui19_age_state(
        lifecycle_freshness.get(
            "sync_seconds"
        ),
        25,
        45,
    )


    (
        watchdog_age_text,
        watchdog_age_class,
    ) = _ui19_age_state(
        lifecycle_freshness.get(
            "watchdog_seconds"
        ),
        25,
        45,
    )


    global_freeze_active = bool(
        lifecycle_safety.get(
            "global_freeze",
            False,
        )
    )

    if global_freeze_active:
        global_freeze_text = "فعال"
        global_freeze_class = "health-ui-error"
    else:
        global_freeze_text = "غیرفعال"
        global_freeze_class = "health-ui-ok"


    lifecycle_warning_count = len(
        lifecycle_warnings
    )

    if lifecycle_warning_count > 0:
        warning_count_class = "health-ui-warning"
    else:
        warning_count_class = "health-ui-ok"


    content = f"""

{notice}


<div class="grid">


<div class="stat fetch-status-card {fetch_status_class}">

<div class="fetch-status-title">
وضعیت Fetch
</div>

<div class="fetch-status-line">

<span class="fetch-status-dot"></span>

<span class="fetch-status-label">
{fetch_status}
</span>

</div>

</div>



<div class="stat">

<strong
 style="font-size:14px"
>
{esc(
    format_time(
        fetcher.get(
            "last_cycle_at"
        )
    )
)}
</strong>

آخرین چرخه Fetch

</div>


<div class="stat">

<strong>
OK
</strong>

<a href="/self-test">
تست سیستم
</a>

</div>


<div class="stat">

<strong>
<a href="/configs">
مشاهده
</a>
</strong>

کانفیگ‌های دریافت‌شده

</div>


<div class="stat">

<strong>
<a href="/settings">
تنظیمات
</a>
</strong>

⚙️ مدیریت مرکزی پروژه

</div>


<div class="stat">

<strong>
<a href="/fetch-now">
Fetch Now
</a>
</strong>

اجرای فوری Fetch

</div>

</div>


<!-- UI19.5 DASHBOARD INDICATORS -->
<div class="grid">


<div class="stat health-ui-status-card {policy_age_class}">
<div class="health-ui-title">
تازگی Policy
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(policy_age_text)}
</strong>
</div>
</div>


<div class="stat health-ui-status-card {tracker_age_class}">
<div class="health-ui-title">
تازگی Tracker
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(tracker_age_text)}
</strong>
</div>
</div>


<div class="stat health-ui-status-card {sync_age_class}">
<div class="health-ui-title">
تازگی Sync
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(sync_age_text)}
</strong>
</div>
</div>


<div class="stat health-ui-status-card {watchdog_age_class}">
<div class="health-ui-title">
تازگی Watchdog
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(watchdog_age_text)}
</strong>
</div>
</div>


<div class="stat health-ui-status-card {global_freeze_class}">
<div class="health-ui-title">
Global Freeze
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(global_freeze_text)}
</strong>
</div>
</div>


<div class="stat health-ui-status-card {warning_count_class}">
<div class="health-ui-title">
هشدارها
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(lifecycle_warning_count)}
</strong>
</div>
</div>


</div>


<!-- UI19.2 SAFE CARDS -->
<div class="grid">


<div class="stat">
<strong>
{esc(
    lifecycle_policy.get(
        "healthy",
        0,
    )
)}
</strong>
سالم
</div>


<div class="stat">
<strong>
{esc(
    lifecycle_policy.get(
        "recovered",
        0,
    )
)}
</strong>
بازیابی‌شده
</div>


<div class="stat">
<strong>
{esc(
    lifecycle_policy.get(
        "publish_eligible",
        0,
    )
)}
</strong>
قابل انتشار
</div>


<div class="stat">
<strong>
{esc(
    lifecycle_policy.get(
        "quarantine",
        0,
    )
)}
</strong>
قرنطینه
</div>


<div class="stat">
<strong>
{esc(
    lifecycle_policy.get(
        "deep_quarantine",
        0,
    )
)}
</strong>
قرنطینه عمیق
</div>


<div class="stat">
<strong>
{esc(
    lifecycle_policy.get(
        "delete_candidate_shadow",
        0,
    )
)}
</strong>
کاندید حذف
</div>


<div class="stat health-ui-status-card {lifecycle_state_class}">
<div class="health-ui-title">
Lifecycle
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(lifecycle_state_fa)}
</strong>
</div>
</div>


<div class="stat health-ui-status-card {lifecycle_sync_class}">
<div class="health-ui-title">
Sync
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(lifecycle_sync_fa)}
</strong>
</div>
</div>


<div class="stat health-ui-status-card {lifecycle_watchdog_class}">
<div class="health-ui-title">
Watchdog
</div>
<div class="health-ui-line">
<span class="health-ui-dot"></span>
<strong class="health-ui-value">
{esc(lifecycle_watchdog_fa)}
</strong>
</div>
</div>


<div class="stat">
<strong>
<a href="/lifecycle">
جزئیات سلامت
</a>
</strong>
سلامت و چرخه عمر
</div>


</div>


<div class="card">

<h3>
افزودن Source
</h3>

<form
 method="post"
 action="/source/add"
>

<p>

<label>
نام اختیاری
</label>

<input
 name="name"
 placeholder="مثلاً Hot"
>

</p>


<p>

<label>
URL
</label>

<input
 name="url"
 dir="ltr"
 required
 placeholder="https://example.com/sub"
>

</p>


<p>

<label>
فاصله Fetch بر حسب ثانیه
</label>

<input
 name="interval"
 type="number"
 min="10"
 max="86400"
 value="60"
>

</p>


<button type="submit">
افزودن Source
</button>

</form>

</div>


<div class="card">

<h3>
افزودن گروهی Source ها
</h3>

<p style="color:#64748b">
هر URL را در یک خط وارد کن.
لینک‌های تکراری خودکار ادغام می‌شوند.
</p>

<form
 method="post"
 action="/source/bulk-add"
>

<p>

<label>
لیست URL ها
</label>

<textarea
 name="urls"
 required
 placeholder="https://example.com/sub1&#10;https://example.com/sub2&#10;https://example.com/sub3"
></textarea>

</p>


<p>

<label>
فاصله Fetch برای همه لینک‌ها
</label>

<input
 name="interval"
 type="number"
 min="10"
 max="86400"
 value="60"
>

</p>


<div class="notice">

تمام Source ها به صورت خودکار فعال هستند.
تشخیص نوع Source نیز توسط Fetch Engine
انجام خواهد شد.

</div>

<br>

<button type="submit">
افزودن گروهی Source ها
</button>

</form>

</div>


<div class="card">

<h3>
Source ها
</h3>


<form
 id="sources-form"
 method="post"
 action="/source/delete-selected"
>


<div class="source-tools">


<button
 type="button"
 class="secondary"

 onclick="
    document
    .querySelectorAll(
        '.source-checkbox'
    )
    .forEach(
        function(box) {{
            box.checked = true;
        }}
    );
 "
>
انتخاب همه
</button>


<button
 type="button"
 class="secondary"

 onclick="
    document
    .querySelectorAll(
        '.source-checkbox'
    )
    .forEach(
        function(box) {{
            box.checked = false;
        }}
    );
 "
>
لغو انتخاب
</button>


<button
 type="submit"
 class="red"

 onclick="
    const count =
        document
        .querySelectorAll(
            '.source-checkbox:checked'
        ).length;

    if (count === 0) {{
        alert(
            'ابتدا حداقل یک Source را انتخاب کن.'
        );

        return false;
    }}

    return confirm(
        count
        + ' Source انتخاب شده حذف شود؟'
    );
 "
>
حذف انتخاب‌شده‌ها
</button>

</div>


<div class="source-card-grid">

{rows_html}

</div>


<br>


<button
 type="submit"
 class="red"

 onclick="
    const count =
        document
        .querySelectorAll(
            '.source-checkbox:checked'
        ).length;

    if (count === 0) {{
        alert(
            'ابتدا حداقل یک Source را انتخاب کن.'
        );

        return false;
    }}

    return confirm(
        count
        + ' Source انتخاب شده حذف شود؟'
    );
 "
>
حذف انتخاب‌شده‌ها
</button>


</form>


<hr
 style="
    margin:20px 0;
    border:0;
    border-top:1px solid #e2e8f0;
 "
>


<form
 method="post"
 action="/source/delete-all"
>

<button
 type="submit"
 class="red"

 onclick="
    return confirm(
        'هشدار: تمام Source ها حذف شوند؟'
    );
 "
>
حذف همه لینک‌ها
</button>

</form>


</div>
"""

    return page(
        "Config Location",
        content
    )


# ============================================================
# ADD SOURCE
# ============================================================

async def source_add(
    request
):
    data = await request.post()

    try:
        _, duplicate = add_source(
            url=data.get(
                "url",
                ""
            ),

            name=data.get(
                "name",
                ""
            ),

            interval=data.get(
                "interval",
                "60"
            ),
        )

        if duplicate:
            redirect_home(
                "این URL از قبل وجود داشت و ادغام شد."
            )

        redirect_home(
            "Source با موفقیت اضافه شد."
        )

    except web.HTTPException:
        raise

    except Exception as e:
        redirect_home(
            error=str(e)
        )


# ============================================================
# BULK ADD
# ============================================================

async def source_bulk_add(
    request
):
    data = await request.post()

    raw_urls = str(
        data.get(
            "urls",
            ""
        )
    )

    lines = (
        raw_urls.splitlines()
    )

    try:
        result = add_sources_bulk(
            urls=lines,

            interval=data.get(
                "interval",
                "60"
            ),

            fetch_mode="auto",
            enabled=True,
            fetch_immediately=True,
        )

        redirect_home(
            "افزودن گروهی انجام شد | "
            f"جدید: {result['added']} | "
            f"ادغام: {result['merged']} | "
            f"نامعتبر: {result['invalid']}"
        )

    except web.HTTPException:
        raise

    except Exception as e:
        redirect_home(
            error=str(e)
        )


# ============================================================
# EDIT
# ============================================================

async def source_edit_page(
    request
):
    source_id = request.match_info[
        "source_id"
    ]

    src = get_source(
        source_id
    )

    if not src:
        raise web.HTTPNotFound()

    content = f"""

<div class="card">

<h3>
ویرایش Source
</h3>


<form
 method="post"
 action="/source/{esc(source_id)}/edit"
>


<p>

<label>
نام
</label>

<input
 name="name"
 value="{esc(
    src.get(
        'name'
    )
)}"
>

</p>


<p>

<label>
URL
</label>

<input
 name="url"
 dir="ltr"
 required

 value="{esc(
    src.get(
        'url'
    )
)}"
>

</p>


<p>

<label>
Fetch Interval
</label>

<input
 name="interval"
 type="number"
 min="10"
 max="86400"

 value="{esc(
    src.get(
        'fetch_interval_seconds',
        60
    )
)}"
>

</p>


<button type="submit">
ذخیره
</button>


<a
 class="button secondary"
 href="/"
>
بازگشت
</a>

</form>

</div>
"""

    return page(
        "ویرایش Source",
        content
    )


async def source_edit_post(
    request
):
    source_id = request.match_info[
        "source_id"
    ]

    data = await request.post()

    try:
        edit_source(
            source_id=source_id,

            url=data.get(
                "url",
                ""
            ),

            name=data.get(
                "name",
                ""
            ),

            interval=data.get(
                "interval",
                "60"
            ),
        )

        redirect_home(
            "Source با موفقیت ویرایش شد."
        )

    except web.HTTPException:
        raise

    except Exception as e:
        redirect_home(
            error=str(e)
        )


# ============================================================
# INDIVIDUAL ACTIONS
# ============================================================

async def source_delete_handler(
    request
):
    source_id = request.match_info[
        "source_id"
    ]

    deleted = delete_source(
        source_id
    )

    if deleted:
        redirect_home(
            "Source حذف شد."
        )

    redirect_home(
        error="Source پیدا نشد."
    )


async def source_toggle_handler(
    request
):
    source_id = request.match_info[
        "source_id"
    ]

    src = get_source(
        source_id
    )

    if not src:
        redirect_home(
            error="Source پیدا نشد."
        )

    set_enabled(
        source_id,
        not bool(
            src.get(
                "enabled"
            )
        )
    )

    redirect_home(
        "وضعیت Source تغییر کرد."
    )


# ============================================================
# BULK DELETE
# ============================================================

async def source_delete_selected(
    request
):
    data = await request.post()

    selected = data.getall(
        "source_ids",
        []
    )

    if not selected:
        redirect_home(
            error=(
                "هیچ Source ای "
                "انتخاب نشده است."
            )
        )

    deleted = delete_sources(
        selected
    )

    redirect_home(
        f"{deleted} Source حذف شد."
    )


async def source_delete_all(
    request
):
    deleted = (
        delete_all_sources()
    )

    redirect_home(
        f"{deleted} Source حذف شد."
    )


# ============================================================
# FETCH / CONFIG VIEW
# ============================================================

async def source_rebuild(
    request
):
    source_id = str(
        request.match_info.get(
            "source_id"
        )
        or ""
    ).strip()

    source = get_source(
        source_id
    )

    if not source:
        redirect_home(
            error="Source پیدا نشد."
        )

    source_name = (
        source.get("name")
        or source_id
    )

    enabled = bool(
        source.get(
            "enabled",
            True,
        )
    )

    try:

        # ----------------------------------------------------
        # 1. Ownership + Snapshot
        # ----------------------------------------------------

        clear_result = (
            clear_source_owned_data(
                source_id
            )
        )

        # ----------------------------------------------------
        # 2. Runtime
        # ----------------------------------------------------

        reset_source_runtime_state(
            source_id
        )

        # ----------------------------------------------------
        # 3. Immediate independent fetch
        # ----------------------------------------------------

        triggered = False

        if enabled:

            trigger_one_source_fetch(
                source_id
            )

            triggered = True

    except Exception as e:

        redirect_home(
            error=(
                "Rebuild Source ناموفق بود: "
                + str(e)
            )
        )

    detach_result = (
        clear_result.get(
            "detach_result"
        )
        if isinstance(
            clear_result,
            dict
        )
        else None
    )

    details = []

    if isinstance(
        detach_result,
        dict
    ):

        for key, label in (
            ("detached", "Detached"),
            ("deleted", "Deleted"),
            ("kept_shared", "Shared kept"),
        ):

            value = detach_result.get(
                key
            )

            if value is not None:
                details.append(
                    f"{label}={value}"
                )

    if triggered:

        details.append(
            "Fetch=triggered"
        )

    else:

        details.append(
            "Fetch=skipped(disabled)"
        )

    msg = (
        f"Rebuild برای Source «{source_name}» انجام شد."
    )

    if details:
        msg += " " + " / ".join(
            details
        )

    redirect_home(
        msg
    )


async def source_clear_data(
    request
):
    source_id = str(
        request.match_info.get(
            "source_id"
        )
        or ""
    ).strip()

    source = get_source(
        source_id
    )

    if not source:

        redirect_home(
            error="Source پیدا نشد."
        )

    try:

        result = clear_source_owned_data(
            source_id
        )

        # Clear transient runtime state as well.
        #
        # Source itself remains registered.
        try:
            reset_source_runtime_state(
                source_id
            )
        except Exception:
            pass

    except Exception as e:

        redirect_home(
            error=(
                "پاک‌سازی داده‌های Source ناموفق بود: "
                + str(e)
            )
        )

    detach_result = result.get(
        "detach_result"
    )

    msg = (
        "داده‌های Source "
        f"«{source.get('name') or source_id}» "
        "پاک‌سازی شد. "
        "خود Source باقی مانده است."
    )

    if isinstance(
        detach_result,
        dict
    ):

        detached = detach_result.get(
            "detached"
        )

        deleted = detach_result.get(
            "deleted"
        )

        kept_shared = detach_result.get(
            "kept_shared"
        )

        details = []

        if detached is not None:
            details.append(
                f"Detached={detached}"
            )

        if deleted is not None:
            details.append(
                f"Deleted={deleted}"
            )

        if kept_shared is not None:
            details.append(
                f"Shared kept={kept_shared}"
            )

        if details:
            msg += " " + " / ".join(
                details
            )

    redirect_home(
        msg
    )


async def source_reset_runtime(
    request
):
    source_id = str(
        request.match_info.get(
            "source_id"
        )
        or ""
    ).strip()

    source = get_source(
        source_id
    )

    if not source:

        redirect_home(
            error="Source پیدا نشد."
        )

    try:

        reset_source_runtime_state(
            source_id
        )

    except Exception as e:

        redirect_home(
            error=(
                "Reset Runtime ناموفق بود: "
                + str(e)
            )
        )

    redirect_home(
        "Runtime فقط برای Source "
        f"«{source.get('name') or source_id}» "
        "ریست شد."
    )


async def source_fetch_now(
    request
):
    source_id = str(
        request.match_info.get(
            "source_id"
        )
        or ""
    ).strip()

    source = get_source(
        source_id
    )

    if not source:

        redirect_home(
            error="Source پیدا نشد."
        )

    trigger_dir = Path(
        "/var/lib/config-location/source-triggers"
    )

    trigger_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    trigger = (
        trigger_dir
        / f"{source_id}.trigger"
    )

    tmp = trigger.with_suffix(
        ".tmp"
    )

    tmp.write_text(
        str(
            time.time()
        ),
        encoding="utf-8",
    )

    os.replace(
        tmp,
        trigger,
    )

    redirect_home(
        "Fetch فوری فقط برای Source "
        f"«{source.get('name') or source_id}» "
        "ثبت شد."
    )


async def fetch_now(request):

    trigger = Path(
        "/var/lib/config-location/state/fetch-now.trigger"
    )

    trigger.write_text(
        str(time.time()),
        encoding="utf-8"
    )

    redirect_home(
        "درخواست Fetch فوری ثبت شد."
    )


async def configs_page(request):

    from app.core.config_store import (
        list_configs,
        config_stats,
    )

    items = list_configs()
    info = config_stats()

    rows = []

    for item in items[:1000]:

        raw = str(
            item.get(
                "raw",
                ""
            )
        )

        preview = (
            raw
            if len(raw) <= 180
            else raw[:180] + "..."
        )

        rows.append(
            f"""
<tr>
<td>{esc(item.get("type"))}</td>
<td>{esc(item.get("last_seen_at"))}</td>
<td>{len(item.get("source_ids", []))}</td>
<td class="url">{esc(preview)}</td>
</tr>
"""
        )

    type_text = " | ".join(
        f"{esc(k)}: {v}"
        for k, v
        in sorted(
            info["types"].items()
        )
    )

    content = f"""

<div class="card">

<h2>
کانفیگ‌های دریافت‌شده
</h2>

<p>
<strong>
کل Unique:
{info["total"]}
</strong>
</p>

<p>
{type_text or "-"}
</p>

<a
 class="button secondary"
 href="/"
>
بازگشت
</a>

</div>


<div class="card">

<div class="table-wrap">

<table>

<thead>
<tr>
<th>نوع</th>
<th>آخرین مشاهده</th>
<th>تعداد Source</th>
<th>Config</th>
</tr>
</thead>

<tbody>
{"".join(rows)}
</tbody>

</table>

</div>

</div>
"""

    return page(
        "Configs",
        content
    )



# ============================================================
# HEALTH
# ============================================================

async def health(
    request
):
    return web.json_response({
        "status": "ok",
        "project": "config-location",
        "component": "panel",
        "port": PORT,
        "source_actions": "fixed",
    })


# ============================================================
# API
# ============================================================

async def api_sources(
    request
):
    return web.json_response({
        "sources":
            list_sources(),

        "stats":
            stats(),

        "fetcher":
            get_fetcher_status(),
    })



# ============================================================
# PANEL_A3_COUNTRY_API
# Country / Config read-only APIs
# ============================================================

async def api_country_summary(
    request
):
    from app.panel.read_model import (
        dashboard_summary,
    )

    return web.json_response(
        dashboard_summary()
    )


async def api_configs(
    request
):
    from app.panel.read_model import (
        query_configs,
    )

    q=request.rel_url.query

    def as_int(
        key,
        default,
    ):
        try:
            return int(
                q.get(
                    key,
                    default,
                )
            )
        except (
            TypeError,
            ValueError,
        ):
            return default


    unresolved_raw=str(
        q.get(
            "unresolved",
            "",
        )
    ).strip().lower()

    unresolved_only=(
        unresolved_raw
        in {
            "1",
            "true",
            "yes",
            "on",
        }
    )


    result=query_configs(
        search=str(
            q.get(
                "q",
                "",
            )
        ),

        config_type=str(
            q.get(
                "type",
                "",
            )
        ),

        health_status=str(
            q.get(
                "health",
                "",
            )
        ),

        country_code=str(
            q.get(
                "country",
                "",
            )
        ),

        country_state=str(
            q.get(
                "state",
                "",
            )
        ),

        unresolved_only=
            unresolved_only,

        offset=as_int(
            "offset",
            0,
        ),

        limit=as_int(
            "limit",
            100,
        ),
    )

    return web.json_response(
        result
    )


async def api_country_unresolved(
    request
):
    from app.panel.read_model import (
        query_configs,
    )

    q=request.rel_url.query

    try:
        offset=int(
            q.get(
                "offset",
                0,
            )
        )
    except (
        TypeError,
        ValueError,
    ):
        offset=0

    try:
        limit=int(
            q.get(
                "limit",
                100,
            )
        )
    except (
        TypeError,
        ValueError,
    ):
        limit=100


    result=query_configs(
        search=str(
            q.get(
                "q",
                "",
            )
        ),

        config_type=str(
            q.get(
                "type",
                "",
            )
        ),

        health_status=str(
            q.get(
                "health",
                "",
            )
        ),

        country_state=str(
            q.get(
                "state",
                "",
            )
        ),

        unresolved_only=True,

        offset=offset,

        limit=limit,
    )

    return web.json_response(
        result
    )



async def api_config_detail(
    request
):
    from app.panel.read_model import (
        config_detail,
    )

    config_id=str(
        request.match_info.get(
            "config_id",
            "",
        )
    ).strip()

    data=config_detail(
        config_id
    )

    if data is None:
        return web.json_response(
            {
                "error":
                    "config_not_found",

                "config_id":
                    config_id,
            },
            status=404,
        )

    return web.json_response(
        data
    )



async def api_operations_summary(
    request
):
    from app.panel.operations_read_model import (
        operations_summary,
    )

    return web.json_response(
        operations_summary()
    )


async def api_xray_failures(
    request
):
    from app.panel.operations_read_model import (
        xray_failure_summary,
    )

    try:
        limit=int(
            request.rel_url.query.get(
                "limit",
                100,
            )
        )
    except (
        TypeError,
        ValueError,
    ):
        limit=100

    return web.json_response(
        xray_failure_summary(
            limit=limit,
        )
    )


async def api_xray_failure_detail(
    request
):
    from app.panel.operations_read_model import (
        xray_failure_detail,
    )

    bundle_id=str(
        request.match_info.get(
            "bundle_id",
            "",
        )
    )

    data=xray_failure_detail(
        bundle_id
    )

    if data is None:

        return web.json_response(
            {
                "error":
                    "failure_bundle_not_found",
            },
            status=404,
        )

    return web.json_response(
        data
    )



async def api_publish_summary(
    request
):
    from app.panel.publish_read_model import (
        publish_summary,
    )

    return web.json_response(
        publish_summary()
    )


# ============================================================
# SELF TEST
# ============================================================

async def self_test(
    request
):
    tests = []

    def add(
        name,
        ok,
        info=""
    ):
        tests.append({
            "name": name,
            "ok": bool(ok),
            "info": str(info),
        })

    try:
        current = list_sources()

        add(
            "Source database",
            isinstance(
                current,
                list
            ),
            f"{len(current)} sources"
        )

    except Exception as e:
        add(
            "Source database",
            False,
            e
        )

    try:
        test_path = Path(
            "/var/lib/config-location/state/panel-self-test.tmp"
        )

        test_path.write_text(
            "OK",
            encoding="utf-8"
        )

        result = (
            test_path.read_text(
                encoding="utf-8"
            )
            == "OK"
        )

        test_path.unlink(
            missing_ok=True
        )

        add(
            "Storage write",
            result
        )

    except Exception as e:
        add(
            "Storage write",
            False,
            e
        )

    add(
        "Authentication",
        is_authenticated(
            request
        )
    )

    rows = ""

    for test in tests:
        rows += f"""
<tr>

<td>
{esc(test["name"])}
</td>

<td>
{
"✅ OK"
if test["ok"]
else
"❌ FAIL"
}
</td>

<td>
{esc(test["info"])}
</td>

</tr>
"""

    passed = all(
        test["ok"]
        for test in tests
    )

    content = f"""

<div class="card">

<h2>
{
"✅ SYSTEM TEST PASSED"
if passed
else
"❌ SYSTEM TEST FAILED"
}
</h2>

<table>

<thead>
<tr>
<th>Test</th>
<th>Status</th>
<th>Details</th>
</tr>
</thead>

<tbody>
{rows}
</tbody>

</table>

<br>

<a
 class="button"
 href="/"
>
بازگشت
</a>

</div>
"""

    return page(
        "System Test",
        content
    )


# ============================================================
# APPLICATION
# ============================================================

def create_app():

    app = web.Application(
        middlewares=[
            auth_middleware
        ]
    )

    app.router.add_get(
        "/login",
        login_page
    )

    app.router.add_post(
        "/login",
        login_post
    )

    app.router.add_get(
        "/logout",
        logout
    )

    app.router.add_get(
        "/",
        dashboard
    )

    app.router.add_get(
        "/health",
        health
    )

    app.router.add_get(
        "/devlog/{token}",
        devlog_handler
    )

    app.router.add_get(
        "/api/sources",
        api_sources
    )

    # PANEL_A3_COUNTRY_API routes
    app.router.add_get(
        "/api/country/summary",
        api_country_summary
    )

    app.router.add_get(
        "/api/configs",
        api_configs
    )

    app.router.add_get(
        "/api/country/unresolved",
        api_country_unresolved
    )

    app.router.add_get(
        "/self-test",
        self_test
    )

    app.router.add_get(
        "/configs",
        configs_page
    )

    app.router.add_get(
        "/country",
        country_page
    )

    app.router.add_get(
        "/config/{config_id}",
        config_detail_page
    )

    app.router.add_get(
        "/api/config/{config_id}",
        api_config_detail
    )

    app.router.add_get(
        "/operations",
        operations_page
    )

    app.router.add_get(
        "/api/operations/summary",
        api_operations_summary
    )

    app.router.add_get(
        "/api/xray/failures",
        api_xray_failures
    )

    app.router.add_get(
        "/api/xray/failure/{bundle_id}",
        api_xray_failure_detail
    )

    app.router.add_get(
        "/publish",
        publish_page
    )

    app.router.add_get(
        "/api/publish/summary",
        api_publish_summary
    )

    app.router.add_get(
        "/fetch-now",
        fetch_now
    )


    # --------------------------------------------
    # Bulk routes
    # --------------------------------------------

    app.router.add_post(
        "/source/bulk-add",
        source_bulk_add
    )

    app.router.add_post(
        "/source/delete-selected",
        source_delete_selected
    )

    app.router.add_post(
        "/source/delete-all",
        source_delete_all
    )


    # --------------------------------------------
    # Single source
    # --------------------------------------------

    app.router.add_post(
        "/source/add",
        source_add
    )

    app.router.add_post(
        "/source/{source_id}/rebuild",
        source_rebuild
    )

    app.router.add_post(
        "/source/{source_id}/clear-data",
        source_clear_data
    )

    app.router.add_post(
        "/source/{source_id}/reset-runtime",
        source_reset_runtime
    )

    app.router.add_post(
        "/source/{source_id}/fetch-now",
        source_fetch_now
    )

    app.router.add_get(
        "/source/{source_id}/edit",
        source_edit_page
    )

    app.router.add_post(
        "/source/{source_id}/edit",
        source_edit_post
    )

    app.router.add_post(
        "/source/{source_id}/delete",
        source_delete_handler
    )

    app.router.add_post(
        "/source/{source_id}/toggle",
        source_toggle_handler
    )



    # PHASE1 Central Settings Engine
    install_settings_routes(app)


    # HT17 Adaptive Health routes
    install_aiohttp_routes(app)


    # HT18.3 Production Publish Filter
    install_publish_routes(app)


    # HT18.8 Lifecycle Observability
    install_lifecycle_observability_routes(app)

    install_control_routes(app)

    return app


if __name__ == "__main__":

    web.run_app(
        create_app(),
        host="0.0.0.0",
        port=PORT,
        access_log=None,
    )
