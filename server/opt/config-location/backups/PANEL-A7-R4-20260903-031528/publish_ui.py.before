from __future__ import annotations

from aiohttp import web


# PANEL_A7_PUBLISH_UI


HTML=r'''<!doctype html>
<html lang="fa" dir="rtl">

<head>

<meta charset="utf-8">

<meta name="viewport"
      content="width=device-width,initial-scale=1">

<title>Publish & Subscriptions</title>

<style>

:root{
    color-scheme:dark;

    --bg:#0b0f14;
    --panel:#111821;
    --panel2:#161f2b;
    --border:#273342;

    --text:#eef4fb;
    --muted:#94a5b8;

    --green:#39d98a;
    --yellow:#f5c451;
    --blue:#55aaff;
    --violet:#a98bff;
    --red:#ff667a;
}

*{
    box-sizing:border-box;
}

body{
    margin:0;
    background:var(--bg);
    color:var(--text);

    font-family:
        system-ui,
        -apple-system,
        BlinkMacSystemFont,
        "Segoe UI",
        sans-serif;
}

.shell{
    width:min(1450px,96%);
    margin:0 auto;
    padding:18px 0 50px;
}

.topbar{
    display:flex;
    justify-content:space-between;
    align-items:flex-start;
    gap:12px;
    margin-bottom:15px;
}

.topbar h1{
    margin:0;
    font-size:22px;
}

.actions{
    display:flex;
    gap:8px;
    flex-wrap:wrap;
}

.btn{
    display:inline-flex;
    align-items:center;
    justify-content:center;

    min-height:40px;
    padding:8px 13px;

    border:1px solid var(--border);
    border-radius:10px;

    background:var(--panel);
    color:var(--text);

    text-decoration:none;
    cursor:pointer;
}

.grid{
    display:grid;
    grid-template-columns:
        repeat(4,minmax(0,1fr));
    gap:12px;
}

.card{
    background:var(--panel);
    border:1px solid var(--border);
    border-radius:14px;
    padding:15px;
}

.metric-name{
    color:var(--muted);
    font-size:12px;
    margin-bottom:7px;
}

.metric-value{
    font-size:24px;
    font-weight:700;
}

.green{color:var(--green)}
.yellow{color:var(--yellow)}
.blue{color:var(--blue)}
.violet{color:var(--violet)}
.red{color:var(--red)}

.section{
    margin-top:14px;
}

.section h2{
    margin:0 0 12px;
    font-size:16px;
}

.link-grid{
    display:grid;
    grid-template-columns:
        repeat(2,minmax(0,1fr));
    gap:10px;
}

.sub-link{
    display:flex;
    justify-content:space-between;
    align-items:center;
    gap:10px;

    padding:11px;

    border:1px solid var(--border);
    border-radius:10px;

    background:#0d131b;
}

.sub-link code{
    direction:ltr;
    text-align:left;
    overflow:auto;
}

.small-btn{
    min-height:34px;
    padding:5px 9px;
}

.kv{
    display:flex;
    justify-content:space-between;
    gap:10px;
    padding:6px 0;

    border-bottom:
        1px dashed var(--border);
}

.kv span{
    color:var(--muted);
}

pre{
    margin:0;
    padding:12px;

    max-height:450px;
    overflow:auto;

    direction:ltr;
    text-align:left;

    white-space:pre-wrap;
    word-break:break-word;

    background:#0b1118;
    border:1px solid var(--border);
    border-radius:10px;

    font-size:12px;
}

@media(max-width:800px){

    .grid{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }

    .link-grid{
        grid-template-columns:1fr;
    }
}

@media(max-width:520px){

    .grid{
        grid-template-columns:1fr;
    }

    .topbar{
        flex-direction:column;
    }
}

</style>

</head>

<body>

<div class="shell">

    <div class="topbar">

        <div>

            <h1>
                📡 Publish & Subscriptions
            </h1>

            <div style="
                color:var(--muted);
                font-size:12px;
                margin-top:5px;
            ">
                Canonical publish view
            </div>

        </div>


        <div class="actions">

            <a class="btn"
               href="/country">
                Country
            </a>

            <a class="btn"
               href="/operations">
                Operations
            </a>

            <a class="btn"
               href="/configs">
                Configs
            </a>

            <a class="btn"
               href="/">
                Dashboard
            </a>

            <button class="btn"
                    id="refresh">
                بروزرسانی
            </button>

        </div>

    </div>


    <div class="grid">

        <div class="card">

            <div class="metric-name">
                Publishable
            </div>

            <div class="metric-value green"
                 id="publishable">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Healthy
            </div>

            <div class="metric-value blue"
                 id="healthy">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Recovered
            </div>

            <div class="metric-value violet"
                 id="recovered">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Subscription Routes
            </div>

            <div class="metric-value yellow"
                 id="routeCount">
                -
            </div>

        </div>

    </div>


    <div class="section card">

        <h2>
            Subscription Links
        </h2>

        <div id="links"
             class="link-grid">
        </div>

    </div>


    <div class="section card">

        <h2>
            Publish Status
        </h2>

        <div id="status">
        </div>

    </div>


    <div class="section card">

        <h2>
            Raw Canonical Status
        </h2>

        <pre id="rawStatus">
-
        </pre>

    </div>

</div>


<script>

"use strict";

const $=id =>
    document.getElementById(id);


function esc(
    value
){

    return String(
        value ?? ""
    )
    .replaceAll("&","&amp;")
    .replaceAll("<","&lt;")
    .replaceAll(">","&gt;")
    .replaceAll('"',"&quot;")
    .replaceAll("'","&#039;");
}


function num(
    value
){

    return Number(
        value || 0
    ).toLocaleString(
        "en-US"
    );
}


async function api(
    url
){

    const response=
        await fetch(
            url,
            {
                credentials:
                    "same-origin",

                cache:
                    "no-store",

                headers:{
                    "Accept":
                        "application/json"
                }
            }
        );


    if(!response.ok){

        throw new Error(
            "HTTP "
            +response.status
        );
    }


    return await response.json();
}


function firstNumber(
    obj,
    keys
){

    for(const key of keys){

        if(
            Object.prototype
            .hasOwnProperty
            .call(
                obj,
                key
            )
        ){

            const n=Number(
                obj[key]
            );

            if(
                Number.isFinite(n)
            ){
                return n;
            }
        }
    }

    return 0;
}


function renderLinks(
    data
){

    const links=[];

    if(
        data.links
        && data.links.all
    ){

        links.push(
            {
                label:"All",
                path:
                    data.links.all,
            }
        );
    }


    for(
        const item
        of (
            data.links?.types
            || []
        )
    ){

        links.push(
            {
                label:
                    item.type,

                path:
                    item.path,
            }
        );
    }


    for(
        const path
        of (
            data.links
            ?.country_templates
            || []
        )
    ){

        links.push(
            {
                label:
                    "Country template",

                path,
            }
        );
    }


    for(
        const path
        of (
            data.links?.other
            || []
        )
    ){

        links.push(
            {
                label:"Other",
                path,
            }
        );
    }


    if(!links.length){

        $("links").innerHTML=
            "<div>Subscription route پیدا نشد</div>";

        return;
    }


    $("links").innerHTML=
        links.map(
            item => {

                const full=
                    location.origin
                    +item.path;


                return (
                    '<div class="sub-link">'

                    +'<div>'

                    +'<strong>'
                    +esc(
                        item.label
                    )
                    +'</strong>'

                    +'<br>'

                    +'<code>'
                    +esc(full)
                    +'</code>'

                    +'</div>'

                    +'<a class="btn small-btn" '
                    +'target="_blank" '
                    +'href="'
                    +esc(item.path)
                    +'">'
                    +'Open'
                    +'</a>'

                    +'</div>'
                );
            }
        ).join("");
}


function renderStatus(
    status
){

    const entries=
        Object.entries(
            status || {}
        );


    $("status").innerHTML=
        entries
        .map(
            ([key,value]) =>
                '<div class="kv">'
                +'<span>'
                +esc(key)
                +'</span>'
                +'<strong>'
                +esc(
                    typeof value
                    ==="object"
                    ?JSON.stringify(value)
                    :value
                )
                +'</strong>'
                +'</div>'
        )
        .join("");
}


async function load(){

    const data=await api(
        "/api/publish/summary"
    );


    const status=
        data.publish_status
        || {};


    const healthy=
        firstNumber(
            status,
            [
                "healthy",
                "healthy_count",
                "eligible_healthy",
            ]
        );


    const recovered=
        firstNumber(
            status,
            [
                "recovered",
                "recovered_count",
                "eligible_recovered",
            ]
        );


    const publishable=
        firstNumber(
            status,
            [
                "publishable",
                "publishable_count",
                "eligible",
                "eligible_count",
                "total_publishable",
            ]
        )
        || (
            healthy
            +recovered
        );


    $("healthy").textContent=
        num(healthy);

    $("recovered").textContent=
        num(recovered);

    $("publishable").textContent=
        num(
            publishable
        );

    $("routeCount").textContent=
        num(
            (
                data.routes
                || []
            ).length
        );


    renderLinks(
        data
    );

    renderStatus(
        status
    );

    $("rawStatus").textContent=
        JSON.stringify(
            status,
            null,
            2
        );
}


$("refresh")
.addEventListener(
    "click",
    () => {
        load().catch(
            console.error
        );
    }
);


load().catch(
    console.error
);


setInterval(
    () => {
        load().catch(
            console.error
        );
    },
    30000
);

</script>

</body>
</html>
'''


async def publish_page(
    request: web.Request,
) -> web.Response:

    return web.Response(
        text=HTML,
        content_type="text/html",
        charset="utf-8",
    )
