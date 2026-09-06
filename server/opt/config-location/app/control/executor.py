from __future__ import annotations

import asyncio


ALLOWED_SERVICES = {
    "config-location-panel.service",
}


async def service_status(service):

    if service not in ALLOWED_SERVICES:
        raise ValueError(
            "service not allowed"
        )


    proc = await asyncio.create_subprocess_exec(
        "systemctl",
        "is-active",
        service,
        stdout=asyncio.subprocess.PIPE,
    )

    out,_ = await proc.communicate()

    return {
        "service":service,
        "state":
            out.decode().strip(),
    }



async def restart_service(service):

    if service not in ALLOWED_SERVICES:
        raise ValueError(
            "service not allowed"
        )


    proc = await asyncio.create_subprocess_exec(
        "systemctl",
        "restart",
        service,
    )

    code = await proc.wait()

    return {
        "service":service,
        "code":code
    }

