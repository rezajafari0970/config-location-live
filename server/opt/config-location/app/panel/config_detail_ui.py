from __future__ import annotations

from aiohttp import web


# PANEL_A5_CONFIG_DETAIL_UI

from app.panel.page_renderer import page

UNIFIED_CONFIG_DETAIL_SHELL_V1 = True

CONTENT = r'''
<div id="errorBox"
         class="error">
    </div>


    <div class="grid">

        <div class="card">

            <div class="metric-title">
                Type
            </div>

            <div id="type"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Health
            </div>

            <div id="health"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Country
            </div>

            <div id="country"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Country State
            </div>

            <div id="countryState"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Exit IP
            </div>

            <div id="exitIp"
                 class="metric-value mono">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Lifecycle
            </div>

            <div id="lifecycleState"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Sources
            </div>

            <div id="sources"
                 class="metric-value">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-title">
                Last Seen
            </div>

            <div id="lastSeen"
                 class="metric-value mono">
                -
            </div>

        </div>

    </div>


    <div class="section detail-grid">

        <div class="card">

            <h2>
                Country Identity
            </h2>

            <pre id="identity">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Country Pipeline
            </h2>

            <pre id="pipeline">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Health
            </h2>

            <pre id="healthJson">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Lifecycle
            </h2>

            <pre id="lifecycleJson">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Country Evidence / Result
            </h2>

            <pre id="resultJson">
-
            </pre>

        </div>


        <div class="card">

            <h2>
                Source IDs
            </h2>

            <pre id="sourceIds">
-
            </pre>

        </div>

    </div>


    <div class="section card">

        <h2>
            Raw Config
        </h2>

        <pre id="raw">
-
        </pre>

    </div>




<script>

"use strict";

const CONFIG_ID =
    decodeURIComponent(
        location.pathname
        .split("/")
        .filter(Boolean)
        .pop()
        || ""
    );


const $ = id =>
    document.getElementById(id);


function escText(
    value
){
    return String(
        value ?? "-"
    );
}


function pretty(
    value
){

    if(
        value===null
        || value===undefined
    ){
        return "-";
    }

    try{
        return JSON.stringify(
            value,
            null,
            2
        );
    }catch(_){
        return String(value);
    }
}


async function api(
    url
){

    const response=await fetch(
        url,
        {
            credentials:
                "same-origin",

            headers:{
                "Accept":
                    "application/json"
            }
        }
    );


    if(
        response.status===401
        || response.status===403
        || response.status===302
    ){
        location.href="/login";
        throw new Error(
            "authentication required"
        );
    }


    if(response.status===404){
        throw new Error(
            "Config not found"
        );
    }


    if(!response.ok){
        throw new Error(
            "HTTP "
            +response.status
        );
    }


    return await response.json();
}


function showError(
    error
){

    const box=$(
        "errorBox"
    );

    box.style.display=
        "block";

    box.textContent=
        String(
            error?.message
            || error
        );
}


async function load(){

    $("configId").textContent=
        CONFIG_ID;


    try{

        const data=await api(
            "/api/config/"
            +encodeURIComponent(
                CONFIG_ID
            )
        );


        const summary=
            data.summary || {};

        const config=
            data.config || {};


        $("type").textContent=
            escText(
                summary.config_type
            );


        $("health").textContent=
            escText(
                summary.health_status
            );


        $("country").textContent=
            summary.country_code
            ?(
                summary.country_code
                +(
                    summary.country_name
                    ?" · "
                    +summary.country_name
                    :""
                )
            )
            :"Unresolved";


        $("countryState").textContent=
            escText(
                summary.country_state
            );


        $("exitIp").textContent=
            escText(
                summary.exit_ip
            );


        $("lifecycleState").textContent=
            escText(
                summary.lifecycle_state
            );


        $("sources").textContent=
            Number(
                summary.source_count
                || 0
            ).toLocaleString();


        $("lastSeen").textContent=
            escText(
                summary.last_seen
            );


        $("identity").textContent=
            pretty(
                data.country_identity
            );


        $("pipeline").textContent=
            pretty(
                data.country_pipeline
            );


        $("healthJson").textContent=
            pretty(
                data.health
            );


        $("lifecycleJson").textContent=
            pretty(
                data.lifecycle
            );


        $("resultJson").textContent=
            pretty(
                data.country_result
            );


        $("sourceIds").textContent=
            pretty(
                config.source_ids
            );


        $("raw").textContent=
            escText(
                config.raw
            );


    }catch(error){

        console.error(error);
        showError(error);
    }
}


load();

</script>
'''


async def config_detail_page(request: web.Request) -> web.Response:
    return page('Config Detail', CONTENT, active='configs')
