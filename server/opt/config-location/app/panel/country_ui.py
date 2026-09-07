from __future__ import annotations

from aiohttp import web


# PANEL_A4_COUNTRY_UI

from app.panel.page_renderer import page

UNIFIED_COUNTRY_SHELL_V1 = True

CONTENT = r'''
<div id="errorBox"
         class="error-box">
    </div>


    <div class="grid">

        <div class="card">

            <div class="metric-name">
                کل کانفیگ‌ها
            </div>

            <div id="mTotal"
                 class="metric-value blue">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Country مشخص
            </div>

            <div id="mKnown"
                 class="metric-value green">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Unresolved
            </div>

            <div id="mUnresolved"
                 class="metric-value yellow">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Rotating IP
            </div>

            <div id="mRotating"
                 class="metric-value violet">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Country Coverage
            </div>

            <div id="mCoverage"
                 class="metric-value green">
                -
            </div>

            <div class="metric-sub">
                درصد کانفیگ‌های دارای Country
            </div>

        </div>

    </div>


    <div class="section summary-grid">

        <div class="card">

            <h2 class="section-title">
                Health
            </h2>

            <div id="healthSummary"
                 class="kv-list">
            </div>

        </div>


        <div class="card">

            <h2 class="section-title">
                Country State
            </h2>

            <div id="stateSummary"
                 class="kv-list">
            </div>

        </div>


        <div class="card">

            <h2 class="section-title">
                Top Countries
            </h2>

            <div id="countrySummary"
                 class="kv-list">
            </div>

        </div>

    </div>


    <div class="section card">

        <h2 class="section-title">
            جستجو و فیلتر
        </h2>

        <div class="filters">

            <input
                id="q"
                type="search"
                placeholder=
                "Config ID / Country / Exit IP">

            <select id="typeFilter">

                <option value="">
                    همه Typeها
                </option>

                <option value="vless">
                    VLESS
                </option>

                <option value="vmess">
                    VMess
                </option>

                <option value="trojan">
                    Trojan
                </option>

                <option value="ss">
                    Shadowsocks
                </option>

                <option value="wireguard">
                    WireGuard
                </option>

                <option value="json_xray">
                    JSON/Xray
                </option>

            </select>


            <select id="healthFilter">

                <option value="">
                    همه Healthها
                </option>

                <option value="healthy">
                    Healthy
                </option>

                <option value="unhealthy">
                    Unhealthy
                </option>

                <option value="invalid">
                    Invalid
                </option>

                <option value="unknown">
                    Unknown
                </option>

            </select>


            <select id="stateFilter">

                <option value="">
                    همه Country Stateها
                </option>

                <option value="confirmed_stable">
                    Stable
                </option>

                <option value="confirmed_rotating_ip">
                    Rotating IP
                </option>

                <option value="pending_confirmation">
                    Pending
                </option>

                <option value="ambiguous">
                    Ambiguous
                </option>

                <option value="unstable_exit">
                    Unstable Exit
                </option>

                <option value="error">
                    Error
                </option>

                <option value="unknown">
                    Unknown
                </option>

            </select>


            <select id="modeFilter">

                <option value="all">
                    همه
                </option>

                <option value="unresolved">
                    فقط Unresolved
                </option>

            </select>


            <button id="refreshBtn"
                    class="btn">
                بروزرسانی
            </button>

        </div>

    </div>


    <div class="section card"
         id="tableCard">

        <h2 class="section-title">
            Config Country Inventory
        </h2>

        <div class="table-wrap">

            <table>

                <thead>
                <tr>

                    <th>Config ID</th>
                    <th>Type</th>
                    <th>Health</th>
                    <th>Country</th>
                    <th>State</th>
                    <th>Exit IP</th>
                    <th>Sources</th>
                    <th>Last Seen</th>

                </tr>
                </thead>

                <tbody id="tbody">
                </tbody>

            </table>

        </div>


        <div class="pager">

            <div id="resultInfo"
                 class="status-line">
                -
            </div>


            <div class="pager-actions">

                <button id="prevBtn"
                        class="btn">
                    قبلی
                </button>

                <span id="pageInfo"
                      class="status-line">
                    -
                </span>

                <button id="nextBtn"
                        class="btn">
                    بعدی
                </button>

            </div>

        </div>

    </div>




<script>
"use strict";

const PAGE_SIZE = 50;

let offset = 0;
let total = 0;

const $ = (id) =>
    document.getElementById(id);


function esc(value){

    return String(
        value ?? ""
    )
    .replaceAll("&","&amp;")
    .replaceAll("<","&lt;")
    .replaceAll(">","&gt;")
    .replaceAll('"',"&quot;")
    .replaceAll("'","&#039;");
}


function number(value){

    return Number(
        value || 0
    ).toLocaleString("en-US");
}


function badge(text,type){

    return (
        '<span class="badge '
        +type
        +'">'
        +esc(text)
        +'</span>'
    );
}


function healthBadge(value){

    const v=String(
        value || "unknown"
    ).toLowerCase();

    if(v==="healthy"){
        return badge(
            "healthy",
            "good"
        );
    }

    if(
        v==="unhealthy"
        || v==="invalid"
    ){
        return badge(
            v,
            "bad"
        );
    }

    return badge(
        v,
        "warn"
    );
}


function stateBadge(value){

    const v=String(
        value || "unknown"
    );

    if(v==="confirmed_stable"){
        return badge(
            "stable",
            "good"
        );
    }

    if(v==="confirmed_rotating_ip"){
        return badge(
            "rotating",
            "violet"
        );
    }

    if(v==="pending_confirmation"){
        return badge(
            "pending",
            "info"
        );
    }

    if(
        v==="ambiguous"
        || v==="unstable_exit"
        || v==="unknown"
    ){
        return badge(
            v,
            "warn"
        );
    }

    if(v==="error"){
        return badge(
            "error",
            "bad"
        );
    }

    return badge(
        v,
        "info"
    );
}


function renderKV(
    target,
    obj,
    limit=20
){

    const entries=Object.entries(
        obj || {}
    )
    .sort(
        (a,b) =>
            Number(b[1])
            -Number(a[1])
    )
    .slice(
        0,
        limit
    );

    if(!entries.length){

        $(target).innerHTML=
            '<div class="status-line">'
            +'داده‌ای موجود نیست'
            +'</div>';

        return;
    }

    $(target).innerHTML=
        entries.map(
            ([key,value]) =>
                '<div class="kv">'
                +'<span class="key">'
                +esc(key)
                +'</span>'
                +'<strong>'
                +number(value)
                +'</strong>'
                +'</div>'
        ).join("");
}


async function api(url){

    const response=await fetch(
        url,
        {
            credentials:"same-origin",
            headers:{
                "Accept":
                    "application/json"
            }
        }
    );

    if(
        response.status===401
        || response.status===403
    ){
        window.location="/login";
        throw new Error(
            "authentication required"
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


async function loadSummary(){

    const s=await api(
        "/api/country/summary"
    );

    $("mTotal").textContent=
        number(
            s.total_configs
        );

    $("mKnown").textContent=
        number(
            s.country_known
        );

    $("mUnresolved").textContent=
        number(
            s.country_unresolved
        );

    $("mRotating").textContent=
        number(
            s.country_rotating
        );

    $("mCoverage").textContent=
        Number(
            s.country_coverage_percent
            || 0
        ).toFixed(2)
        +"%";


    renderKV(
        "healthSummary",
        s.health,
        10
    );

    renderKV(
        "stateSummary",
        s.country_states,
        12
    );

    renderKV(
        "countrySummary",
        s.countries,
        15
    );
}


function buildQuery(){

    const params=
        new URLSearchParams();

    params.set(
        "offset",
        String(offset)
    );

    params.set(
        "limit",
        String(PAGE_SIZE)
    );


    const q=$("q").value.trim();

    if(q){
        params.set(
            "q",
            q
        );
    }


    const type=
        $("typeFilter").value;

    if(type){
        params.set(
            "type",
            type
        );
    }


    const health=
        $("healthFilter").value;

    if(health){
        params.set(
            "health",
            health
        );
    }


    const state=
        $("stateFilter").value;

    if(state){
        params.set(
            "state",
            state
        );
    }


    const unresolved=
        $("modeFilter").value
        ==="unresolved";

    if(unresolved){
        params.set(
            "unresolved",
            "1"
        );
    }


    return params;
}


function renderRows(items){

    if(!items.length){

        $("tbody").innerHTML=
            '<tr>'
            +'<td colspan="8" '
            +'class="empty">'
            +'نتیجه‌ای پیدا نشد'
            +'</td>'
            +'</tr>';

        return;
    }


    $("tbody").innerHTML=
        items.map(
            row => {

                const id=String(
                    row.config_id || ""
                );

                const shortId=
                    id.length>20
                    ?id.slice(0,18)+"…"
                    :id;


                const country=
                    row.country_code
                    ?(
                        esc(
                            row.country_code
                        )
                        +(
                            row.country_name
                            ?" · "
                            +esc(
                                row.country_name
                            )
                            :""
                        )
                    )
                    :'<span class="yellow">'
                     +'Unresolved'
                     +'</span>';


                return (
                    "<tr>"

                    +"<td class='mono' "
                    +"title='"
                    +esc(id)
                    +"'>"
                    +"<a "
                    +"href='/config/"
                    +encodeURIComponent(id)
                    +"' "
                    +"style='color:inherit;"
                    +"text-decoration:none'>"
                    +esc(shortId)
                    +"</a>"
                    +"</td>"
                    // PANEL_A5_DETAIL_LINK

                    +"<td>"
                    +esc(
                        row.config_type
                    )
                    +"</td>"

                    +"<td>"
                    +healthBadge(
                        row.health_status
                    )
                    +"</td>"

                    +"<td>"
                    +country
                    +"</td>"

                    +"<td>"
                    +stateBadge(
                        row.country_state
                    )
                    +"</td>"

                    +"<td class='mono'>"
                    +esc(
                        row.exit_ip || "-"
                    )
                    +"</td>"

                    +"<td>"
                    +number(
                        row.source_count
                    )
                    +"</td>"

                    +"<td class='mono'>"
                    +esc(
                        row.last_seen || "-"
                    )
                    +"</td>"

                    +"</tr>"
                );
            }
        ).join("");
}


async function loadConfigs(){

    const card=$("tableCard");

    card.classList.add(
        "loading"
    );

    try{

        const params=
            buildQuery();

        const data=await api(
            "/api/configs?"
            +params.toString()
        );

        total=Number(
            data.total || 0
        );

        renderRows(
            data.items || []
        );


        const start=
            total===0
            ?0
            :offset+1;

        const end=Math.min(
            offset+PAGE_SIZE,
            total
        );


        $("resultInfo").textContent=
            "نمایش "
            +number(start)
            +" تا "
            +number(end)
            +" از "
            +number(total);


        const currentPage=
            total===0
            ?0
            :Math.floor(
                offset/PAGE_SIZE
            )+1;

        const pages=
            total===0
            ?0
            :Math.ceil(
                total/PAGE_SIZE
            );

        $("pageInfo").textContent=
            "صفحه "
            +number(currentPage)
            +" / "
            +number(pages);


        $("prevBtn").disabled=
            offset<=0;

        $("nextBtn").disabled=
            (
                offset
                +PAGE_SIZE
                >=total
            );

    }finally{

        card.classList.remove(
            "loading"
        );
    }
}


function showError(error){

    const box=$("errorBox");

    box.style.display="block";

    box.textContent=
        "خطا در بارگذاری: "
        +String(
            error?.message
            || error
        );
}


function clearError(){

    const box=$("errorBox");

    box.style.display="none";
    box.textContent="";
}


async function reloadAll(){

    clearError();

    try{

        await Promise.all(
            [
                loadSummary(),
                loadConfigs(),
            ]
        );

    }catch(error){

        console.error(error);
        showError(error);
    }
}


function resetAndLoad(){

    offset=0;
    reloadAll();
}


$("refreshBtn")
.addEventListener(
    "click",
    resetAndLoad
);


$("prevBtn")
.addEventListener(
    "click",
    () => {

        offset=Math.max(
            0,
            offset-PAGE_SIZE
        );

        reloadAll();
    }
);


$("nextBtn")
.addEventListener(
    "click",
    () => {

        if(
            offset
            +PAGE_SIZE
            <total
        ){
            offset+=PAGE_SIZE;
            reloadAll();
        }
    }
);


for(
    const id
    of [
        "typeFilter",
        "healthFilter",
        "stateFilter",
        "modeFilter",
    ]
){
    $(id).addEventListener(
        "change",
        resetAndLoad
    );
}


let searchTimer=null;

$("q")
.addEventListener(
    "input",
    () => {

        clearTimeout(
            searchTimer
        );

        searchTimer=setTimeout(
            resetAndLoad,
            350
        );
    }
);


reloadAll();

setInterval(
    () => {
        loadSummary()
        .catch(
            console.error
        );
    },
    30000
);

</script>
'''


async def country_page(request: web.Request) -> web.Response:
    return page('Country Control', CONTENT, active='country')
