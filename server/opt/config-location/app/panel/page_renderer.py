from __future__ import annotations

from aiohttp import web


def page(title: str, content: str) -> web.Response:
    html = f"""<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
body {{
    margin: 0;
    font-family: sans-serif;
    background: #f6f7f9;
    color: #222;
}}
.wrap {{
    max-width: 1180px;
    margin: 0 auto;
    padding: 20px;
}}
.card {{
    background: #fff;
    border: 1px solid #e5e7eb;
    border-radius: 14px;
    padding: 18px;
    margin-bottom: 16px;
}}
</style>
</head>
<body>
<div class="wrap">
{content}
</div>
</body>
</html>"""

    return web.Response(
        text=html,
        content_type="text/html",
        charset="utf-8",
    )
