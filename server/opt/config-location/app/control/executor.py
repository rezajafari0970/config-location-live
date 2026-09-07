from __future__ import annotations
import asyncio,re
SERVICE_PATTERN=re.compile(r"^config-location-[A-Za-z0-9_.@-]+\.service$")
ALLOWED_SERVICES={"config-location-panel.service","config-location-fetcher.service"}
class ControlExecutorError(RuntimeError): pass
def validate_service(s):
    if not isinstance(s,str): raise ValueError("service must be string")
    s=s.strip()
    if not SERVICE_PATTERN.fullmatch(s): raise ValueError("invalid project service name")
    if s not in ALLOWED_SERVICES: raise ValueError("service not allowed")
    return s
async def _run_systemctl(*args,timeout=20):
    p=await asyncio.create_subprocess_exec("systemctl",*args,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try: out,err=await asyncio.wait_for(p.communicate(),timeout=timeout)
    except asyncio.TimeoutError:
        p.kill(); await p.wait(); raise ControlExecutorError("systemctl_timeout")
    return {"code":p.returncode,"stdout":out.decode(errors="replace").strip(),"stderr":err.decode(errors="replace").strip()}
async def service_status(s):
    s=validate_service(s); r=await _run_systemctl("is-active",s,timeout=10)
    return {"service":s,"state":r["stdout"] or "unknown","code":r["code"]}
async def all_service_status():
    return [await service_status(s) for s in sorted(ALLOWED_SERVICES)]
async def restart_service(s):
    s=validate_service(s); r=await _run_systemctl("restart",s,timeout=30)
    if r["code"]!=0: raise ControlExecutorError("service_restart_failed:"+r["stderr"])
    st=await service_status(s); return {"service":s,"code":r["code"],"state":st["state"]}
