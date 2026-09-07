from __future__ import annotations

import html
import os

from aiohttp import web


UNIFIED_PANEL_SHELL_V1 = True


def _esc(value) -> str:
    return html.escape(str(value if value is not None else ""))


def _active_from_title(title: str) -> str:
    value = str(title or "").lower()
    if "setting" in value:
        return "settings"
    if "country" in value:
        return "country"
    if "publish" in value or "subscription" in value:
        return "publish"
    if "config" in value and "detail" in value:
        return "configs"
    return "dashboard"


def _nav_item(href: str, label: str, key: str, active: str) -> str:
    state = " shell-nav-active" if key == active else ""
    current = ' aria-current="page"' if key == active else ""
    return (
        f'<a class="shell-nav-item{state}" '
        f'href="{_esc(href)}"{current}>'
        f'{_esc(label)}</a>'
    )


def _navigation(active: str) -> str:
    # Intentionally no /operations or /lifecycle in user-facing navigation.
    items = (
        ("/", "داشبورد", "dashboard"),
        ("/settings", "تنظیمات", "settings"),
        ("/country", "کشورها", "country"),
        ("/publish", "انتشار", "publish"),
    )
    return "".join(
        _nav_item(href, label, key, active)
        for href, label, key in items
    )


def page(
    title: str,
    content: str,
    show_header: bool = True,
    *,
    port: int | None = None,
    active: str | None = None,
) -> web.Response:

    if port is None:
        try:
            port = int(os.environ.get("CONFIGLOC_PORT", "4040"))
        except Exception:
            port = 4040

    active = str(active) if active else _active_from_title(title)

    shell_header = ""
    if show_header:
        shell_header = f"""
<header class="shell-header" data-unified-shell="v1">
  <div class="shell-header-inner">
    <div class="shell-brand">
      <div class="shell-brand-mark">CL</div>
      <div>
        <div class="shell-brand-title">Config Location</div>
        <div class="shell-brand-subtitle">Management Panel • Port {_esc(port)}</div>
      </div>
    </div>
    <a class="button secondary shell-logout" href="/logout">خروج</a>
  </div>
  <nav class="shell-nav" aria-label="Main navigation">
    <div class="shell-nav-scroll">{_navigation(active)}</div>
  </nav>
</header>
"""

    body_content = (
        f'<main class="container shell-main">{content}</main>'
        if show_header
        else content
    )

    document = f"""<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#f97316">
<title>{_esc(title)}</title>
<style>
* {{ box-sizing:border-box; }}
:root {{
    --orange:#f97316; --orange-dark:#ea580c; --orange-soft:#fff7ed;
    --bg:#f8fafc; --card:#ffffff; --border:#e2e8f0;
    --text:#1e293b; --muted:#64748b;
    --green:#16a34a; --red:#dc2626; --yellow:#d97706;
    --blue:#2563eb; --gray:#64748b;
    --radius:14px; --shadow:0 3px 12px rgba(15,23,42,.05);
}}
html {{ min-height:100%; background:var(--bg); }}
body {{
    margin:0; min-height:100vh; background:var(--bg); color:var(--text);
    font-family:Tahoma,Arial,sans-serif; -webkit-text-size-adjust:100%;
}}
a {{ color:inherit; }}
.shell-header {{
    position:sticky; top:0; z-index:100; background:rgba(255,255,255,.97);
    border-bottom:1px solid var(--border);
    box-shadow:0 2px 10px rgba(15,23,42,.05); backdrop-filter:blur(10px);
}}
.shell-header-inner {{
    max-width:1300px; margin:0 auto; padding:12px 14px 9px;
    display:flex; align-items:center; justify-content:space-between; gap:12px;
}}
.shell-brand {{ min-width:0; display:flex; align-items:center; gap:10px; }}
.shell-brand-mark {{
    width:38px; height:38px; flex:0 0 38px; border-radius:11px;
    background:linear-gradient(145deg,var(--orange),var(--orange-dark));
    color:#fff; display:flex; align-items:center; justify-content:center;
    font-weight:800; font-size:13px; box-shadow:0 5px 15px rgba(249,115,22,.22);
}}
.shell-brand-title {{ color:var(--orange-dark); font-weight:800; font-size:18px; line-height:1.35; }}
.shell-brand-subtitle {{ color:var(--muted); font-size:11px; margin-top:2px; }}
.shell-nav {{ border-top:1px solid #f1f5f9; }}
.shell-nav-scroll {{
    max-width:1300px; margin:0 auto; display:flex; align-items:center; gap:6px;
    padding:7px 12px 9px; overflow-x:auto; overscroll-behavior-inline:contain;
    scrollbar-width:none;
}}
.shell-nav-scroll::-webkit-scrollbar {{ display:none; }}
.shell-nav-item {{
    flex:0 0 auto; min-height:36px; display:inline-flex; align-items:center;
    justify-content:center; padding:7px 12px; border:1px solid transparent;
    border-radius:10px; text-decoration:none; color:#475569; font-size:13px;
    font-weight:700; white-space:nowrap;
}}
.shell-nav-item:hover {{ background:#f8fafc; border-color:var(--border); }}
.shell-nav-active {{ color:#9a3412; background:var(--orange-soft); border-color:#fed7aa; }}
.container {{ max-width:1300px; margin:18px auto; padding:0 10px; }}
.shell-main {{ width:100%; }}
.card {{
    background:var(--card); border:1px solid var(--border); border-radius:var(--radius);
    padding:16px; margin-bottom:15px; box-shadow:var(--shadow);
}}
.card > :first-child {{ margin-top:0; }}
.grid {{
    display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
    gap:9px; margin-bottom:15px;
}}
.stat {{
    min-width:0; background:var(--orange-soft); border:1px solid #fed7aa;
    border-radius:12px; padding:14px;
}}
.stat strong {{
    color:var(--orange-dark); display:block; font-size:22px; overflow-wrap:anywhere;
}}
input, select, textarea {{
    width:100%; max-width:100%; border:1px solid #cbd5e1; border-radius:9px;
    padding:10px; background:#fff; color:var(--text); font:inherit;
}}
input:focus, select:focus, textarea:focus {{
    outline:none; border-color:var(--orange); box-shadow:0 0 0 3px rgba(249,115,22,.12);
}}
textarea {{
    min-height:160px; resize:vertical; direction:ltr; font-family:monospace;
}}
label {{ display:block; margin:10px 0 6px; }}
button, .button {{
    min-height:38px; background:var(--orange); color:#fff; border:0; border-radius:9px;
    padding:9px 13px; text-decoration:none; cursor:pointer; display:inline-flex;
    align-items:center; justify-content:center; gap:6px; font:inherit;
}}
button:hover, .button:hover {{ opacity:.92; }}
.secondary {{ background:var(--gray); }}
.red {{ background:var(--red); }}
.green {{ background:var(--green); }}
.msg, .notice {{ padding:11px; margin-bottom:12px; border-radius:9px; }}
.msg {{ background:#f0fdf4; border:1px solid #86efac; color:#166534; }}
.notice {{ color:#9a3412; background:#fff7ed; border:1px solid #fed7aa; }}
.notice.success {{ color:#166534; background:#f0fdf4; border-color:#86efac; }}
.error, .notice.error {{ background:#fef2f2; border-color:#fecaca; color:#991b1b; }}
.table-wrap {{ width:100%; overflow:auto; border-radius:10px; }}
table {{ width:100%; border-collapse:collapse; min-width:760px; }}
th, td {{
    border-bottom:1px solid var(--border); padding:10px 8px;
    text-align:right; vertical-align:middle;
}}
th {{ background:var(--orange-soft); color:#9a3412; }}
.url {{ direction:ltr; text-align:left; word-break:break-all; }}
.actions {{ white-space:nowrap; }}
.actions button, .actions a {{ margin:2px; }}
.source-tools {{ display:flex; gap:7px; flex-wrap:wrap; margin-bottom:12px; }}
.select-box {{ width:18px; height:18px; accent-color:var(--orange); }}
.login-wrap {{
    min-height:100vh; display:flex; align-items:center; justify-content:center; padding:20px;
}}
.login-card {{
    width:100%; max-width:420px; background:#fff; border:1px solid #fed7aa;
    border-top:5px solid var(--orange); border-radius:17px; padding:24px;
    box-shadow:0 12px 35px rgba(249,115,22,.12);
}}
.login-card h2 {{ color:var(--orange-dark); }}
.remember {{ display:flex; gap:8px; align-items:center; margin:15px 0; }}
.remember input {{ width:18px; height:18px; accent-color:var(--orange); }}
.health-ui-status-card {{
    position:relative; overflow:hidden; min-height:72px; display:flex;
    flex-direction:column; justify-content:center;
}}
.health-ui-title {{ text-align:center; font-size:13px; color:var(--muted); margin-bottom:9px; }}
.health-ui-line {{ display:flex; align-items:center; justify-content:center; gap:9px; }}
.health-ui-dot {{ width:12px; height:12px; min-width:12px; border-radius:50%; }}
.health-ui-value {{ font-size:16px !important; margin:0; }}
.health-ui-ok {{ background:#f0fdf4 !important; border-color:#86efac !important; }}
.health-ui-ok .health-ui-dot {{ background:#16a34a; box-shadow:0 0 0 5px rgba(22,163,74,.12); }}
.health-ui-ok .health-ui-value {{ color:#15803d; }}
.health-ui-warning {{ background:#fff7ed !important; border-color:#fdba74 !important; }}
.health-ui-warning .health-ui-dot {{ background:#f97316; box-shadow:0 0 0 5px rgba(249,115,22,.12); }}
.health-ui-warning .health-ui-value {{ color:#c2410c; }}
.health-ui-error {{ background:#fef2f2 !important; border-color:#fca5a5 !important; }}
.health-ui-error .health-ui-dot {{ background:#dc2626; box-shadow:0 0 0 5px rgba(220,38,38,.12); }}
.health-ui-error .health-ui-value {{ color:#b91c1c; }}
.health-ui-unknown {{ background:#f8fafc !important; border-color:#cbd5e1 !important; }}
.health-ui-unknown .health-ui-dot {{ background:#64748b; box-shadow:0 0 0 5px rgba(100,116,139,.12); }}
.health-ui-unknown .health-ui-value {{ color:#475569; }}
@media (max-width:720px) {{
    .shell-header-inner {{ padding:10px 10px 7px; }}
    .shell-brand-mark {{ width:34px; height:34px; flex-basis:34px; }}
    .shell-brand-title {{ font-size:16px; }}
    .shell-brand-subtitle {{ font-size:10px; }}
    .shell-logout {{ min-height:34px; padding:7px 10px; font-size:12px; }}
    .shell-nav-scroll {{ padding:6px 8px 8px; }}
    .shell-nav-item {{ min-height:34px; padding:6px 10px; font-size:12px; }}
    .container {{ margin:10px auto 24px; padding:0 8px; }}
    .card {{ padding:12px; margin-bottom:10px; border-radius:12px; }}
    .grid {{ grid-template-columns:repeat(2,minmax(0,1fr)); gap:7px; margin-bottom:10px; }}
    .stat {{ padding:10px; }}
    .stat strong {{ font-size:18px; }}
    table {{ min-width:680px; }}
}}
@media (max-width:390px) {{
    .grid {{ grid-template-columns:1fr; }}
    .shell-brand-subtitle {{ display:none; }}
}}

/* UNIFIED_PANEL_SHELL_V1_MIGRATION_COMPAT */
.metric-name,.metric-title{{color:var(--muted);font-size:12px;margin-bottom:7px}}
.metric-value{{font-size:24px;font-weight:800;line-height:1.2;overflow-wrap:anywhere}}
.metric-sub,.muted,.status-line{{color:var(--muted);font-size:12px}}
.section{{margin-top:14px}}
.section-title,.section h2{{margin:0 0 12px;font-size:16px}}
.detail-grid,.summary-grid,.link-grid{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}}
.summary-grid{{grid-template-columns:repeat(3,minmax(0,1fr))}}
.filters{{display:grid;grid-template-columns:2fr repeat(4,minmax(140px,1fr)) auto;gap:8px}}
.btn{{display:inline-flex;align-items:center;justify-content:center;min-height:38px;padding:8px 12px;border:0;border-radius:9px;background:var(--orange);color:#fff;text-decoration:none;cursor:pointer}}
.btn:hover{{opacity:.92}}
.small-btn{{min-height:34px;padding:5px 9px}}
.top-actions,.pager,.pager-actions{{display:flex;gap:8px;align-items:center;flex-wrap:wrap}}
.sub-link{{display:flex;justify-content:space-between;align-items:center;gap:10px;padding:11px;border:1px solid var(--border);border-radius:10px;background:#fff}}
.sub-link code{{direction:ltr;text-align:left;overflow:auto;word-break:break-all}}
.kv-list{{display:flex;flex-direction:column;gap:7px}}
.kv{{display:flex;align-items:center;justify-content:space-between;gap:12px;border-bottom:1px dashed var(--border);padding:6px 0}}
.kv .key,.kv span{{color:var(--muted)}}
.mono,code,pre{{direction:ltr;text-align:left;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}}
pre{{margin:0;padding:12px;max-height:520px;overflow:auto;white-space:pre-wrap;word-break:break-word;background:#f8fafc;border:1px solid var(--border);border-radius:10px;font-size:12px;line-height:1.5}}
.badge{{display:inline-flex;align-items:center;min-height:25px;padding:3px 8px;border-radius:999px;border:1px solid var(--border);font-size:11px}}
.good,.green{{color:var(--green)!important}}
.metric-value.green,.metric-value.yellow,.metric-value.blue,.metric-value.violet{{background:transparent!important}}
.bad,.red-text{{color:var(--red)!important}}
.warn,.yellow{{color:var(--yellow)!important}}
.info,.blue{{color:var(--blue)!important}}
.violet{{color:#7c3aed!important}}
.error-box{{display:none;margin-bottom:12px;padding:10px 12px;border:1px solid #fecaca;background:#fef2f2;border-radius:10px;color:#991b1b}}
.loading{{opacity:.55;pointer-events:none}}
.empty{{text-align:center;padding:32px!important;color:var(--muted)}}
@media(max-width:1100px){{.filters{{grid-template-columns:repeat(2,minmax(0,1fr))}}.summary-grid{{grid-template-columns:1fr}}}}
@media(max-width:720px){{.detail-grid,.link-grid{{grid-template-columns:1fr}}.filters{{grid-template-columns:1fr}}.metric-value{{font-size:20px}}}}

</style>
</head>
<body data-shell="unified-panel-v1">
{shell_header}
{body_content}
</body>
</html>
"""

    return web.Response(
        text=document,
        content_type="text/html",
        charset="utf-8",
        headers={"Cache-Control": "no-store"},
    )
