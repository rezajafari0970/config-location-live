from __future__ import annotations

import os
import shutil
from aiohttp import web

from app.control.audit import audit
from app.control.executor import all_service_status, restart_service
from app.control.security import check_action, check_token, security_status
from app.core.events import list_events, prune_events
from app.core.status import get_core_status
from app.settings import (
    get_feature_runtime_contracts,
    get_setting_runtime_contracts,
    get_settings_status,
    prune_settings_history,
)

def _headers():
    return {"Cache-Control": "no-store"}

def _json(payload, *, status=200):
    return web.json_response(payload, status=status, headers=_headers())

def _actor(request):
    return request.remote or "unknown"

def _authz(request, action):
    token = request.headers.get("X-Control-Token", "")
    if not check_token(token):
        audit(action, "denied", "unauthorized", actor=_actor(request))
        return _json({"ok":False,"error":"unauthorized","code":"control_unauthorized"}, status=401)
    if not check_action(action):
        audit(action, "denied", "forbidden", actor=_actor(request))
        return _json({"ok":False,"error":"forbidden","code":"control_forbidden"}, status=403)
    return None

async def control_status(request):
    denied=_authz(request,"status")
    if denied: return denied
    try:
        services=await all_service_status()
        result={
            "ok":True,
            "services":services,
            "security":security_status(),
        }
        audit("status","success",actor=_actor(request))
        return _json(result)
    except Exception as exc:
        audit("status","failure",repr(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"control_status_failed"},status=500)

async def control_restart(request):
    denied=_authz(request,"restart")
    if denied: return denied
    try:
        body=await request.json()
        if not isinstance(body,dict):
            raise ValueError("JSON body must be object")
        service=body.get("service")
        result=await restart_service(service)
        audit("restart","success",str(result),actor=_actor(request))
        return _json({"ok":True,"result":result})
    except ValueError as exc:
        audit("restart","rejected",str(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"invalid_restart_request"},status=400)
    except Exception as exc:
        audit("restart","failure",repr(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"restart_failed"},status=500)

async def resources(request):
    denied=_authz(request,"resources")
    if denied: return denied
    try:
        total,used,free=shutil.disk_usage("/")
        data={
            "ok":True,
            "disk":{"total":total,"used":used,"free":free,"percent":round((used/total)*100,2) if total else 0},
            "load":list(os.getloadavg()),
            "cpu_count":os.cpu_count(),
        }
        try:
            import psutil
            vm=psutil.virtual_memory()
            data["ram"]={"total":vm.total,"available":vm.available,"used":vm.used,"percent":vm.percent}
            data["cpu_percent"]=psutil.cpu_percent(interval=0.05)
        except Exception:
            pass
        audit("resources","success",actor=_actor(request))
        return _json(data)
    except Exception as exc:
        audit("resources","failure",repr(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"resources_failed"},status=500)

async def core_status(request):
    denied=_authz(request,"core_status")
    if denied: return denied
    try:
        result=get_core_status(event_limit=20)
        audit("core_status","success",actor=_actor(request))
        return _json({"ok":True,"core":result})
    except Exception as exc:
        audit("core_status","failure",repr(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"core_status_failed"},status=500)

async def core_events(request):
    denied=_authz(request,"events")
    if denied: return denied
    try:
        limit=int(request.rel_url.query.get("limit","50"))
        limit=max(1,min(limit,500))
        result=list_events(limit=limit)
        audit("events","success",f"limit={limit}",actor=_actor(request))
        return _json({"ok":True,"events":result,"count":len(result)})
    except ValueError as exc:
        return _json({"ok":False,"error":str(exc),"code":"invalid_event_limit"},status=400)
    except Exception as exc:
        audit("events","failure",repr(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"events_failed"},status=500)

async def settings_status(request):
    denied=_authz(request,"settings_status")
    if denied: return denied
    try:
        result=get_settings_status()
        audit("settings_status","success",actor=_actor(request))
        return _json({"ok":True,"settings":result})
    except Exception as exc:
        audit("settings_status","failure",repr(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"settings_status_failed"},status=500)

async def capabilities(request):
    denied=_authz(request,"capabilities")
    if denied: return denied
    result={
        "ok":True,
        "features":get_feature_runtime_contracts(),
        "settings":get_setting_runtime_contracts(),
    }
    audit("capabilities","success",actor=_actor(request))
    return _json(result)

def _maintenance_args(obj):
    if not isinstance(obj,dict):
        raise ValueError("JSON body must be object")
    target=str(obj.get("target","")).strip()
    if target not in {"events","settings_history"}:
        raise ValueError("target must be events or settings_history")
    return target

async def maintenance_preview(request):
    denied=_authz(request,"maintenance_preview")
    if denied: return denied
    try:
        body=await request.json()
        target=_maintenance_args(body)
        if target=="events":
            age=int(body.get("max_age_seconds",7*24*3600))
            result=prune_events(max_age_seconds=age,dry_run=True)
        else:
            entries=int(body.get("max_entries",50))
            days=body.get("max_age_days")
            days=int(days) if days is not None else None
            result=prune_settings_history(max_entries=entries,max_age_days=days,dry_run=True)
        audit("maintenance_preview","success",f"{target}:{result}",actor=_actor(request))
        return _json({"ok":True,"target":target,"result":result})
    except ValueError as exc:
        audit("maintenance_preview","rejected",str(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"invalid_maintenance_request"},status=400)
    except Exception as exc:
        audit("maintenance_preview","failure",repr(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"maintenance_preview_failed"},status=500)

async def maintenance_run(request):
    denied=_authz(request,"maintenance_run")
    if denied: return denied
    try:
        body=await request.json()
        target=_maintenance_args(body)
        if body.get("confirm") is not True:
            raise ValueError("confirm=true required")
        if target=="events":
            age=int(body.get("max_age_seconds",7*24*3600))
            result=prune_events(max_age_seconds=age,dry_run=False)
        else:
            entries=int(body.get("max_entries",50))
            days=body.get("max_age_days")
            days=int(days) if days is not None else None
            result=prune_settings_history(max_entries=entries,max_age_days=days,dry_run=False)
        audit("maintenance_run","success",f"{target}:{result}",actor=_actor(request))
        return _json({"ok":True,"target":target,"result":result})
    except ValueError as exc:
        audit("maintenance_run","rejected",str(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"invalid_maintenance_request"},status=400)
    except Exception as exc:
        audit("maintenance_run","failure",repr(exc),actor=_actor(request))
        return _json({"ok":False,"error":str(exc),"code":"maintenance_run_failed"},status=500)

def install_control_routes(app):
    marker="_control_plane_v2_routes"
    if app.get(marker):
        return
    app.router.add_get("/api/control/status",control_status)
    app.router.add_post("/api/control/restart",control_restart)
    app.router.add_get("/api/control/resources",resources)
    app.router.add_get("/api/control/core",core_status)
    app.router.add_get("/api/control/events",core_events)
    app.router.add_get("/api/control/settings",settings_status)
    app.router.add_get("/api/control/capabilities",capabilities)
    app.router.add_post("/api/control/maintenance/preview",maintenance_preview)
    app.router.add_post("/api/control/maintenance/run",maintenance_run)
    app[marker]=True
