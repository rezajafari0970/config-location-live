from __future__ import annotations


from aiohttp import web


from app.control.executor import (
    service_status,
    restart_service,
)


from app.control.security import (
    check_token,
    check_action,
)


from app.control.audit import audit



def auth(request):

    token = request.headers.get(
        "X-Control-Token",
        ""
    )

    return check_token(token)



async def control_status(request):

    if not auth(request):
        return web.json_response(
            {
                "error":"unauthorized"
            },
            status=401
        )


    if not check_action(
        "status"
    ):
        return web.json_response(
            {
                "error":"forbidden"
            },
            status=403
        )


    result = await service_status(
        "config-location-panel.service"
    )

    audit(
        "status",
        "success"
    )


    return web.json_response(
        {
            "ok":True,
            "services":[result]
        }
    )



async def control_restart(request):

    if not auth(request):
        return web.json_response(
            {
                "error":"unauthorized"
            },
            status=401
        )


    if not check_action(
        "restart"
    ):
        return web.json_response(
            {
                "error":"forbidden"
            },
            status=403
        )


    body = await request.json()

    result = await restart_service(
        body.get("service")
    )


    audit(
        "restart",
        "success",
        str(result)
    )


    return web.json_response(
        {
            "ok":True,
            "result":result
        }
    )



async def resources(request):

    import shutil
    import os


    total,used,free = shutil.disk_usage("/")


    return web.json_response(
        {
            "disk":{
                "total":total,
                "used":used,
                "free":free
            },

            "load":
                os.getloadavg()
        }
    )



def install_control_routes(app):

    if getattr(
        app,
        "_control_hardened",
        False
    ):
        return


    app.router.add_get(
        "/api/control/status",
        control_status
    )


    app.router.add_post(
        "/api/control/restart",
        control_restart
    )


    app.router.add_get(
        "/api/control/resources",
        resources
    )


    app._control_hardened=True

