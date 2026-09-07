from __future__ import annotations

from aiohttp import web


# PANEL_A7_PUBLISH_UI

from app.panel.page_renderer import page

UNIFIED_PUBLISH_SHELL_V1 = True

CONTENT = r'''
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
'''


async def publish_page(request: web.Request) -> web.Response:
    return page('Publish & Subscriptions', CONTENT, active='publish')
