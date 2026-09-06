from __future__ import annotations

import copy
import json
import os

from pathlib import Path
from typing import Any

from aiohttp import web


POLICY_PATH = Path(
    "/etc/config-location/"
    "health-adaptive.json"
)

STATUS_PATH = Path(
    "/var/lib/config-location/"
    "health-adaptive/"
    "daemon-status.json"
)

EFFECTIVE_PATH = Path(
    "/var/lib/config-location/"
    "health-adaptive/"
    "effective-runtime.json"
)

REPORT_PATH = Path(
    "/var/lib/config-location/"
    "health-adaptive/"
    "last-run.json"
)


def _read_json(
    path: Path,
    default: Any,
):

    try:

        value = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        return value

    except Exception:

        return copy.deepcopy(
            default
        )


def _atomic_json(
    path: Path,
    value: dict,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    tmp = path.with_name(
        "." + path.name + ".tmp"
    )

    tmp.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    tmp.chmod(
        0o660
    )

    os.replace(
        tmp,
        path,
    )


def _num(
    value,
    name: str,
    low: float,
    high: float,
    *,
    integer: bool = False,
):

    try:

        result = (
            int(value)
            if integer
            else float(value)
        )

    except Exception:

        raise ValueError(
            f"{name}: invalid number"
        )

    if not (
        low <= result <= high
    ):

        raise ValueError(
            f"{name}: must be between "
            f"{low} and {high}"
        )

    return result


def validate_policy(
    incoming: dict,
) -> dict:

    if not isinstance(
        incoming,
        dict,
    ):

        raise ValueError(
            "policy must be object"
        )


    current = _read_json(
        POLICY_PATH,
        {},
    )

    out = copy.deepcopy(
        current
    )


    workers_in = incoming.get(
        "workers",
        {},
    )

    workers = out.setdefault(
        "workers",
        {},
    )


    workers["min"] = _num(
        workers_in.get(
            "min",
            workers.get(
                "min",
                5,
            ),
        ),
        "workers.min",
        1,
        200,
        integer=True,
    )


    workers["soft_max"] = _num(
        workers_in.get(
            "soft_max",
            workers.get(
                "soft_max",
                100,
            ),
        ),
        "workers.soft_max",
        1,
        500,
        integer=True,
    )


    workers["hard_max"] = _num(
        workers_in.get(
            "hard_max",
            workers.get(
                "hard_max",
                200,
            ),
        ),
        "workers.hard_max",
        1,
        500,
        integer=True,
    )


    if not (
        workers["min"]
        <= workers["soft_max"]
        <= workers["hard_max"]
    ):

        raise ValueError(
            "workers: min <= soft_max <= hard_max"
        )


    batch_in = incoming.get(
        "batch",
        {},
    )

    batch = out.setdefault(
        "batch",
        {},
    )


    batch["min"] = _num(
        batch_in.get(
            "min",
            batch.get(
                "min",
                50,
            ),
        ),
        "batch.min",
        1,
        10000,
        integer=True,
    )


    batch["max"] = _num(
        batch_in.get(
            "max",
            batch.get(
                "max",
                3000,
            ),
        ),
        "batch.max",
        1,
        50000,
        integer=True,
    )


    batch[
        "target_cycle_seconds"
    ] = _num(
        batch_in.get(
            "target_cycle_seconds",
            batch.get(
                "target_cycle_seconds",
                180,
            ),
        ),
        "batch.target_cycle_seconds",
        10,
        3600,
        integer=True,
    )


    if batch["min"] > batch["max"]:

        raise ValueError(
            "batch.min <= batch.max required"
        )


    sg_in = incoming.get(
        "server_guard",
        {},
    )

    sg = out.setdefault(
        "server_guard",
        {},
    )


    sg[
        "target_cpu_percent"
    ] = _num(
        sg_in.get(
            "target_cpu_percent",
            sg.get(
                "target_cpu_percent",
                60,
            ),
        ),
        "target_cpu_percent",
        10,
        90,
    )


    sg[
        "max_cpu_percent"
    ] = _num(
        sg_in.get(
            "max_cpu_percent",
            sg.get(
                "max_cpu_percent",
                82,
            ),
        ),
        "max_cpu_percent",
        20,
        98,
    )


    sg[
        "critical_cpu_percent"
    ] = _num(
        sg_in.get(
            "critical_cpu_percent",
            sg.get(
                "critical_cpu_percent",
                94,
            ),
        ),
        "critical_cpu_percent",
        30,
        100,
    )


    if not (
        sg["target_cpu_percent"]
        <
        sg["max_cpu_percent"]
        <
        sg["critical_cpu_percent"]
    ):

        raise ValueError(
            "CPU thresholds: target < max < critical"
        )


    sg[
        "reserve_ram_mb"
    ] = _num(
        sg_in.get(
            "reserve_ram_mb",
            sg.get(
                "reserve_ram_mb",
                1536,
            ),
        ),
        "reserve_ram_mb",
        256,
        65536,
        integer=True,
    )


    sg[
        "max_fd_percent"
    ] = _num(
        sg_in.get(
            "max_fd_percent",
            sg.get(
                "max_fd_percent",
                70,
            ),
        ),
        "max_fd_percent",
        10,
        95,
    )


    sg[
        "max_health_xray"
    ] = _num(
        sg_in.get(
            "max_health_xray",
            sg.get(
                "max_health_xray",
                200,
            ),
        ),
        "max_health_xray",
        1,
        500,
        integer=True,
    )


    ex_in = incoming.get(
        "execution",
        {},
    )

    ex = out.setdefault(
        "execution",
        {},
    )


    ex[
        "startup_timeout"
    ] = _num(
        ex_in.get(
            "startup_timeout",
            ex.get(
                "startup_timeout",
                6,
            ),
        ),
        "startup_timeout",
        2,
        60,
    )


    ex[
        "download_timeout"
    ] = _num(
        ex_in.get(
            "download_timeout",
            ex.get(
                "download_timeout",
                6,
            ),
        ),
        "download_timeout",
        2,
        60,
    )


    ex[
        "upload_timeout"
    ] = _num(
        ex_in.get(
            "upload_timeout",
            ex.get(
                "upload_timeout",
                6,
            ),
        ),
        "upload_timeout",
        2,
        60,
    )


    ex[
        "runtime_retries"
    ] = _num(
        ex_in.get(
            "runtime_retries",
            ex.get(
                "runtime_retries",
                3,
            ),
        ),
        "runtime_retries",
        0,
        10,
        integer=True,
    )


    return out


def snapshot():

    return {
        "policy":
            _read_json(
                POLICY_PATH,
                {},
            ),

        "daemon":
            _read_json(
                STATUS_PATH,
                {},
            ),

        "effective":
            _read_json(
                EFFECTIVE_PATH,
                {},
            ),

        "last_run":
            _read_json(
                REPORT_PATH,
                {},
            ),
    }


async def adaptive_get(
    request: web.Request,
):

    return web.json_response(
        snapshot()
    )


async def adaptive_post(
    request: web.Request,
):

    try:

        body = await request.json()

        policy = validate_policy(
            body
        )

        _atomic_json(
            POLICY_PATH,
            policy,
        )

        return web.json_response({
            "ok": True,

            "message":
                "saved; adaptive daemon "
                "will hot-reload policy",

            "policy":
                policy,
        })

    except ValueError as exc:

        return web.json_response(
            {
                "ok": False,
                "error": str(exc),
            },
            status=400,
        )

    except json.JSONDecodeError:

        return web.json_response(
            {
                "ok": False,
                "error":
                    "invalid JSON",
            },
            status=400,
        )


ADAPTIVE_HTML = r'''<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>تنظیمات Health Adaptive</title>
<style>
:root{--orange:#f97316;--orange-dark:#c2410c;--orange-soft:#fff7ed;--green:#16a34a;--red:#dc2626;--bg:#f8fafc;--card:#fff;--border:#e2e8f0;--text:#0f172a;--muted:#64748b}
*{box-sizing:border-box}
body{margin:0;font-family:Arial,Tahoma,sans-serif;background:var(--bg);color:var(--text);direction:rtl}
.wrap{max-width:1100px;margin:auto;padding:14px}
.top{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:14px}
.top h2{margin:0;font-size:20px}
.nav{display:flex;gap:7px;flex-wrap:wrap}
.button,button{display:inline-block;border:0;border-radius:8px;padding:10px 14px;background:var(--orange);color:#fff;text-decoration:none;cursor:pointer;font-weight:700;font-size:13px}
.button.secondary{background:#64748b}
.card{background:var(--card);border:1px solid var(--border);border-top:3px solid var(--orange);border-radius:12px;padding:14px;margin-bottom:12px;box-shadow:0 1px 2px rgba(15,23,42,.04)}
.card h3{margin:0 0 12px;font-size:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px}
label{display:block;font-size:13px;font-weight:700;margin-bottom:5px}
.help{display:block;color:var(--muted);font-size:11px;line-height:1.6;margin-top:5px}
input{width:100%;border:1px solid #cbd5e1;background:#fff;color:var(--text);padding:10px;border-radius:8px;font-size:14px;direction:ltr;text-align:left}
input:focus{outline:2px solid rgba(249,115,22,.18);border-color:var(--orange)}
.status-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px}
.stat{border:1px solid var(--border);background:#fff;border-radius:9px;padding:10px;text-align:center;color:var(--muted);font-size:12px}
.stat strong{display:block;color:var(--text);font-size:16px;margin-bottom:4px;word-break:break-word}
.notice{background:var(--orange-soft);border:1px solid #fed7aa;color:#9a3412;border-radius:9px;padding:10px;font-size:12px;line-height:1.8;margin-bottom:12px}
.notice.danger{background:#fef2f2;border-color:#fecaca;color:#991b1b}
#msg{display:block;margin-top:10px;font-size:13px;font-weight:700}
.ok{color:var(--green)} .bad{color:var(--red)}
details{margin-top:10px} summary{cursor:pointer;font-weight:700;color:var(--orange-dark)}
pre{white-space:pre-wrap;word-break:break-word;direction:ltr;text-align:left;background:#f8fafc;border:1px solid var(--border);padding:10px;border-radius:8px;max-height:320px;overflow:auto;font-size:11px}
@media(max-width:720px){.wrap{padding:9px}.grid,.status-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:7px}.card{padding:11px}.button,button{padding:9px 11px}}
</style>
</head>
<body>
<div class="wrap">
<div class="top"><h2>تنظیمات Health Adaptive</h2><div class="nav"><a class="button secondary" href="/">بازگشت به پنل</a><a class="button secondary" href="/lifecycle">سلامت / چرخه عمر</a></div></div>
<div class="card"><h3>وضعیت لحظه‌ای</h3><div id="runtime" class="status-grid"><div class="stat"><strong>...</strong>در حال دریافت</div></div></div>
<div class="notice">تغییرات این صفحه پس از ذخیره توسط Health Adaptive Daemon به‌صورت Hot Reload اعمال می‌شوند. مقادیر خارج از محدوده توسط Backend رد خواهند شد.</div>
<form id="form">
<div class="card"><h3>Workerها</h3><div class="grid">
<div><label>حداقل Worker</label><input id="wmin" type="number"><span class="help">حد مجاز: 1 تا 200</span></div>
<div><label>حد نرم Worker</label><input id="wsoft" type="number"><span class="help">حد مجاز: 1 تا 500</span></div>
<div><label>حد سخت Worker</label><input id="whard" type="number"><span class="help">باید min ≤ soft ≤ hard باشد.</span></div>
</div></div>
<div class="card"><h3>Batch تطبیقی</h3><div class="grid">
<div><label>حداقل Batch</label><input id="bmin" type="number"><span class="help">حد مجاز: 1 تا 10000</span></div>
<div><label>حداکثر Batch</label><input id="bmax" type="number"><span class="help">حد مجاز: 1 تا 50000</span></div>
<div><label>زمان هدف هر Cycle</label><input id="cycle" type="number"><span class="help">10 تا 3600 ثانیه</span></div>
</div></div>
<div class="card"><h3>محافظ منابع سرور</h3><div class="notice danger">این بخش Safety-sensitive است. مقادیر CPU باید به ترتیب Target &lt; Max &lt; Critical باشند.</div><div class="grid">
<div><label>CPU هدف (%)</label><input id="ctarget" type="number"><span class="help">10 تا 90</span></div>
<div><label>CPU حداکثر (%)</label><input id="cmax" type="number"><span class="help">20 تا 98</span></div>
<div><label>CPU بحرانی (%)</label><input id="ccritical" type="number"><span class="help">30 تا 100</span></div>
<div><label>RAM رزرو (MB)</label><input id="ram" type="number"><span class="help">256 تا 65536 MB</span></div>
<div><label>حداکثر FD (%)</label><input id="fd" type="number"><span class="help">10 تا 95</span></div>
<div><label>حداکثر Xrayهای Health</label><input id="xray" type="number"><span class="help">1 تا 500</span></div>
</div></div>
<div class="card"><h3>Runtime پایه</h3><div class="grid">
<div><label>Timeout شروع</label><input id="startup" type="number"><span class="help">2 تا 60 ثانیه</span></div>
<div><label>Timeout دانلود</label><input id="download" type="number"><span class="help">2 تا 60 ثانیه</span></div>
<div><label>Timeout آپلود</label><input id="upload" type="number"><span class="help">2 تا 60 ثانیه</span></div>
<div><label>تعداد Retry</label><input id="retry" type="number"><span class="help">0 تا 10 بار</span></div>
</div></div>
<div class="card"><button type="submit">ذخیره تنظیمات Adaptive</button><span id="msg"></span></div>
</form>
<div class="card"><h3>اطلاعات فنی</h3><details><summary>نمایش JSON وضعیت کامل</summary><pre id="raw"></pre></details></div>
</div>
<script>
const $=id=>document.getElementById(id);
let data={};
function get(path,def){let x=data.policy||{};for(const k of path){x=(x||{})[k]}return x ?? def}
function safe(v,def='—'){return (v===undefined||v===null||v==='')?def:String(v)}
function runtimeCard(title,value){return `<div class="stat"><strong>${safe(value)}</strong>${title}</div>`}
async function load(){
 const runtime=$('runtime');
 try{
   const r=await fetch('/api/health/adaptive',{cache:'no-store'});
   if(!r.ok) throw new Error('HTTP '+r.status);
   data=await r.json();
   $('wmin').value=get(['workers','min'],5); $('wsoft').value=get(['workers','soft_max'],100); $('whard').value=get(['workers','hard_max'],200);
   $('bmin').value=get(['batch','min'],50); $('bmax').value=get(['batch','max'],3000); $('cycle').value=get(['batch','target_cycle_seconds'],180);
   $('ctarget').value=get(['server_guard','target_cpu_percent'],60); $('cmax').value=get(['server_guard','max_cpu_percent'],82); $('ccritical').value=get(['server_guard','critical_cpu_percent'],94);
   $('ram').value=get(['server_guard','reserve_ram_mb'],1536); $('fd').value=get(['server_guard','max_fd_percent'],70); $('xray').value=get(['server_guard','max_health_xray'],200);
   $('startup').value=get(['execution','startup_timeout'],6); $('download').value=get(['execution','download_timeout'],6); $('upload').value=get(['execution','upload_timeout'],6); $('retry').value=get(['execution','runtime_retries'],3);
   const daemon=data.daemon||{}, effective=data.effective||{}, last=data.last_run||{};
   runtime.innerHTML=runtimeCard('Daemon',daemon.state||daemon.status||'نامشخص')+runtimeCard('Worker موثر',effective.workers??effective.worker_count??effective.worker??'—')+runtimeCard('Batch موثر',effective.batch??effective.batch_size??'—')+runtimeCard('آخرین نتیجه',last.result||last.state||last.status||'—');
   $('raw').textContent=JSON.stringify(data,null,2);
 }catch(err){runtime.innerHTML=`<div class="notice danger">دریافت وضعیت Adaptive ناموفق بود: ${safe(err.message)}</div>`;$('raw').textContent=String(err)}
}
$('form').addEventListener('submit',async e=>{
 e.preventDefault(); const msg=$('msg'); msg.className=''; msg.textContent='در حال اعتبارسنجی و ذخیره...';
 const body={
   workers:{min:Number($('wmin').value),soft_max:Number($('wsoft').value),hard_max:Number($('whard').value)},
   batch:{min:Number($('bmin').value),max:Number($('bmax').value),target_cycle_seconds:Number($('cycle').value)},
   server_guard:{target_cpu_percent:Number($('ctarget').value),max_cpu_percent:Number($('cmax').value),critical_cpu_percent:Number($('ccritical').value),reserve_ram_mb:Number($('ram').value),max_fd_percent:Number($('fd').value),max_health_xray:Number($('xray').value)},
   execution:{startup_timeout:Number($('startup').value),download_timeout:Number($('download').value),upload_timeout:Number($('upload').value),runtime_retries:Number($('retry').value)}
 };
 try{
   const r=await fetch('/api/health/adaptive',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
   let response={}; try{response=await r.json()}catch(_){}
   if(!r.ok||response.ok===false) throw new Error(response.error||response.message||('HTTP '+r.status));
   msg.className='ok'; msg.textContent='ذخیره شد؛ Daemon تنظیمات را Hot Reload می‌کند.'; await load();
 }catch(err){msg.className='bad';msg.textContent='خطا: '+safe(err.message)}
});
load(); setInterval(load,15000);
</script>
</body>
</html>'''


async def adaptive_page(
    request: web.Request,
):

    return web.Response(
        text=ADAPTIVE_HTML,
        content_type="text/html",
        charset="utf-8",
    )


def install_aiohttp_routes(
    app: web.Application,
) -> None:

    if app.get(
        "_ht17_adaptive_installed"
    ):

        return


    app[
        "_ht17_adaptive_installed"
    ] = True


    app.router.add_get(
        "/api/health/adaptive",
        adaptive_get,
    )

    app.router.add_post(
        "/api/health/adaptive",
        adaptive_post,
    )

    app.router.add_get(
        "/health/adaptive",
        adaptive_page,
    )
