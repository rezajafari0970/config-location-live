#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. CANONICAL FUNCTION SIGNATURES ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.publish import filter as pf
from app.publish import http as ph

names=[
    (pf,"build_publish_snapshot"),
    (pf,"publishable_config_ids"),
    (ph,"publish_status"),
    (ph,"install_publish_routes"),
]

for module,name in names:

    obj=getattr(
        module,
        name,
        None,
    )

    print()
    print(
        "OBJECT=",
        module.__name__
        +"."+name,
    )

    print(
        "EXISTS=",
        obj is not None,
    )

    if obj is None:
        continue

    try:
        print(
            "SIGNATURE=",
            inspect.signature(obj),
        )
    except Exception as exc:
        print(
            "SIGNATURE_ERROR=",
            type(exc).__name__,
            str(exc),
        )

    try:
        print(
            "IS_COROUTINE=",
            inspect.iscoroutinefunction(obj),
        )
    except Exception:
        pass
PY


echo
echo "=== 2. PUBLISH SNAPSHOT DATACLASS ==="

PYTHONPATH="$R" "$PY" <<'PY'
import dataclasses
import inspect

from app.publish.filter import (
    PublishSnapshot,
)

print(
    "IS_DATACLASS=",
    dataclasses.is_dataclass(
        PublishSnapshot
    ),
)

print(
    "SIGNATURE=",
    inspect.signature(
        PublishSnapshot
    ),
)

if dataclasses.is_dataclass(
    PublishSnapshot
):

    for field in dataclasses.fields(
        PublishSnapshot
    ):

        print(
            "FIELD=",
            field.name,
            "TYPE=",
            field.type,
        )
PY


echo
echo "=== 3. BUILD SNAPSHOT DIRECTLY ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect
import dataclasses

from app.publish.filter import (
    build_publish_snapshot,
)

sig=inspect.signature(
    build_publish_snapshot
)

print(
    "PARAMETERS=",
    list(
        sig.parameters
    ),
)

if len(
    sig.parameters
)==0:

    snap=build_publish_snapshot()

    print(
        "TYPE=",
        type(snap).__name__,
    )

    if dataclasses.is_dataclass(
        snap
    ):

        data=dataclasses.asdict(
            snap
        )

    elif hasattr(
        snap,
        "__dict__",
    ):

        data=dict(
            snap.__dict__
        )

    else:

        data=snap

    print(
        "SNAPSHOT=",
        data,
    )

else:

    print(
        "DIRECT_BUILD=REQUIRES_ARGUMENTS"
    )
PY


echo
echo "=== 4. SOURCE OF SNAPSHOT BUILDER ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.publish.filter import (
    build_publish_snapshot,
    publishable_config_ids,
)

print(
    "=== build_publish_snapshot ==="
)

print(
    inspect.getsource(
        build_publish_snapshot
    )
)

print()
print(
    "=== publishable_config_ids ==="
)

print(
    inspect.getsource(
        publishable_config_ids
    )
)
PY


echo
echo "=== 5. SOURCE OF HTTP STATUS ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.publish.http import (
    publish_status,
    install_publish_routes,
)

print(
    "=== publish_status ==="
)

print(
    inspect.getsource(
        publish_status
    )
)

print()
print(
    "=== install_publish_routes ==="
)

print(
    inspect.getsource(
        install_publish_routes
    )
)
PY


echo
echo "=== 6. FILTER CONSTANTS / ROOTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
import app.publish.filter as pf

for name in sorted(
    dir(pf)
):

    upper=name.upper()

    if any(
        token in upper
        for token in (
            "ROOT",
            "PATH",
            "HEALTH",
            "LIFECYCLE",
            "STATE",
            "PUBLISH",
        )
    ):

        try:
            value=getattr(
                pf,
                name,
            )
        except Exception:
            continue

        if callable(value):
            continue

        print(
            name,
            "=",
            value,
        )
PY


echo
echo "=== 7. SAME TEST AS PANEL USER ==="

runuser -u configloc -- \
env PYTHONPATH="$R" \
"$PY" <<'PY'
import inspect
import dataclasses

from app.publish.filter import (
    build_publish_snapshot,
    publishable_config_ids,
)

print(
    "BUILD_SIGNATURE=",
    inspect.signature(
        build_publish_snapshot
    ),
)

print(
    "IDS_SIGNATURE=",
    inspect.signature(
        publishable_config_ids
    ),
)


if len(
    inspect.signature(
        build_publish_snapshot
    ).parameters
)==0:

    try:

        snap=build_publish_snapshot()

        if dataclasses.is_dataclass(
            snap
        ):
            value=dataclasses.asdict(
                snap
            )
        elif hasattr(
            snap,
            "__dict__",
        ):
            value=dict(
                snap.__dict__
            )
        else:
            value=snap

        print(
            "CONFIGLOC_SNAPSHOT=",
            value,
        )

    except Exception as exc:

        print(
            "CONFIGLOC_BUILD_ERROR=",
            type(exc).__name__,
            str(exc),
        )


if len(
    inspect.signature(
        publishable_config_ids
    ).parameters
)==0:

    try:

        ids=publishable_config_ids()

        print(
            "CONFIGLOC_PUBLISHABLE_IDS=",
            len(ids),
        )

    except Exception as exc:

        print(
            "CONFIGLOC_IDS_ERROR=",
            type(exc).__name__,
            str(exc),
        )
PY


echo
echo "======================================================"
echo "PANEL_A7_R3_DIAG=PASS"
echo "PRODUCTION_MUTATION=NO"
echo "PANEL_RESTART=NO"
echo "NEXT=PANEL-A7-R4-CANONICAL-STATUS-FIX"
echo "======================================================"
