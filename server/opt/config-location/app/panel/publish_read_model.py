from __future__ import annotations

from typing import Any
from pathlib import Path
import inspect
import re


# ============================================================
# PANEL_A7_PUBLISH_READ_MODEL
# Canonical publish/subscription discovery
# READ ONLY
# ============================================================


def _safe_dict(
    value: Any,
) -> dict[str, Any]:

    if isinstance(
        value,
        dict,
    ):
        return value

    return {}


def _discover_publish_status() -> dict[str, Any]:
    """
    PANEL_A7_R5_COHERENT_CANONICAL_STATUS

    Canonical eligibility remains owned exclusively by:

        app.publish.filter.build_publish_snapshot()

    Healthy/recovered are only a breakdown of the exact
    publishable IDs returned by that canonical snapshot.

    Because production state changes continuously, we retry
    briefly until snapshot + policy view are coherent.
    """

    import time

    try:

        from app.publish.filter import (
            ALLOWED_STATES,
            POLICY_PATH,
            _policy_index,
            _read_json,
            build_publish_snapshot,
        )

    except Exception as exc:

        return {
            "_source":
                "app.publish.filter",

            "available":
                False,

            "error":
                type(exc).__name__,

            "message":
                str(exc),
        }


    last=None


    for attempt in range(1,9):

        try:

            snapshot=build_publish_snapshot()

            policy=_read_json(
                POLICY_PATH
            )

            index=(
                _policy_index(policy)
                if policy
                else {}
            )

        except Exception as exc:

            return {
                "_source":
                    "app.publish.filter.build_publish_snapshot",

                "available":
                    False,

                "error":
                    type(exc).__name__,

                "message":
                    str(exc),
            }


        # These are the exact configs selected by the
        # canonical filter for this particular snapshot.
        snapshot_ids=set()

        for record in snapshot.configs:

            if not isinstance(
                record,
                dict,
            ):
                continue

            config_id=(
                record.get("id")
                or record.get(
                    "config_id"
                )
            )

            if config_id:

                snapshot_ids.add(
                    str(config_id)
                )


        breakdown={
            "healthy":0,
            "recovered":0,
        }

        unresolved_breakdown=0


        for config_id in snapshot_ids:

            item=index.get(
                config_id
            )

            if not isinstance(
                item,
                dict,
            ):

                unresolved_breakdown+=1
                continue


            state=str(
                item.get(
                    "policy_state",
                    "",
                )
            ).strip().lower()


            eligible=bool(
                item.get(
                    "publish_eligible",
                    False,
                )
            )


            if (
                not eligible
                or state
                not in ALLOWED_STATES
            ):

                # State changed between canonical
                # snapshot and policy read.
                unresolved_breakdown+=1
                continue


            if state in breakdown:

                breakdown[state]+=1

            else:

                unresolved_breakdown+=1


        classified=(
            breakdown["healthy"]
            +breakdown["recovered"]
        )


        coherent=(
            len(snapshot_ids)
            ==snapshot.publishable
            and classified
            ==snapshot.publishable
            and unresolved_breakdown
            ==0
        )


        last={
            "_source":
                "app.publish.filter.build_publish_snapshot",

            "available":
                True,

            "mode":
                "production-output-filter",

            "policy_available":
                bool(
                    snapshot.policy_available
                ),

            "total_configs":
                int(
                    snapshot.total_configs
                ),

            "policy_tracked":
                int(
                    snapshot.policy_tracked
                ),

            "publishable":
                int(
                    snapshot.publishable
                ),

            "suppressed":
                int(
                    snapshot.suppressed
                ),

            "missing_policy_record":
                int(
                    snapshot.missing_policy_record
                ),

            "healthy":
                int(
                    breakdown["healthy"]
                ),

            "recovered":
                int(
                    breakdown["recovered"]
                ),

            "eligible_by_state":{
                "healthy":
                    int(
                        breakdown[
                            "healthy"
                        ]
                    ),

                "recovered":
                    int(
                        breakdown[
                            "recovered"
                        ]
                    ),
            },

            "allowed_states":
                sorted(
                    str(x)
                    for x
                    in ALLOWED_STATES
                ),

            "breakdown_unresolved":
                int(
                    unresolved_breakdown
                ),

            "coherent":
                bool(coherent),

            "coherence_attempt":
                attempt,

            "production_delete":
                False,
        }


        if coherent:
            return last


        # Very short retry only; no production mutation.
        time.sleep(0.02)


    # State may be changing continuously.
    # Publishable itself is still canonical.
    return last or {
        "_source":
            "app.publish.filter.build_publish_snapshot",

        "available":
            False,

        "error":
            "snapshot_unavailable",
    }


def _discover_routes() -> list[str]:

    try:

        from app.panel.server import (
            create_app,
        )

        app=create_app()

    except Exception:

        return []


    found=set()

    for route in app.router.routes():

        try:
            path=route.resource.canonical
        except Exception:
            continue

        if not isinstance(
            path,
            str,
        ):
            continue

        if (
            path.startswith("/sub/")
            or path=="/sub"
        ):
            found.add(path)


    return sorted(found)


def _classify_routes(
    routes: list[str],
) -> dict[str, list[str]]:

    result={
        "all":[],
        "type":[],
        "country":[],
        "other":[],
    }


    for path in routes:

        low=path.lower()

        if path=="/sub/all":

            result["all"].append(
                path
            )

        elif (
            "{config_type}" in path
            or "{type}" in path
        ):

            result["type"].append(
                path
            )

        elif (
            "{country" in low
            or "/country/" in low
        ):

            result["country"].append(
                path
            )

        else:

            result["other"].append(
                path
            )


    return result


def _known_types() -> list[str]:

    return [
        "vless",
        "vmess",
        "trojan",
        "ss",
        "wireguard",
        "json_xray",
    ]


def publish_summary() -> dict[str, Any]:

    status=_discover_publish_status()

    routes=_discover_routes()

    classes=_classify_routes(
        routes
    )


    type_links=[]

    route_template=None

    for item in classes[
        "type"
    ]:

        if (
            "{config_type}"
            in item
        ):
            route_template=item
            break


    if route_template:

        for config_type in _known_types():

            type_links.append(
                {
                    "type":
                        config_type,

                    "path":
                        route_template.replace(
                            "{config_type}",
                            config_type,
                        ),
                }
            )


    return {
        "publish_status":
            status,

        "routes":
            routes,

        "route_classes":
            classes,

        "links":{
            "all":
                "/sub/all"
                if "/sub/all"
                in routes
                else None,

            "types":
                type_links,

            "country_templates":
                classes[
                    "country"
                ],

            "other":
                classes[
                    "other"
                ],
        },
    }
