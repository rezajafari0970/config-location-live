from __future__ import annotations
import asyncio
import os
import re

SERVICE_PATTERN = re.compile(r"^config-location-[A-Za-z0-9_.@-]+\.service$")
ALLOWED_SERVICES = {
    "config-location-panel.service",
    "config-location-fetcher.service",
}

class ControlExecutorError(RuntimeError):
    pass

def validate_service(service) -> str:
    if not isinstance(service, str):
        raise ValueError("service must be string")
    service = service.strip()
    if not SERVICE_PATTERN.fullmatch(service):
        raise ValueError("invalid project service name")
    if service not in ALLOWED_SERVICES:
        raise ValueError("service not allowed")
    return service

def _systemctl_command(*args: str) -> tuple[str, ...]:
    if os.geteuid() == 0:
        return ("systemctl", *args)
    return ("sudo", "-n", "/usr/bin/systemctl", *args)

async def _run_systemctl(*args: str, timeout: float = 20.0):
    cmd = _systemctl_command(*args)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise ControlExecutorError("systemctl_timeout")
    return {
        "code": int(proc.returncode),
        "stdout": stdout.decode(errors="replace").strip(),
        "stderr": stderr.decode(errors="replace").strip(),
    }

async def service_status(service):
    service = validate_service(service)
    result = await _run_systemctl("is-active", service, timeout=10)
    return {
        "service": service,
        "state": result["stdout"] or "unknown",
        "code": result["code"],
    }

async def all_service_status():
    return [await service_status(s) for s in sorted(ALLOWED_SERVICES)]

async def restart_service(service):
    service = validate_service(service)
    result = await _run_systemctl("restart", service, timeout=30)
    if result["code"] != 0:
        raise ControlExecutorError("service_restart_failed:" + result["stderr"])
    status = await service_status(service)
    return {"service": service, "code": 0, "state": status["state"]}
