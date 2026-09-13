#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

SERVER="$R/app/panel/server.py"
OPS_MODEL="$R/app/panel/operations_read_model.py"
OPS_UI="$R/app/panel/operations_ui.py"
COUNTRY_UI="$R/app/panel/country_ui.py"
DETAIL_UI="$R/app/panel/config_detail_ui.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/PANEL-A6-$TS"

mkdir -p "$B"

for F in \
"$SERVER" \
"$COUNTRY_UI" \
"$DETAIL_UI" \
"$OPS_MODEL" \
"$OPS_UI"
do
    if [ -f "$F" ]; then
        cp -a "$F" "$B/$(basename "$F").before"
    fi
done

echo "BACKUP=$B"


echo
echo "=== 1. CREATE OPERATIONS READ MODEL ==="

cat >"$OPS_MODEL" <<'PY'
from __future__ import annotations

from pathlib import Path
from typing import Any
import json
import time


# ============================================================
# PANEL_A6_OPERATIONS_READ_MODEL
# READ ONLY
# ============================================================

XRAY_FAILURE_ROOTS = (
    Path(
        "/var/log/config-location/"
        "xray/failures"
    ),
    Path(
        "/var/log/config-location/"
        "xray-full-audit"
    ),
)


def _read_json(
    path: Path,
) -> dict[str, Any] | None:

    try:

        value=json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )

    except (
        OSError,
        ValueError,
        TypeError,
    ):
        return None

    if not isinstance(
        value,
        dict,
    ):
        return None

    return value


def _event_bus_stats() -> dict[str, Any]:

    try:

        from app.country.event_bus import (
            stats,
        )

        value=stats()

    except Exception as exc:

        return {
            "available":False,
            "error":
                type(exc).__name__,
            "message":
                str(exc),
        }


    if not isinstance(
        value,
        dict,
    ):

        return {
            "available":False,
            "error":
                "invalid_stats_type",
        }


    result={
        "available":True,
    }

    result.update(value)

    return result


def _bundle_json_candidates(
    root: Path,
):

    preferred=[
        "failure.json",
        "metadata.json",
        "manifest.json",
        "runtime.json",
        "report.json",
    ]

    seen=set()

    for name in preferred:

        path=root/name

        if path.is_file():

            seen.add(path)

            yield path


    for path in sorted(
        root.glob("*.json")
    ):

        if path in seen:
            continue

        yield path


def _bundle_metadata(
    bundle: Path,
) -> dict[str, Any]:

    merged={}

    json_files=[]

    for path in _bundle_json_candidates(
        bundle
    ):

        json_files.append(
            path.name
        )

        value=_read_json(path)

        if value is None:
            continue


        # Preserve first meaningful value.
        for key in (
            "config_id",
            "stage",
            "exception",
            "exception_type",
            "message",
            "error",
            "status",
            "created_at",
            "timestamp",
            "config_type",
        ):

            if (
                key not in merged
                and value.get(key)
                not in (
                    None,
                    "",
                )
            ):
                merged[key]=value.get(
                    key
                )


    files=[]

    try:

        for path in sorted(
            bundle.iterdir()
        ):

            if not path.is_file():
                continue

            try:
                size=path.stat().st_size
            except OSError:
                size=None

            files.append(
                {
                    "name":path.name,
                    "size":size,
                }
            )

    except OSError:
        pass


    try:

        stat=bundle.stat()

        mtime=stat.st_mtime

    except OSError:

        mtime=0.0


    stage=(
        merged.get("stage")
        or merged.get("status")
        or "unknown"
    )

    exception=(
        merged.get("exception")
        or merged.get(
            "exception_type"
        )
        or merged.get("error")
    )


    return {
        "bundle_id":
            bundle.name,

        "path":
            str(bundle),

        "mtime_epoch":
            mtime,

        "mtime_iso":
            time.strftime(
                "%Y-%m-%dT%H:%M:%SZ",
                time.gmtime(mtime),
            )
            if mtime
            else None,

        "config_id":
            merged.get(
                "config_id"
            ),

        "config_type":
            merged.get(
                "config_type"
            ),

        "stage":
            stage,

        "exception":
            exception,

        "message":
            merged.get(
                "message"
            ),

        "created_at":
            merged.get(
                "created_at"
            )
            or merged.get(
                "timestamp"
            ),

        "json_files":
            json_files,

        "files":
            files,
    }


def iter_xray_failure_bundles():

    seen=set()

    for root in XRAY_FAILURE_ROOTS:

        if not root.is_dir():
            continue


        # Direct failure bundle directories.
        try:

            dirs=[
                p
                for p in root.iterdir()
                if p.is_dir()
            ]

        except OSError:

            continue


        # xray-full-audit may contain a jobs/
        # hierarchy; descend a small bounded depth.
        if (
            root.name
            =="xray-full-audit"
        ):

            nested=[]

            for path in root.glob(
                "*/jobs/*"
            ):

                if path.is_dir():
                    nested.append(path)

            dirs.extend(nested)


        for bundle in dirs:

            key=str(bundle)

            if key in seen:
                continue

            seen.add(key)

            yield _bundle_metadata(
                bundle
            )


def xray_failure_summary(
    *,
    limit: int = 100,
) -> dict[str, Any]:

    limit=max(
        1,
        min(
            int(limit),
            500,
        ),
    )

    rows=list(
        iter_xray_failure_bundles()
    )

    rows.sort(
        key=lambda x:
            float(
                x.get(
                    "mtime_epoch"
                )
                or 0
            ),
        reverse=True,
    )


    stages={}
    exceptions={}

    for row in rows:

        stage=str(
            row.get("stage")
            or "unknown"
        )

        stages[stage]=(
            stages.get(stage,0)
            +1
        )


        exc=str(
            row.get("exception")
            or "unknown"
        )

        exceptions[exc]=(
            exceptions.get(exc,0)
            +1
        )


    return {
        "total":
            len(rows),

        "stages":
            stages,

        "exceptions":
            exceptions,

        "items":
            rows[:limit],
    }


def operations_summary() -> dict[str, Any]:

    return {
        "event_bus":
            _event_bus_stats(),

        "xray_failures":
            xray_failure_summary(
                limit=50,
            ),
    }


def xray_failure_detail(
    bundle_id: str,
) -> dict[str, Any] | None:

    bundle_id=str(
        bundle_id
        or ""
    ).strip()


    if not bundle_id:

        return None


    # Reject path traversal.
    if (
        "/" in bundle_id
        or "\\" in bundle_id
        or bundle_id
        in {
            ".",
            "..",
        }
    ):
        return None


    for row in iter_xray_failure_bundles():

        if (
            row.get(
                "bundle_id"
            )
            !=bundle_id
        ):
            continue


        path=Path(
            row["path"]
        )


        content={}


        for name in (
            "failure.json",
            "metadata.json",
            "manifest.json",
            "runtime.json",
            "report.json",
            "xray-test.stderr.log",
            "xray-test.stdout.log",
            "xray-runtime.stderr.log",
            "xray-runtime.stdout.log",
        ):

            file_path=path/name

            if not file_path.is_file():
                continue


            try:

                text=file_path.read_text(
                    encoding="utf-8",
                    errors="replace",
                )

            except OSError:

                continue


            # Safety cap for UI/API.
            content[name]=text[
                -20000:
            ]


        result=dict(row)

        result[
            "content"
        ]=content

        return result


    return None
PY


"$PY" -m py_compile "$OPS_MODEL"

echo "OPERATIONS_MODEL=PASS"


echo
echo "=== 2. STATIC READ-ONLY AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import ast

path=Path(
    "/opt/config-location/"
    "app/panel/"
    "operations_read_model.py"
)

src=path.read_text()

tree=ast.parse(src)

forbidden={
    "write_text",
    "write_bytes",
    "unlink",
    "mkdir",
    "rename",
    "replace",
    "touch",
    "rmdir",
    "remove",
    "rmtree",
    "system",
    "run",
    "Popen",
    "check_call",
    "check_output",
}

bad=[]

for node in ast.walk(tree):

    if not isinstance(
        node,
        ast.Call,
    ):
        continue

    f=node.func

    name=(
        f.attr
        if isinstance(
            f,
            ast.Attribute,
        )
        else
        f.id
        if isinstance(
            f,
            ast.Name,
        )
        else None
    )

    if name in forbidden:

        # str.replace is not used here.
        bad.append(
            (
                node.lineno,
                name,
            )
        )


print(
    "WRITE_CALLS=",
    bad,
)

assert not bad

print(
    "READ_ONLY_CONTRACT=PASS"
)
PY


echo
echo "=== 3. EVENT BUS MODEL TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.operations_read_model import (
    operations_summary,
)

s=operations_summary()

bus=s["event_bus"]

print(
    "EVENT_BUS=",
    bus,
)

assert isinstance(
    bus,
    dict,
)

assert (
    bus.get("available")
    in {
        True,
        False,
    }
)

print(
    "EVENT_BUS_MODEL=PASS"
)
PY


echo
echo "=== 4. XRAY FORENSIC MODEL TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.operations_read_model import (
    xray_failure_summary,
)

r=xray_failure_summary(
    limit=20,
)

print(
    "XRAY_FAILURE_TOTAL=",
    r["total"],
)

print(
    "XRAY_FAILURE_STAGES=",
    r["stages"],
)

print(
    "XRAY_FAILURE_EXCEPTIONS=",
    r["exceptions"],
)

print(
    "RETURNED=",
    len(
        r["items"]
    ),
)

assert isinstance(
    r["total"],
    int,
)

assert len(
    r["items"]
)<=20

print(
    "XRAY_FORENSIC_MODEL=PASS"
)
PY


echo
echo "=== 5. CONFIGLOC ACCESS CHECK ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
from app.panel.operations_read_model import (
    operations_summary,
)

s=operations_summary()

print(
    "CONFIGLOC_EVENT_BUS=",
    s["event_bus"],
)

print(
    "CONFIGLOC_XRAY_TOTAL=",
    s[
        "xray_failures"
    ][
        "total"
    ],
)

print(
    "CONFIGLOC_XRAY_STAGES=",
    s[
        "xray_failures"
    ][
        "stages"
    ],
)

print(
    "CONFIGLOC_OPERATIONS_READ=PASS"
)
PY


echo
echo "=== 6. XRAY LOG READ ACL IF REQUIRED ==="

XRAY_ROOT=/var/log/config-location/xray

if [ -d "$XRAY_ROOT" ]; then

    # Directory traversal/read only.
    setfacl \
    -m u:configloc:r-x \
    /var/log/config-location \
    2>/dev/null || true

    setfacl \
    -m u:configloc:r-x \
    "$XRAY_ROOT" \
    2>/dev/null || true


    if [ -d "$XRAY_ROOT/failures" ]; then

        setfacl \
        -m u:configloc:r-x \
        "$XRAY_ROOT/failures"

        setfacl \
        -m d:u:configloc:r-x \
        "$XRAY_ROOT/failures"


        export XRAY_FAILURE_DIR="$XRAY_ROOT/failures"

        "$PY" <<'PY'
from pathlib import Path
import subprocess
import os

root=Path(
    os.environ[
        "XRAY_FAILURE_DIR"
    ]
)

dirs=list(
    root.iterdir()
)

ok=0
vanished=0
failed=[]


for bundle in dirs:

    if not bundle.exists():
        continue

    try:

        result=subprocess.run(
            [
                "setfacl",
                "-m",
                "u:configloc:r-x",
                str(bundle),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )

    except Exception as exc:

        failed.append(
            (
                str(bundle),
                str(exc),
            )
        )

        continue


    if result.returncode!=0:

        if not bundle.exists():
            vanished+=1
            continue

        failed.append(
            (
                str(bundle),
                result.stderr.strip(),
            )
        )

        continue


    if not bundle.is_dir():
        continue


    for file_path in list(
        bundle.glob("*")
    ):

        if not file_path.is_file():
            continue


        result=subprocess.run(
            [
                "setfacl",
                "-m",
                "u:configloc:r--",
                str(file_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )


        if result.returncode==0:
            ok+=1
            continue


        if not file_path.exists():
            vanished+=1
            continue


        failed.append(
            (
                str(file_path),
                result.stderr.strip(),
            )
        )


print(
    "XRAY_ACL_OK=",
    ok,
)

print(
    "XRAY_ACL_VANISHED=",
    vanished,
)

print(
    "XRAY_ACL_FAILED=",
    len(failed),
)

for item in failed[:10]:
    print(
        "FAIL=",
        item,
    )

if failed:
    raise SystemExit(
        "ERROR=XRAY_ACL_FAILURE"
    )
PY

    fi
fi

echo "XRAY_READ_ACL=PASS"


echo
echo "=== 7. CREATE OPERATIONS UI ==="

cat >"$OPS_UI" <<'PY'
from __future__ import annotations

from aiohttp import web


# PANEL_A6_OPERATIONS_UI


HTML=r'''<!doctype html>
<html lang="fa" dir="rtl">

<head>

<meta charset="utf-8">

<meta name="viewport"
      content="width=device-width,initial-scale=1">

<title>Operations Control</title>

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
    --red:#ff667a;
    --yellow:#f5c451;
    --blue:#55aaff;
    --violet:#a98bff;
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
    font-size:25px;
    font-weight:700;
}

.green{color:var(--green)}
.red{color:var(--red)}
.yellow{color:var(--yellow)}
.blue{color:var(--blue)}
.violet{color:var(--violet)}

.section{
    margin-top:14px;
}

.section h2{
    margin:0 0 12px;
    font-size:16px;
}

.table-wrap{
    overflow:auto;

    border:1px solid var(--border);
    border-radius:11px;
}

table{
    width:100%;
    min-width:1100px;
    border-collapse:collapse;
}

th,
td{
    padding:10px;
    border-bottom:
        1px solid var(--border);

    text-align:right;
    white-space:nowrap;
}

th{
    color:var(--muted);
    background:var(--panel2);
    font-size:12px;
}

td{
    font-size:12px;
}

.mono{
    direction:ltr;
    text-align:left;

    font-family:
        ui-monospace,
        SFMono-Regular,
        Menlo,
        monospace;
}

.badge{
    display:inline-flex;

    padding:3px 8px;

    border:
        1px solid var(--border);

    border-radius:999px;
}

.error{
    color:var(--red);
}

.empty{
    color:var(--muted);
    text-align:center;
    padding:30px !important;
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

.two{
    display:grid;
    grid-template-columns:
        repeat(2,minmax(0,1fr));
    gap:12px;
}

@media(max-width:850px){

    .grid{
        grid-template-columns:
            repeat(2,minmax(0,1fr));
    }

    .two{
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
                ⚙️ Operations Control
            </h1>

            <div style="
                color:var(--muted);
                font-size:12px;
                margin-top:5px;
            ">
                Read-only · Event Bus + Xray Forensic
            </div>

        </div>


        <div class="actions">

            <a class="btn"
               href="/country">
                Country
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
                Event Pending
            </div>

            <div class="metric-value yellow"
                 id="pending">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Event Leased
            </div>

            <div class="metric-value blue"
                 id="leased">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Event Done
            </div>

            <div class="metric-value green"
                 id="done">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Event Dead
            </div>

            <div class="metric-value red"
                 id="dead">
                -
            </div>

        </div>


        <div class="card">

            <div class="metric-name">
                Xray Failure Bundles
            </div>

            <div class="metric-value violet"
                 id="failures">
                -
            </div>

        </div>

    </div>


    <div class="section two">

        <div class="card">

            <h2>
                Xray Failure Stages
            </h2>

            <div id="stages">
                -
            </div>

        </div>


        <div class="card">

            <h2>
                Xray Exceptions
            </h2>

            <div id="exceptions">
                -
            </div>

        </div>

    </div>


    <div class="section card">

        <h2>
            Recent Xray Failure Bundles
        </h2>

        <div class="table-wrap">

            <table>

                <thead>

                <tr>
                    <th>Time</th>
                    <th>Bundle</th>
                    <th>Config ID</th>
                    <th>Type</th>
                    <th>Stage</th>
                    <th>Exception</th>
                    <th>Message</th>
                    <th>Files</th>
                </tr>

                </thead>


                <tbody id="tbody">
                </tbody>

            </table>

        </div>

    </div>

</div>


<script>

"use strict";

const $=id =>
    document.getElementById(id);


function num(
    value
){
    return Number(
        value || 0
    ).toLocaleString(
        "en-US"
    );
}


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


function renderKV(
    target,
    obj
){

    const entries=
        Object.entries(
            obj || {}
        )
        .sort(
            (a,b) =>
                Number(b[1])
                -Number(a[1])
        );


    if(!entries.length){

        $(target).innerHTML=
            '<div class="empty">'
            +'No data'
            +'</div>';

        return;
    }


    $(target).innerHTML=
        entries
        .map(
            ([key,value]) =>
                '<div class="kv">'
                +'<span>'
                +esc(key)
                +'</span>'
                +'<strong>'
                +num(value)
                +'</strong>'
                +'</div>'
        )
        .join("");
}


function renderRows(
    rows
){

    if(!rows.length){

        $("tbody").innerHTML=
            '<tr>'
            +'<td colspan="8" '
            +'class="empty">'
            +'Failure bundle موجود نیست'
            +'</td>'
            +'</tr>';

        return;
    }


    $("tbody").innerHTML=
        rows.map(
            row => {

                const files=
                    (row.files || [])
                    .map(
                        x=>x.name
                    )
                    .join(", ");


                return (
                    "<tr>"

                    +"<td class='mono'>"
                    +esc(
                        row.mtime_iso
                        || "-"
                    )
                    +"</td>"

                    +"<td class='mono'>"
                    +esc(
                        row.bundle_id
                        || "-"
                    )
                    +"</td>"

                    +"<td class='mono'>"
                    +esc(
                        row.config_id
                        || "-"
                    )
                    +"</td>"

                    +"<td>"
                    +esc(
                        row.config_type
                        || "-"
                    )
                    +"</td>"

                    +"<td>"
                    +esc(
                        row.stage
                        || "-"
                    )
                    +"</td>"

                    +"<td class='error'>"
                    +esc(
                        row.exception
                        || "-"
                    )
                    +"</td>"

                    +"<td>"
                    +esc(
                        row.message
                        || "-"
                    )
                    +"</td>"

                    +"<td>"
                    +esc(files)
                    +"</td>"

                    +"</tr>"
                );
            }
        )
        .join("");
}


async function load(){

    const data=await api(
        "/api/operations/summary"
    );


    const bus=
        data.event_bus
        || {};


    $("pending").textContent=
        num(
            bus.pending
        );

    $("leased").textContent=
        num(
            bus.leased
        );

    $("done").textContent=
        num(
            bus.done
        );

    $("dead").textContent=
        num(
            bus.dead
        );


    const xray=
        data.xray_failures
        || {};


    $("failures").textContent=
        num(
            xray.total
        );


    renderKV(
        "stages",
        xray.stages
    );

    renderKV(
        "exceptions",
        xray.exceptions
    );

    renderRows(
        xray.items || []
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


async def operations_page(
    request: web.Request,
) -> web.Response:

    return web.Response(
        text=HTML,
        content_type="text/html",
        charset="utf-8",
    )
PY


"$PY" -m py_compile "$OPS_UI"

echo "OPERATIONS_UI=PASS"


echo
echo "=== 8. PATCH SERVER ROUTES/APIS ==="

export SERVER

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["SERVER"]
)

s=p.read_text()

MARK="PANEL_A6_OPERATIONS_API"

if MARK in s:

    print(
        "SERVER_A6_ALREADY_PRESENT=YES"
    )

    raise SystemExit(0)


import_needle='''from app.panel.config_detail_ui import (
    config_detail_page,
)
'''

import_replacement='''from app.panel.config_detail_ui import (
    config_detail_page,
)

from app.panel.operations_ui import (
    operations_page,
)

# PANEL_A6_OPERATIONS_API
'''


if import_needle not in s:

    raise SystemExit(
        "ERROR=A5_IMPORT_POINT_NOT_FOUND"
    )


s=s.replace(
    import_needle,
    import_replacement,
    1,
)


handler_needle='''# ============================================================
# SELF TEST
# ============================================================
'''

handlers=r'''
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


'''


if handler_needle not in s:

    raise SystemExit(
        "ERROR=A6_HANDLER_INSERT_POINT_NOT_FOUND"
    )


s=s.replace(
    handler_needle,
    handlers+handler_needle,
    1,
)


route_needle='''    app.router.add_get(
        "/api/config/{config_id}",
        api_config_detail
    )
'''

routes='''    app.router.add_get(
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
'''


if route_needle not in s:

    raise SystemExit(
        "ERROR=A6_ROUTE_INSERT_POINT_NOT_FOUND"
    )


s=s.replace(
    route_needle,
    routes,
    1,
)


p.write_text(s)

print(
    "SERVER_A6_PATCH=PASS"
)
PY


echo
echo "=== 9. ADD OPERATIONS NAV LINK ==="

export COUNTRY_UI DETAIL_UI

"$PY" <<'PY'
from pathlib import Path
import os


for env_name in (
    "COUNTRY_UI",
    "DETAIL_UI",
):

    p=Path(
        os.environ[
            env_name
        ]
    )

    if not p.is_file():
        continue

    s=p.read_text()

    marker=(
        "PANEL_A6_OPERATIONS_NAV"
    )

    if marker in s:
        continue


    target='''            <a class="btn"
               href="/">
                داشبورد
            </a>
'''

    replacement='''            <a class="btn"
               href="/operations">
                Operations
            </a>

            <!-- PANEL_A6_OPERATIONS_NAV -->

            <a class="btn"
               href="/">
                داشبورد
            </a>
'''


    if target in s:

        s=s.replace(
            target,
            replacement,
            1,
        )

    else:

        # Detail UI uses English Dashboard.
        target2='''            <a href="/"
               class="btn">
                Dashboard
            </a>
'''

        replacement2='''            <a href="/operations"
               class="btn">
                Operations
            </a>

            <!-- PANEL_A6_OPERATIONS_NAV -->

            <a href="/"
               class="btn">
                Dashboard
            </a>
'''

        if target2 not in s:
            raise SystemExit(
                f"ERROR=NAV_INSERT_POINT_NOT_FOUND:{p}"
            )

        s=s.replace(
            target2,
            replacement2,
            1,
        )


    p.write_text(s)


print(
    "OPERATIONS_NAV=PASS"
)
PY


echo
echo "=== 10. COMPILE PANEL ==="

"$PY" -m py_compile \
"$SERVER" \
"$OPS_MODEL" \
"$OPS_UI" \
"$COUNTRY_UI" \
"$DETAIL_UI"

echo "COMPILE=PASS"


echo
echo "=== 11. ROUTE CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.server import (
    create_app,
)

app=create_app()

routes=set()

for r in app.router.routes():

    try:
        path=r.resource.canonical
    except Exception:
        continue

    routes.add(
        (
            r.method,
            path,
        )
    )


required={
    (
        "GET",
        "/operations",
    ),
    (
        "GET",
        "/api/operations/summary",
    ),
    (
        "GET",
        "/api/xray/failures",
    ),
    (
        "GET",
        "/api/xray/failure/{bundle_id}",
    ),
}


print(
    "MISSING=",
    required-routes,
)

assert not (
    required-routes
)

print(
    "A6_ROUTES=PASS"
)
PY


echo
echo "=== 12. REAL PANEL USER OPERATIONS TEST ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
from app.panel.operations_read_model import (
    operations_summary,
)

s=operations_summary()

print(
    "EVENT_BUS=",
    s["event_bus"],
)

print(
    "XRAY_TOTAL=",
    s[
        "xray_failures"
    ][
        "total"
    ],
)

print(
    "XRAY_STAGES=",
    s[
        "xray_failures"
    ][
        "stages"
    ],
)

assert isinstance(
    s["event_bus"],
    dict,
)

assert isinstance(
    s[
        "xray_failures"
    ][
        "total"
    ],
    int,
)

print(
    "CONFIGLOC_OPERATIONS=PASS"
)
PY


echo
echo "=== 13. RESTART PANEL ONLY ==="

systemctl restart \
config-location-panel.service

sleep 4

test "$(
    systemctl is-active \
    config-location-panel.service
)" = active

echo "PANEL_RESTART=PASS"


echo
echo "=== 14. AUTH PROTECTION ==="

"$PY" <<'PY'
import http.client

paths=[
    "/operations",
    "/api/operations/summary",
    "/api/xray/failures",
    "/api/xray/failure/test",
]

for path in paths:

    conn=http.client.HTTPConnection(
        "127.0.0.1",
        4040,
        timeout=15,
    )

    conn.request(
        "GET",
        path,
    )

    r=conn.getresponse()

    status=r.status

    location=r.getheader(
        "Location"
    )

    r.read()

    conn.close()

    print(
        path,
        status,
        location,
    )

    assert status==302
    assert location=="/login"


print(
    "A6_AUTH=PASS"
)
PY


echo
echo "=== 15. CORE SERVICES ==="

for S in \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$S" 2>/dev/null || true
    )

    echo "$S=$X"

    test "$X" = active

done

echo "CORE_SERVICES=PASS"


echo
echo "======================================================"
echo "PANEL_A6=PASS"
echo "OPERATIONS_UI=/operations"
echo "EVENT_BUS_DASHBOARD=READY"
echo "XRAY_FORENSIC_VIEWER=READY"
echo "FORENSIC_MODE=READ_ONLY"
echo "AUTH_PROTECTED=YES"
echo "CORE_MUTATION=NO"
echo "NEXT=PANEL-A7-PUBLISH-SUBSCRIPTIONS"
echo "======================================================"
