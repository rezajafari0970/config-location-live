from __future__ import annotations


import html


def render_page(
    title: str,
    content: str
):

    return f"""
<!doctype html>

<html>

<head>

<meta charset="utf-8">

<title>{html.escape(title)}</title>


<style>

body {{
font-family: sans-serif;
background:#f5f7fb;
padding:20px;
}}

.card {{
background:white;
border-radius:12px;
padding:20px;
margin-bottom:15px;
box-shadow:0 2px 8px #ddd;
}}

input {{
width:100%;
padding:10px;
margin:8px 0;
}}

button {{
padding:12px 20px;
border:0;
border-radius:8px;
background:#2563eb;
color:white;
}}

</style>


</head>


<body>


<h1>
{html.escape(title)}
</h1>


{content}


</body>

</html>
"""
