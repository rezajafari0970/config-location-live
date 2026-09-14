#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"

APP="$PROJECT/backend/app"


echo "======================================"
echo " CONFIG MANAGER"
echo " PHASE 1.2 MODERN UI FOUNDATION"
echo "======================================"



mkdir -p \
"$APP/templates" \
"$APP/static/css" \
"$APP/static/js"



echo "[1] Layout"



cat > "$APP/templates/layout.html" <<'HTML'
<!DOCTYPE html>
<html>

<head>

<meta charset="UTF-8">

<meta name="viewport" content="width=device-width,initial-scale=1">

<title>Config Manager</title>

<link rel="stylesheet" href="/static/css/app.css">

</head>


<body>


<div class="sidebar">

<h2>Config Manager</h2>

<a href="/">Dashboard</a>
<a href="/sources">Sources</a>
<a href="#">Configs</a>
<a href="#">Health</a>
<a href="#">Logs</a>
<a href="#">Settings</a>

</div>



<div class="content">

{% block content %}
{% endblock %}

</div>


<script src="/static/js/app.js"></script>

</body>

</html>
HTML



echo "[2] Dashboard"



cat > "$APP/templates/dashboard.html" <<'HTML'
{% extends "layout.html" %}


{% block content %}


<h1>Dashboard</h1>


<div class="cards">


<div class="card">

<h3>Sources</h3>

<p>{{sources}}</p>

</div>


<div class="card">

<h3>Configs</h3>

<p>{{configs}}</p>

</div>


<div class="card">

<h3>Status</h3>

<p class="ok">Running</p>

</div>


</div>



<div class="panel">

<h2>Recent Activity</h2>

<p>✓ System started</p>

<p>✓ Worker ready</p>

</div>



{% endblock %}
HTML



echo "[3] Sources"



cat > "$APP/templates/sources.html" <<'HTML'
{% extends "layout.html" %}


{% block content %}


<h1>Sources</h1>


<div class="panel">


<form method="post">


<input

name="url"

placeholder="https://example.com/sub/all"

>


<button>Add Source</button>


</form>


</div>



<div class="panel">


{% for item in sources %}

<p class="source">

{{item}}

</p>


{% endfor %}


</div>



{% endblock %}
HTML



echo "[4] CSS"



cat > "$APP/static/css/app.css" <<'CSS'
*{
box-sizing:border-box;
}


body{

margin:0;

font-family:

Arial, sans-serif;

background:#0f172a;

color:white;

display:flex;

min-height:100vh;

}


.sidebar{

width:230px;

background:#111827;

padding:20px;

}


.sidebar a{

display:block;

color:#cbd5e1;

text-decoration:none;

padding:12px;

border-radius:8px;

}


.sidebar a:hover{

background:#1e293b;

}


.content{

flex:1;

padding:30px;

}



.cards{

display:grid;

grid-template-columns:

repeat(auto-fit,minmax(200px,1fr));

gap:20px;

}



.card,.panel{

background:#1e293b;

padding:20px;

border-radius:15px;

margin-bottom:20px;

box-shadow:0 10px 30px #0004;

}



.ok{

color:#22c55e;

}



input{

width:80%;

padding:12px;

border-radius:8px;

border:0;

}



button{

padding:12px 20px;

border:0;

border-radius:8px;

background:#2563eb;

color:white;

}



@media(max-width:700px){

body{

display:block;

}


.sidebar{

width:100%;

}


.content{

padding:15px;

}

}
CSS



echo "[5] JavaScript"



cat > "$APP/static/js/app.js" <<'JS'
console.log("Config Manager UI Loaded");


setTimeout(()=>{

console.log("UI Ready");

},500);

JS



echo "[6] Permission"



chown -R configmanager:configmanager "$PROJECT"



echo

echo "======================================"
echo " UI FOUNDATION COMPLETE"
echo "======================================"

