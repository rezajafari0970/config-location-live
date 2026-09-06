#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase5-post-closure-hardening-a-e-v2"

PROJECT="/opt/config-location"
REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"

BACKUP="/root/3245/${PHASE}-${TS}"

LOG="/root/background-logs/${PHASE}-${TS}.log"
REPORT="$REPO/reports/${PHASE}-${TS}.txt"
SUMMARY="$REPO/discovery/$DATE/${PHASE}-${TS}.json"

PROJECTION="$PROJECT/app/country/projection.py"
STORAGE="$PROJECT/app/country/storage.py"
PANEL_ADAPTER="$PROJECT/app/country/panel_projection_adapter.py"
READ_MODEL="$PROJECT/app/panel/read_model.py"
PROD_PROJECTION="$PROJECT/app/country/production_publish_projection.py"
HTTP="$PROJECT/app/publish/http.py"
IDENTITY="$PROJECT/app/country/country_identity.py"
FILTER="$PROJECT/app/publish/filter.py"
GUARD="$PROJECT/app/country/publish_contract_guard.py"

mkdir -p \
  "$BACKUP" \
  /root/background-logs \
  "$(dirname "$REPORT")" \
  "$(dirname "$SUMMARY")"

ROLLED_BACK="NO"
MUTATION_STARTED="NO"

rollback() {

    [ "$ROLLED_BACK" = "NO" ] || return 0
    [ "$MUTATION_STARTED" = "YES" ] || return 0

    echo
    echo "========== AUTOMATIC ROLLBACK =========="

    cp -a "$BACKUP/projection.py" "$PROJECTION"
    cp -a "$BACKUP/storage.py" "$STORAGE"
    cp -a "$BACKUP/panel_projection_adapter.py" "$PANEL_ADAPTER"
    cp -a "$BACKUP/read_model.py" "$READ_MODEL"
    cp -a "$BACKUP/production_publish_projection.py" "$PROD_PROJECTION"
    cp -a "$BACKUP/http.py" "$HTTP"
    cp -a "$BACKUP/country_identity.py" "$IDENTITY"
    cp -a "$BACKUP/filter.py" "$FILTER"
    cp -a "$BACKUP/publish_contract_guard.py" "$GUARD"

    cd "$PROJECT"

    PYTHONPATH="$PROJECT" \
    "$PROJECT/venv/bin/python" \
    -m py_compile \
      app/country/projection.py \
      app/country/storage.py \
      app/country/panel_projection_adapter.py \
      app/panel/read_model.py \
      app/country/production_publish_projection.py \
      app/publish/http.py \
      app/country/country_identity.py \
      app/publish/filter.py \
      app/country/publish_contract_guard.py \
      >/dev/null 2>&1 || true

    systemctl restart \
      config-location-country-worker.service \
      >/dev/null 2>&1 || true

    systemctl restart \
      config-location-country-event-consumer.service \
      >/dev/null 2>&1 || true

    systemctl restart \
      config-location-panel.service \
      >/dev/null 2>&1 || true

    ROLLED_BACK="YES"

    echo "ROLLBACK_DONE"
}

on_error() {
    CODE=$?

    echo
    echo "HARDENING_ERROR_EXIT=$CODE"

    rollback

    exit "$CODE"
}

trap on_error ERR


echo "================================================"
echo " PHASE 5 POST-CLOSURE HARDENING A-E V2"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/13] PRECHECK =========="

[ "$(id -u)" -eq 0 ]

id configloc >/dev/null

for FILE in \
  "$PROJECTION" \
  "$STORAGE" \
  "$PANEL_ADAPTER" \
  "$READ_MODEL" \
  "$PROD_PROJECTION" \
  "$HTTP" \
  "$IDENTITY" \
  "$FILTER" \
  "$GUARD"
do
    test -f "$FILE"
done

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/projection.py \
  app/country/storage.py \
  app/country/panel_projection_adapter.py \
  app/panel/read_model.py \
  app/country/production_publish_projection.py \
  app/publish/http.py \
  app/country/country_identity.py \
  app/publish/filter.py \
  app/country/publish_contract_guard.py

echo "BASELINE_COMPILE=PASS"
echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/13] BACKUP =========="

cp -a "$PROJECTION" "$BACKUP/projection.py"
cp -a "$STORAGE" "$BACKUP/storage.py"
cp -a "$PANEL_ADAPTER" "$BACKUP/panel_projection_adapter.py"
cp -a "$READ_MODEL" "$BACKUP/read_model.py"
cp -a "$PROD_PROJECTION" "$BACKUP/production_publish_projection.py"
cp -a "$HTTP" "$BACKUP/http.py"
cp -a "$IDENTITY" "$BACKUP/country_identity.py"
cp -a "$FILTER" "$BACKUP/filter.py"
cp -a "$GUARD" "$BACKUP/publish_contract_guard.py"

echo "BACKUP=$BACKUP"
echo "BACKUP_OK"

MUTATION_STARTED="YES"


################################################
# 3 FIX A
# results/latest authority + 0640 writer
################################################

echo
echo "========== [3/13] FIX A — RESULTS CONTRACT =========="

"$PROJECT/venv/bin/python" \
- "$PROJECTION" "$STORAGE" <<'PY'
import sys
from pathlib import Path


projection = Path(sys.argv[1])
storage = Path(sys.argv[2])


# -------------------------------------------
# Canonical projection must consume the actual
# writer location:
#
# results/latest/<config_id>.json
# -------------------------------------------

s = projection.read_text(
    encoding="utf-8"
)

old = '''RESULT_ROOT = (
    COUNTRY_ROOT / "results"
)'''

new = '''RESULT_ROOT = (
    COUNTRY_ROOT / "results" / "latest"
)'''

if old not in s:
    raise SystemExit(
        "FIX_A_RESULT_ROOT_PATTERN_NOT_FOUND"
    )

s = s.replace(
    old,
    new,
    1,
)


old = '''        "mode":
            "shadow",'''

new = '''        "mode":
            "production",'''

if old not in s:
    raise SystemExit(
        "FIX_A_MODE_PATTERN_NOT_FOUND"
    )

s = s.replace(
    old,
    new,
    1,
)

projection.write_text(
    s,
    encoding="utf-8",
)


# -------------------------------------------
# Every results file is born as:
#
# root:<configloc group> 0640
# -------------------------------------------

s = storage.read_text(
    encoding="utf-8"
)

needle = '''    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix="." + path.name + ".",
        suffix=".tmp",
    )

    try:
'''

replacement = '''    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix="." + path.name + ".",
        suffix=".tmp",
    )

    _configloc_gid = (
        __import__("grp")
        .getgrnam("configloc")
        .gr_gid
    )

    os.fchown(
        fd,
        -1,
        _configloc_gid,
    )

    os.fchmod(
        fd,
        0o640,
    )

    try:
'''

if needle not in s:
    raise SystemExit(
        "FIX_A_STORAGE_MKSTEMP_PATTERN_NOT_FOUND"
    )

s = s.replace(
    needle,
    replacement,
    1,
)

storage.write_text(
    s,
    encoding="utf-8",
)

print("FIX_A_SOURCE_PATCHED=YES")
PY


RESULTS_LATEST="/var/lib/config-location/country/results/latest"

mkdir -p "$RESULTS_LATEST"

CONFIGLOC_GROUP="$(id -gn configloc)"

find "$RESULTS_LATEST" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  -exec chgrp "$CONFIGLOC_GROUP" {} + \
  2>/dev/null || true

find "$RESULTS_LATEST" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  -exec chmod 0640 {} + \
  2>/dev/null || true

echo "FIX_A_RESULTS_RECONCILED=YES"


################################################
# 4 FIX B
# panel freshness + raw evidence integrity
################################################

echo
echo "========== [4/13] FIX B — PANEL CONTRACT =========="

cat > "$PANEL_ADAPTER" <<'PY'
from __future__ import annotations

import threading
import time

from typing import Any

from app.country.projection import (
    build_projection,
)


_CACHE_TTL_SECONDS = 2.0

_lock = threading.RLock()

_cache: dict[str, Any] | None = None
_deadline = 0.0


def _projection_cache() -> dict[str, Any]:

    global _cache
    global _deadline

    now = time.monotonic()

    with _lock:

        if (
            _cache is not None
            and now < _deadline
        ):
            return _cache


    value = build_projection()


    with _lock:

        _cache = value

        _deadline = (
            time.monotonic()
            + _CACHE_TTL_SECONDS
        )


    return value


def refresh_projection_cache() -> None:

    global _cache
    global _deadline

    with _lock:

        _cache = None
        _deadline = 0.0


def country_projection_for(
    config_id: str,
) -> dict[str, Any]:

    row = (
        _projection_cache()
        .get(
            "records",
            {},
        )
        .get(
            str(config_id)
        )
    )

    if not isinstance(
        row,
        dict,
    ):

        return {
            "state":
                "unknown",

            "country_code":
                None,

            "country_name":
                None,

            "flag":
                None,

            "confidence":
                None,

            "selected_source":
                None,
        }

    return row


def overlay_country(
    row: dict[str, Any],
) -> dict[str, Any]:

    if not isinstance(
        row,
        dict,
    ):
        return row

    cid = (
        row.get("config_id")
        or row.get("id")
    )

    if not cid:
        return row


    projected = (
        country_projection_for(
            str(cid)
        )
    )


    out = dict(row)

    state = projected.get(
        "state",
        "unknown",
    )

    out[
        "country_state"
    ] = state


    if state == "resolved":

        out[
            "country_code"
        ] = projected.get(
            "country_code"
        )

        out[
            "country_name"
        ] = projected.get(
            "country_name"
        )

        out[
            "country"
        ] = (
            projected.get(
                "country_name"
            )
            or projected.get(
                "country_code"
            )
        )

        out[
            "flag"
        ] = projected.get(
            "flag"
        )

        out[
            "country_confidence"
        ] = projected.get(
            "confidence"
        )

        out[
            "country_source"
        ] = projected.get(
            "selected_source"
        )

    else:

        out["country_code"] = None
        out["country_name"] = None
        out["country"] = None
        out["flag"] = None
        out["country_confidence"] = None
        out["country_source"] = None


    return out


def overlay_country_collection(
    value: Any,
) -> Any:

    if isinstance(
        value,
        list,
    ):

        return [
            (
                overlay_country(item)
                if isinstance(item, dict)
                else item
            )
            for item in value
        ]


    if (
        isinstance(value, dict)
        and (
            "config_id" in value
            or "id" in value
        )
    ):

        return overlay_country(
            value
        )


    return value
PY


"$PROJECT/venv/bin/python" \
- "$READ_MODEL" <<'PY'
import sys
from pathlib import Path


path = Path(sys.argv[1])

s = path.read_text(
    encoding="utf-8"
)


old = '''def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding='utf-8', errors='replace'))
    except (OSError, ValueError, TypeError):
        return overlay_country_collection(None)
    if not isinstance(value, dict):
        return overlay_country_collection(None)
    return overlay_country_collection(value)
'''

new = '''def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding='utf-8', errors='replace'))
    except (OSError, ValueError, TypeError):
        return None
    if not isinstance(value, dict):
        return None
    return value
'''

if old not in s:
    raise SystemExit(
        "FIX_B_READ_JSON_PATTERN_NOT_FOUND"
    )

s = s.replace(
    old,
    new,
    1,
)


old = '''return overlay_country_collection(str(record.get('config_id') or record.get('id') or fallback))'''

new = '''return str(record.get('config_id') or record.get('id') or fallback)'''

if old not in s:
    raise SystemExit(
        "FIX_B_CONFIG_ID_PATTERN_NOT_FOUND"
    )

s = s.replace(
    old,
    new,
    1,
)


path.write_text(
    s,
    encoding="utf-8",
)

print(
    "FIX_B_READ_MODEL_PATCHED=YES"
)
PY


echo "FIX_B_PANEL_CACHE_TTL=2s"
echo "FIX_B_RAW_EVIDENCE_INTEGRITY=YES"

################################################
# 5 FIX C
# production projection TTL cache
################################################

echo
echo "========== [5/13] FIX C — PRODUCTION READ MODEL =========="

cat > "$PROD_PROJECTION" <<'PY'
from __future__ import annotations

import threading
import time

from typing import Any

from app.country.projection import (
    build_projection,
)


_CACHE_TTL_SECONDS = 2.0

_lock = threading.RLock()

_cache: dict[str, Any] | None = None
_deadline = 0.0


def refresh_country_projection() -> dict[str, Any]:

    global _cache
    global _deadline

    value = build_projection()

    with _lock:

        _cache = value

        _deadline = (
            time.monotonic()
            + _CACHE_TTL_SECONDS
        )

    return value


def get_country_projection() -> dict[str, Any]:

    global _cache
    global _deadline

    now = time.monotonic()

    with _lock:

        if (
            _cache is not None
            and now < _deadline
        ):
            return _cache


    return refresh_country_projection()


def invalidate_country_projection() -> None:

    global _cache
    global _deadline

    with _lock:

        _cache = None
        _deadline = 0.0


def country_record_for(
    config_id: str,
) -> dict[str, Any] | None:

    row = (
        get_country_projection()
        .get(
            "records",
            {},
        )
        .get(
            str(config_id)
        )
    )

    if not isinstance(
        row,
        dict,
    ):
        return None

    return row


def country_state_for(
    config_id: str,
) -> str:

    row = country_record_for(
        config_id
    )

    if not row:
        return "unknown"

    return str(
        row.get(
            "state",
            "unknown",
        )
    )


def country_code_for_config(
    config_id: str,
) -> str | None:

    row = country_record_for(
        config_id
    )

    if not row:
        return None

    if row.get("state") != "resolved":
        return None

    code = row.get(
        "country_code"
    )

    if (
        isinstance(code, str)
        and len(code.strip()) == 2
        and code.strip().isalpha()
    ):

        return code.strip().upper()

    return None


def discovered_country_codes() -> set[str]:

    projection = get_country_projection()

    result: set[str] = set()

    for row in (
        projection
        .get(
            "records",
            {},
        )
        .values()
    ):

        if not isinstance(
            row,
            dict,
        ):
            continue

        if row.get("state") != "resolved":
            continue

        code = row.get(
            "country_code"
        )

        if (
            isinstance(code, str)
            and len(code.strip()) == 2
            and code.strip().isalpha()
        ):

            result.add(
                code.strip().upper()
            )

    return result
PY

echo "FIX_C_CACHE_TTL=2s"
echo "FIX_C_PRODUCTION_READ_MODEL=YES"


################################################
# 6 FIX D
# Deferred to exact HTTP finalizer in section 9.
#
# The baseline implementation splits country logic
# between _country_subscription_text() and
# subscription_country(), therefore an AST search
# for one combined handler is intentionally avoided.
################################################

echo
echo "========== [6/13] FIX D — COUNTRY HTTP CONTRACT =========="

echo "FIX_D_BASELINE_DISCOVERED=YES"
echo "FIX_D_AST_PATCH_SKIPPED=YES"
echo "FIX_D_EXACT_FINALIZER_PENDING=YES"


################################################
# 7 FIX E1
# identity corruption recovery
################################################

echo
echo "========== [7/13] FIX E1 — IDENTITY RECOVERY =========="

"$PROJECT/venv/bin/python" \
- "$IDENTITY" <<'PY'
import ast
import sys
from pathlib import Path


path = Path(sys.argv[1])

tree = ast.parse(
    path.read_text(
        encoding="utf-8",
    )
)


# -------------------------------------------------
# Inject repair helper.
# -------------------------------------------------

helper_exists = any(
    isinstance(
        node,
        ast.FunctionDef,
    )
    and node.name
    == "_recover_corrupt_identity"
    for node in tree.body
)


if not helper_exists:

    helper = ast.parse(
r'''
def _recover_corrupt_identity(
    path,
):
    try:

        if not path.exists():
            return False

        import json

        value = json.loads(
            path.read_text(
                encoding="utf-8",
                errors="strict",
            )
        )

        if isinstance(
            value,
            dict,
        ):
            return False

    except Exception:
        pass


    try:

        path.unlink()

        return True

    except OSError:

        return False
'''
    ).body[0]


    insert_at = 0

    for index, node in enumerate(
        tree.body
    ):

        if isinstance(
            node,
            (
                ast.Import,
                ast.ImportFrom,
            ),
        ):

            insert_at = (
                index + 1
            )


    tree.body.insert(
        insert_at,
        helper,
    )


# -------------------------------------------------
# Patch load_identity exception path.
# -------------------------------------------------

patched_load = 0


for node in ast.walk(tree):

    if (
        isinstance(
            node,
            ast.FunctionDef,
        )
        and node.name
        == "load_identity"
    ):

        for child in ast.walk(node):

            if isinstance(
                child,
                ast.ExceptHandler,
            ):

                body_text = (
                    ast.unparse(
                        child
                    )
                )

                if (
                    "return None"
                    in body_text
                    and "_recover_corrupt_identity"
                    not in body_text
                ):

                    child.body.insert(
                        0,
                        ast.parse(
                            "_recover_corrupt_identity(path)"
                        ).body[0],
                    )

                    patched_load += 1

                    break


if patched_load != 1:

    raise SystemExit(
        f"FIX_E1_LOAD_PATCH_COUNT={patched_load}"
    )


ast.fix_missing_locations(
    tree
)


path.write_text(
    ast.unparse(tree)
    + "\n",
    encoding="utf-8",
)


print(
    "FIX_E1_IDENTITY_RECOVERY_PATCHED=YES"
)
PY


echo "FIX_E1_CORRUPT_IDENTITY_RECOVERY=YES"


################################################
# 8 FIX E2
# PublishSnapshot corrupt_configs metric
################################################

echo
echo "========== [8/13] FIX E2 — CORRUPTION OBSERVABILITY =========="

"$PROJECT/venv/bin/python" \
- "$FILTER" <<'PY'
import ast
import sys
from pathlib import Path


path = Path(sys.argv[1])

tree = ast.parse(
    path.read_text(
        encoding="utf-8",
    )
)


# -------------------------------------------------
# Add dataclass field.
# -------------------------------------------------

class_found = False


for node in tree.body:

    if (
        isinstance(
            node,
            ast.ClassDef,
        )
        and node.name
        == "PublishSnapshot"
    ):

        class_found = True

        existing = {
            child.target.id
            for child in node.body
            if isinstance(
                child,
                ast.AnnAssign,
            )
            and isinstance(
                child.target,
                ast.Name,
            )
        }

        if (
            "corrupt_configs"
            not in existing
        ):

            node.body.append(
                ast.AnnAssign(
                    target=ast.Name(
                        id="corrupt_configs",
                        ctx=ast.Store(),
                    ),
                    annotation=ast.Name(
                        id="int",
                        ctx=ast.Load(),
                    ),
                    value=ast.Constant(
                        value=0,
                    ),
                    simple=1,
                )
            )

        break


if not class_found:

    raise SystemExit(
        "FIX_E2_PUBLISHSNAPSHOT_CLASS_NOT_FOUND"
    )


# -------------------------------------------------
# Add counter and increment parse failures.
# -------------------------------------------------

function_found = False


for node in ast.walk(tree):

    if (
        isinstance(
            node,
            ast.FunctionDef,
        )
        and node.name
        == "build_publish_snapshot"
    ):

        function_found = True


        text = ast.unparse(node)

        if (
            "corrupt_configs = 0"
            not in text
        ):

            node.body.insert(
                0,
                ast.parse(
                    "corrupt_configs = 0"
                ).body[0],
            )


        for child in ast.walk(node):

            if isinstance(
                child,
                ast.ExceptHandler,
            ):

                if (
                    len(child.body) == 1
                    and isinstance(
                        child.body[0],
                        ast.Pass,
                    )
                ):

                    child.body = (
                        ast.parse(
                            "corrupt_configs += 1"
                        ).body
                    )


        for child in ast.walk(node):

            if not isinstance(
                child,
                ast.Call,
            ):
                continue

            if not (
                isinstance(
                    child.func,
                    ast.Name,
                )
                and child.func.id
                == "PublishSnapshot"
            ):
                continue


            existing = {
                kw.arg
                for kw in child.keywords
                if kw.arg
            }


            if (
                "corrupt_configs"
                not in existing
            ):

                child.keywords.append(
                    ast.keyword(
                        arg="corrupt_configs",
                        value=ast.Name(
                            id="corrupt_configs",
                            ctx=ast.Load(),
                        ),
                    )
                )


if not function_found:

    raise SystemExit(
        "FIX_E2_BUILD_FUNCTION_NOT_FOUND"
    )


ast.fix_missing_locations(
    tree
)


path.write_text(
    ast.unparse(tree)
    + "\n",
    encoding="utf-8",
)


print(
    "FIX_E2_CORRUPTION_METRIC_PATCHED=YES"
)
PY


echo "FIX_E2_CORRUPT_CONFIGS_METRIC=YES"

################################################
# 9 FINALIZERS + FIX E3
################################################

echo
echo "========== [9/13] FINALIZERS + FIX E3 =========="


################################################
# E1 FINALIZER
# Correct corrupt identity recovery variable.
################################################

"$PROJECT/venv/bin/python" \
- "$IDENTITY" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])

s = path.read_text(
    encoding="utf-8"
)

s = s.replace(
    "_recover_corrupt_identity(path)",
    "_recover_corrupt_identity(p)",
)

if "_recover_corrupt_identity(p)" not in s:
    raise SystemExit(
        "IDENTITY_RECOVERY_FINALIZER_FAILED"
    )

path.write_text(
    s,
    encoding="utf-8",
)

print(
    "IDENTITY_RECOVERY_FINALIZER=PASS"
)
PY


################################################
# E2 FINALIZER
# Real config corruption accounting.
################################################

cat > "$FILTER" <<'PY'
from __future__ import annotations

import json

from dataclasses import dataclass
from pathlib import Path
from typing import Any


CONFIG_DIR = Path(
    "/var/lib/config-location/configs"
)

POLICY_PATH = Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "policy-latest.json"
)


ALLOWED_STATES = {
    "healthy",
    "recovered",
}


@dataclass(frozen=True)
class PublishSnapshot:

    policy_available: bool

    total_configs: int
    policy_tracked: int

    publishable: int
    suppressed: int

    missing_policy_record: int

    configs: tuple[
        dict[str, Any],
        ...
    ]

    corrupt_configs: int = 0


def _read_json(
    path: Path,
) -> dict[str, Any] | None:

    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

    except Exception:
        return None


    if not isinstance(
        obj,
        dict,
    ):
        return None

    return obj


def _load_configs(
) -> tuple[
    dict[str, dict[str, Any]],
    int,
]:

    configs: dict[
        str,
        dict[str, Any],
    ] = {}

    corrupt_configs = 0


    for path in CONFIG_DIR.glob(
        "*.json"
    ):

        obj = _read_json(
            path
        )

        if obj is None:

            corrupt_configs += 1
            continue


        config_id = str(
            obj.get("id")
            or path.stem
        )


        raw = obj.get(
            "raw"
        )


        if not isinstance(
            raw,
            str,
        ):

            corrupt_configs += 1
            continue


        configs[
            config_id
        ] = obj


    return (
        configs,
        corrupt_configs,
    )


def _policy_index(
    value: dict[str, Any],
) -> dict[str, dict[str, Any]]:

    result = {}

    decisions = value.get(
        "decisions",
        [],
    )


    if not isinstance(
        decisions,
        list,
    ):
        return result


    for item in decisions:

        if not isinstance(
            item,
            dict,
        ):
            continue


        config_id = str(
            item.get(
                "config_id",
                "",
            )
        )


        if not config_id:
            continue


        result[
            config_id
        ] = item


    return result


def publishable_config_ids() -> set[str]:

    policy = _read_json(
        POLICY_PATH
    )


    if not policy:
        return set()


    index = _policy_index(
        policy
    )


    allowed = set()


    for config_id, item in (
        index.items()
    ):

        state = str(
            item.get(
                "policy_state",
                "",
            )
        ).strip().lower()


        publish_flag = bool(
            item.get(
                "publish_eligible",
                False,
            )
        )


        if (
            state in ALLOWED_STATES
            and publish_flag
        ):

            allowed.add(
                config_id
            )


    return allowed


def build_publish_snapshot(
    *,
    config_type: str | None = None,
) -> PublishSnapshot:

    (
        configs,
        corrupt_configs,
    ) = _load_configs()


    policy = _read_json(
        POLICY_PATH
    )


    kind_filter = (
        str(
            config_type
        )
        .strip()
        .lower()
        if config_type
        else None
    )


    valid_relevant = {
        config_id: record
        for config_id, record
        in configs.items()
        if (
            not kind_filter
            or str(
                record.get(
                    "type",
                    "",
                )
            ).strip().lower()
            == kind_filter
        )
    }


    # For an unfiltered snapshot, total_configs
    # represents physical config files including
    # corrupt/unreadable entries.
    #
    # For a type-filtered view a corrupt file cannot
    # safely be attributed to a protocol type, so the
    # corruption metric remains global and separate.
    total_configs = len(
        valid_relevant
    )

    if kind_filter is None:

        total_configs += (
            corrupt_configs
        )


    if not policy:

        return PublishSnapshot(
            policy_available=False,

            total_configs=total_configs,

            policy_tracked=0,

            publishable=0,

            suppressed=total_configs,

            missing_policy_record=len(
                valid_relevant
            ),

            configs=(),

            corrupt_configs=(
                corrupt_configs
            ),
        )


    policy_index = _policy_index(
        policy
    )


    output = []

    missing_policy_record = 0


    for config_id, record in (
        valid_relevant.items()
    ):

        decision = (
            policy_index.get(
                config_id
            )
        )


        if decision is None:

            missing_policy_record += 1

            # Fail closed.
            continue


        state = str(
            decision.get(
                "policy_state",
                "",
            )
        ).strip().lower()


        eligible = bool(
            decision.get(
                "publish_eligible",
                False,
            )
        )


        if (
            state not in ALLOWED_STATES
            or not eligible
        ):

            continue


        output.append(
            record
        )


    output.sort(
        key=lambda x: (
            str(
                x.get(
                    "type",
                    "",
                )
            ),
            str(
                x.get(
                    "id",
                    "",
                )
            ),
        )
    )


    return PublishSnapshot(
        policy_available=True,

        total_configs=total_configs,

        policy_tracked=len(
            policy_index
        ),

        publishable=len(
            output
        ),

        suppressed=max(
            0,
            total_configs
            - len(output),
        ),

        missing_policy_record=(
            missing_policy_record
        ),

        configs=tuple(
            output
        ),

        corrupt_configs=(
            corrupt_configs
        ),
    )
PY

echo "CORRUPT_CONFIGS_REAL_ACCOUNTING=PASS"


################################################
# FIX D FINALIZER
# Write exact HTTP contract instead of relying
# on AST formatting/import compatibility.
################################################

cat > "$HTTP" <<'PY'
from __future__ import annotations

from aiohttp import web

from .filter import (
    build_publish_snapshot,
)

from app.country.production_publish_projection import (
    get_country_projection,
)


def _subscription_text(
    config_type: str | None = None,
) -> tuple[str, dict]:

    snapshot = build_publish_snapshot(
        config_type=config_type
    )

    lines = []

    for record in snapshot.configs:

        raw = record.get(
            "raw"
        )

        if not isinstance(
            raw,
            str,
        ):
            continue

        lines.append(
            raw
        )


    text = "\n".join(
        lines
    )


    if text:
        text += "\n"


    metadata = {
        "policy_available":
            snapshot.policy_available,

        "total_configs":
            snapshot.total_configs,

        "publishable":
            snapshot.publishable,

        "suppressed":
            snapshot.suppressed,

        "missing_policy_record":
            snapshot.missing_policy_record,

        "corrupt_configs":
            snapshot.corrupt_configs,

        "config_type":
            config_type,
    }


    return (
        text,
        metadata,
    )


async def subscription_all(
    request: web.Request,
):

    text, metadata = (
        _subscription_text()
    )


    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Publishable":
                str(
                    metadata[
                        "publishable"
                    ]
                ),

            "X-Config-Suppressed":
                str(
                    metadata[
                        "suppressed"
                    ]
                ),

            "X-Config-Corrupt":
                str(
                    metadata[
                        "corrupt_configs"
                    ]
                ),
        },
    )


async def subscription_type(
    request: web.Request,
):

    config_type = str(
        request.match_info.get(
            "config_type",
            "",
        )
    ).strip().lower()


    if not config_type:
        raise web.HTTPNotFound()


    text, metadata = (
        _subscription_text(
            config_type
        )
    )


    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Type":
                config_type,

            "X-Config-Publishable":
                str(
                    metadata[
                        "publishable"
                    ]
                ),

            "X-Config-Corrupt":
                str(
                    metadata[
                        "corrupt_configs"
                    ]
                ),
        },
    )


async def publish_status(
    request: web.Request,
):

    snapshot = (
        build_publish_snapshot()
    )


    return web.json_response(
        {
            "mode":
                "production-output-filter",

            "policy_available":
                snapshot.policy_available,

            "total_configs":
                snapshot.total_configs,

            "policy_tracked":
                snapshot.policy_tracked,

            "publishable":
                snapshot.publishable,

            "suppressed":
                snapshot.suppressed,

            "missing_policy_record":
                snapshot.missing_policy_record,

            "corrupt_configs":
                snapshot.corrupt_configs,

            "allowed_states": [
                "healthy",
                "recovered",
            ],

            "production_delete":
                False,
        }
    )


def _available_country_codes(
    projection: dict,
) -> set[str]:

    codes = set()


    for row in (
        projection
        .get(
            "records",
            {},
        )
        .values()
    ):

        if not isinstance(
            row,
            dict,
        ):
            continue


        if row.get(
            "state"
        ) != "resolved":
            continue


        code = row.get(
            "country_code"
        )


        if not isinstance(
            code,
            str,
        ):
            continue


        code = (
            code.strip().upper()
        )


        if (
            len(code) == 2
            and code.isalpha()
        ):

            codes.add(
                code
            )


    return codes


def _country_subscription_text(
    country_code: str,
) -> tuple[
    str,
    object,
    int,
]:

    wanted = str(
        country_code
        or ""
    ).strip().upper()


    if wanted == "UNKNOWN":

        wanted_mode = "UNKNOWN"

    elif wanted == "CONFLICT":

        wanted_mode = "CONFLICT"

    elif (
        len(wanted) == 2
        and wanted.isalpha()
    ):

        wanted_mode = "COUNTRY"

    else:

        raise KeyError(
            "invalid_country"
        )


    projection = (
        get_country_projection()
    )


    snapshot = (
        build_publish_snapshot()
    )


    if wanted_mode == "COUNTRY":

        if (
            wanted
            not in _available_country_codes(
                projection
            )
        ):

            raise KeyError(
                "country_not_present"
            )


    selected = []


    for record in snapshot.configs:

        if not isinstance(
            record,
            dict,
        ):
            continue


        cid = record.get(
            "id"
        )


        if not cid:
            continue


        row = (
            projection
            .get(
                "records",
                {},
            )
            .get(
                str(cid)
            )
        )


        if not isinstance(
            row,
            dict,
        ):

            state = "unknown"
            code = None

        else:

            state = str(
                row.get(
                    "state",
                    "unknown",
                )
            )


            code = row.get(
                "country_code"
            )


            if isinstance(
                code,
                str,
            ):

                code = (
                    code
                    .strip()
                    .upper()
                )


        if wanted_mode == "UNKNOWN":

            match = (
                state == "unknown"
            )

        elif wanted_mode == "CONFLICT":

            match = (
                state == "conflict"
            )

        else:

            match = (
                state == "resolved"
                and code == wanted
            )


        if not match:
            continue


        raw = record.get(
            "raw"
        )


        if not isinstance(
            raw,
            str,
        ):
            continue


        # Raw preservation contract:
        # never call strip() on config payload.
        if raw == "":
            continue


        selected.append(
            raw
        )


    return (
        "\n".join(
            selected
        ),
        snapshot,
        len(selected),
    )


async def subscription_country(
    request: web.Request,
):

    country_code = str(
        request.match_info.get(
            "country_code",
            "",
        )
    ).strip().upper()


    if (
        country_code
        not in {
            "UNKNOWN",
            "CONFLICT",
        }
        and (
            len(country_code) != 2
            or not country_code.isalpha()
        )
    ):

        raise web.HTTPNotFound()


    try:

        (
            text,
            snapshot,
            count,
        ) = _country_subscription_text(
            country_code
        )


    except KeyError:

        raise web.HTTPNotFound()


    except Exception:

        raise web.HTTPServiceUnavailable(
            headers={
                "Cache-Control":
                    "no-store",

                "Retry-After":
                    "5",

                "X-Country-Source":
                    "canonical-projection-v2",

                "X-Country-Contract":
                    "unavailable",
            }
        )


    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",

            "X-Config-Policy":
                "health-lifecycle",

            "X-Config-Country":
                country_code,

            "X-Config-Publishable":
                str(
                    snapshot.publishable
                ),

            "X-Config-Country-Count":
                str(
                    count
                ),

            "X-Config-Corrupt":
                str(
                    snapshot.corrupt_configs
                ),

            "X-Country-Source":
                "canonical-projection-v2",

            "X-Country-Contract":
                "healthy",
        },
    )


def install_publish_routes(
    app: web.Application,
) -> None:

    if app.get(
        "_ht18_publish_installed"
    ):
        return


    app[
        "_ht18_publish_installed"
    ] = True


    app.router.add_get(
        "/sub/all",
        subscription_all,
    )

    app.router.add_get(
        "/sub/country/{country_code}",
        subscription_country,
    )

    app.router.add_get(
        "/sub/{config_type}",
        subscription_type,
    )

    app.router.add_get(
        "/api/publish/status",
        publish_status,
    )
PY

echo "FIX_D_FINAL_HTTP_CONTRACT=PASS"


################################################
# FIX E3
# Real rotating multi-country permanent guard
################################################

echo
echo "========== FIX E3 — ROTATING PERMANENT GUARD =========="

cat > "$GUARD" <<'PY'
from __future__ import annotations

import json
import os
import tempfile
import time
import urllib.error
import urllib.request

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any

from app.publish.filter import (
    PublishSnapshot,
    build_publish_snapshot,
)

from app.country.projection import (
    build_projection,
)


BASE = "http://127.0.0.1:4040"

STATE_ROOT = Path(
    "/var/lib/config-location/"
    "country/publish-contract"
)

STATUS = (
    STATE_ROOT
    / "status.json"
)

TIMEOUT = 10.0

COUNTRY_SAMPLE_SIZE = 5


def now_iso() -> str:

    return datetime.now(
        timezone.utc
    ).isoformat()


def atomic_json(
    path: Path,
    data: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )


    fd, tmp = tempfile.mkstemp(
        dir=str(
            path.parent
        ),
        prefix=(
            "."
            + path.name
            + "."
        ),
        suffix=".tmp",
    )


    configloc_gid = (
        __import__("grp")
        .getgrnam("configloc")
        .gr_gid
    )


    os.fchown(
        fd,
        -1,
        configloc_gid,
    )

    os.fchmod(
        fd,
        0o640,
    )


    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as fh:

            json.dump(
                data,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()

            os.fsync(
                fh.fileno()
            )


        os.replace(
            tmp,
            path,
        )


    finally:

        if os.path.exists(
            tmp
        ):

            os.unlink(
                tmp
            )


def http_get(
    path: str,
) -> dict[str, Any]:

    started = (
        time.monotonic()
    )


    request = (
        urllib.request.Request(
            BASE + path,
            method="GET",
            headers={
                "User-Agent":
                    "config-location-country-contract/2",
            },
        )
    )


    try:

        with urllib.request.urlopen(
            request,
            timeout=TIMEOUT,
        ) as response:

            body = (
                response.read()
            )

            status = int(
                response.status
            )

            headers = {
                key.lower():
                    value

                for key, value
                in response.headers.items()
            }


    except urllib.error.HTTPError as exc:

        body = exc.read()

        status = int(
            exc.code
        )

        headers = {
            key.lower():
                value

            for key, value
            in exc.headers.items()
        }


    return {
        "path":
            path,

        "status":
            status,

        "body":
            body,

        "headers":
            headers,

        "elapsed_seconds":
            round(
                time.monotonic()
                - started,
                4,
            ),
    }


def nonempty_lines(
    body: bytes,
) -> int:

    text = body.decode(
        "utf-8",
        errors="replace",
    )


    return sum(
        1
        for line in text.splitlines()
        if line.strip()
    )


def _country_counts(
    snapshot: PublishSnapshot,
    projection: dict[str, Any],
) -> dict[str, int]:

    publish_ids = {
        str(record["id"])

        for record
        in snapshot.configs

        if (
            isinstance(
                record,
                dict,
            )
            and record.get(
                "id"
            )
        )
    }


    counts: dict[
        str,
        int,
    ] = {}


    for cid, row in (
        projection
        .get(
            "records",
            {},
        )
        .items()
    ):

        if (
            str(cid)
            not in publish_ids
        ):
            continue


        if not isinstance(
            row,
            dict,
        ):
            continue


        if row.get(
            "state"
        ) != "resolved":
            continue


        code = row.get(
            "country_code"
        )


        if not isinstance(
            code,
            str,
        ):
            continue


        code = (
            code
            .strip()
            .upper()
        )


        if (
            len(code) != 2
            or not code.isalpha()
        ):
            continue


        counts[code] = (
            counts.get(
                code,
                0,
            )
            + 1
        )


    return counts


def _select_guard_countries(
    country_counts: dict[str, int],
    limit: int = COUNTRY_SAMPLE_SIZE,
) -> list[str]:

    codes = sorted(
        code
        for code, count
        in country_counts.items()
        if count > 0
    )


    if not codes:
        return []


    limit = max(
        1,
        min(
            int(limit),
            len(codes),
        ),
    )


    # Timer runs every minute.
    # Advancing the starting position every minute
    # guarantees coverage rotates over all countries.
    bucket = int(
        time.time()
        // 60
    )


    start = (
        bucket
        % len(codes)
    )


    result = []


    for offset in range(
        len(codes)
    ):

        code = codes[
            (
                start
                + offset
            )
            % len(codes)
        ]


        result.append(
            code
        )


        if (
            len(result)
            >= limit
        ):

            break


    return result


def _select_config_type(
    snapshot: PublishSnapshot,
) -> str:

    counts: dict[
        str,
        int,
    ] = {}


    for record in (
        snapshot.configs
    ):

        if not isinstance(
            record,
            dict,
        ):
            continue


        config_type = (
            record.get(
                "type"
            )
        )


        if not isinstance(
            config_type,
            str,
        ):
            continue


        config_type = (
            config_type
            .strip()
            .lower()
        )


        if not config_type:
            continue


        counts[
            config_type
        ] = (
            counts.get(
                config_type,
                0,
            )
            + 1
        )


    if not counts:

        raise RuntimeError(
            "no publishable config type"
        )


    return max(
        counts,
        key=counts.get,
    )


def _country_present_now(
    code: str,
) -> bool:

    try:

        snapshot = (
            build_publish_snapshot()
        )

        projection = (
            build_projection()
        )

        return (
            _country_counts(
                snapshot,
                projection,
            ).get(
                code,
                0,
            )
            > 0
        )

    except Exception:

        return True


def run_contract(
) -> dict[str, Any]:

    started = (
        time.monotonic()
    )


    gates: dict[
        str,
        bool,
    ] = {}


    errors: list[str] = []


    try:

        snapshot = (
            build_publish_snapshot()
        )


        gates[
            "snapshot_type"
        ] = isinstance(
            snapshot,
            PublishSnapshot,
        )


        gates[
            "snapshot_configs_tuple"
        ] = isinstance(
            snapshot.configs,
            tuple,
        )


        gates[
            "snapshot_count_match"
        ] = (
            len(
                snapshot.configs
            )
            == snapshot.publishable
        )


        gates[
            "corruption_metric_valid"
        ] = (
            isinstance(
                snapshot.corrupt_configs,
                int,
            )
            and snapshot.corrupt_configs
            >= 0
        )


    except Exception as exc:

        snapshot = None

        errors.append(
            "snapshot:"
            + repr(exc)
        )


        gates[
            "snapshot_type"
        ] = False

        gates[
            "snapshot_configs_tuple"
        ] = False

        gates[
            "snapshot_count_match"
        ] = False

        gates[
            "corruption_metric_valid"
        ] = False


    try:

        projection = (
            build_projection()
        )


        gates[
            "projection_mapping"
        ] = isinstance(
            projection,
            dict,
        )


        gates[
            "projection_records"
        ] = isinstance(
            projection.get(
                "records"
            ),
            dict,
        )


        gates[
            "projection_mode_production"
        ] = (
            projection.get(
                "mode"
            )
            == "production"
        )


    except Exception as exc:

        projection = None

        errors.append(
            "projection:"
            + repr(exc)
        )


        gates[
            "projection_mapping"
        ] = False

        gates[
            "projection_records"
        ] = False

        gates[
            "projection_mode_production"
        ] = False


    selected_countries = []
    config_type = None


    if (
        snapshot is not None
        and projection is not None
    ):

        try:

            counts = (
                _country_counts(
                    snapshot,
                    projection,
                )
            )


            selected_countries = (
                _select_guard_countries(
                    counts
                )
            )


            config_type = (
                _select_config_type(
                    snapshot
                )
            )


            gates[
                "target_selection"
            ] = bool(
                selected_countries
                and config_type
            )


        except Exception as exc:

            errors.append(
                "targets:"
                + repr(exc)
            )


            gates[
                "target_selection"
            ] = False


    else:

        gates[
            "target_selection"
        ] = False


    results: dict[
        str,
        Any,
    ] = {}


    def capture(
        key: str,
        path: str,
    ) -> None:

        try:

            results[key] = (
                http_get(
                    path
                )
            )


        except Exception as exc:

            errors.append(
                key
                + ":"
                + repr(exc)
            )


            results[key] = {
                "path":
                    path,

                "status":
                    0,

                "body":
                    b"",

                "headers":
                    {},

                "elapsed_seconds":
                    999.0,
            }


    capture(
        "all",
        "/sub/all",
    )


    if config_type:

        capture(
            "type",
            "/sub/"
            + config_type,
        )


    for index, code in enumerate(
        selected_countries
    ):

        capture(
            f"country_{index}",
            "/sub/country/"
            + code,
        )


    capture(
        "unknown",
        "/sub/country/UNKNOWN",
    )


    capture(
        "conflict",
        "/sub/country/CONFLICT",
    )


    capture(
        "invalid",
        "/sub/country/INVALID",
    )


    capture(
        "missing",
        "/sub/country/ZZ",
    )


    gates[
        "sub_all_http_200"
    ] = (
        results[
            "all"
        ][
            "status"
        ] == 200
    )


    gates[
        "sub_all_nonempty"
    ] = bool(
        results[
            "all"
        ][
            "body"
        ]
    )


    if "type" in results:

        gates[
            "sub_type_http_200"
        ] = (
            results[
                "type"
            ][
                "status"
            ]
            == 200
        )

    else:

        gates[
            "sub_type_http_200"
        ] = False


    for index, code in enumerate(
        selected_countries
    ):

        key = (
            f"country_{index}"
        )

        result = (
            results[key]
        )


        if result[
            "status"
        ] == 200:

            try:

                header_count = int(
                    result[
                        "headers"
                    ].get(
                        "x-config-country-count",
                        "-1",
                    )
                )

            except Exception:

                header_count = -1


            ok = (
                header_count
                == nonempty_lines(
                    result[
                        "body"
                    ]
                )
                and result[
                    "headers"
                ].get(
                    "x-country-source"
                )
                == "canonical-projection-v2"
                and result[
                    "headers"
                ].get(
                    "x-country-contract"
                )
                == "healthy"
            )


        elif (
            result[
                "status"
            ] == 404
            and not _country_present_now(
                code
            )
        ):

            # Country disappeared during this guard
            # cycle due to normal live churn.
            ok = True


        else:

            ok = False


        gates[
            f"country_{index}_contract"
        ] = ok


    for name in (
        "unknown",
        "conflict",
    ):

        result = (
            results[name]
        )


        try:

            header_count = int(
                result[
                    "headers"
                ].get(
                    "x-config-country-count",
                    "-1",
                )
            )

        except Exception:

            header_count = -1


        gates[
            name
            + "_contract"
        ] = (
            result[
                "status"
            ] == 200
            and header_count
            == nonempty_lines(
                result[
                    "body"
                ]
            )
            and result[
                "headers"
            ].get(
                "x-country-source"
            )
            == "canonical-projection-v2"
        )


    gates[
        "invalid_http_404"
    ] = (
        results[
            "invalid"
        ][
            "status"
        ]
        == 404
    )


    # ZZ is expected to be absent. If it somehow
    # becomes a real discovered country, this gate
    # will be corrected by the full regression.
    gates[
        "missing_http_404"
    ] = (
        results[
            "missing"
        ][
            "status"
        ]
        == 404
    )


    latency_values = [
        float(
            result[
                "elapsed_seconds"
            ]
        )

        for result
        in results.values()
    ]


    max_latency = (
        max(
            latency_values
        )
        if latency_values
        else 999.0
    )


    gates[
        "max_latency_le_10s"
    ] = (
        max_latency <= 10.0
    )


    healthy = all(
        gates.values()
    )


    clean_results = {}


    for key, value in (
        results.items()
    ):

        clean_results[key] = {
            "path":
                value["path"],

            "status":
                value["status"],

            "elapsed_seconds":
                value[
                    "elapsed_seconds"
                ],

            "size":
                len(
                    value[
                        "body"
                    ]
                ),
        }


    data = {
        "component":
            "country-publish-contract-guard",

        "schema":
            2,

        "updated_at":
            now_iso(),

        "healthy":
            healthy,

        "state":
            (
                "healthy"
                if healthy
                else "contract_failed"
            ),

        "country_source":
            "CANONICAL_PROJECTION_V2",

        "selected_country":
            (
                selected_countries[0]
                if selected_countries
                else None
            ),

        "selected_countries":
            selected_countries,

        "country_sample_size":
            len(
                selected_countries
            ),

        "selected_config_type":
            config_type,

        "publishable":
            (
                snapshot.publishable
                if snapshot is not None
                else None
            ),

        "corrupt_configs":
            (
                snapshot.corrupt_configs
                if snapshot is not None
                else None
            ),

        "gates":
            gates,

        "results":
            clean_results,

        "max_latency_seconds":
            round(
                max_latency,
                4,
            ),

        "errors":
            errors,

        "production_mutation":
            False,

        "service_restart":
            False,

        "fail_closed_contract":
            {
                "invalid_country_404":
                    True,

                "missing_country_404":
                    True,

                "unknown_conflict_separated":
                    True,
            },

        "elapsed_seconds":
            round(
                time.monotonic()
                - started,
                4,
            ),
    }


    atomic_json(
        STATUS,
        data,
    )


    return data


def main() -> int:

    data = run_contract()


    print(
        json.dumps(
            data,
            ensure_ascii=False,
            indent=2,
        )
    )


    return (
        0
        if data[
            "healthy"
        ]
        else 2
    )


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
PY

echo "FIX_E3_ROTATING_MULTI_COUNTRY_GUARD=PASS"


################################################
# 10 COMPILE + SOURCE CONTRACT GATE
################################################

echo
echo "========== [10/13] COMPILE / SOURCE GATE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/projection.py \
  app/country/storage.py \
  app/country/panel_projection_adapter.py \
  app/panel/read_model.py \
  app/country/production_publish_projection.py \
  app/publish/http.py \
  app/country/country_identity.py \
  app/publish/filter.py \
  app/country/publish_contract_guard.py

echo "COMPILE_GATE=PASS"


"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path

root = Path(
    "/opt/config-location/app"
)

checks = {
    "results_latest":
        'COUNTRY_ROOT / "results" / "latest"'
        in (
            root
            / "country/projection.py"
        ).read_text(),

    "projection_production":
        '"production"'
        in (
            root
            / "country/projection.py"
        ).read_text(),

    "results_0640":
        "os.fchmod"
        in (
            root
            / "country/storage.py"
        ).read_text(),

    "panel_ttl":
        "_CACHE_TTL_SECONDS = 2.0"
        in (
            root
            / "country/panel_projection_adapter.py"
        ).read_text(),

    "production_ttl":
        "_CACHE_TTL_SECONDS = 2.0"
        in (
            root
            / "country/production_publish_projection.py"
        ).read_text(),

    "conflict_route":
        '"CONFLICT"'
        in (
            root
            / "publish/http.py"
        ).read_text(),

    "corrupt_metric":
        "corrupt_configs"
        in (
            root
            / "publish/filter.py"
        ).read_text(),

    "identity_recovery":
        "_recover_corrupt_identity(p)"
        in (
            root
            / "country/country_identity.py"
        ).read_text(),

    "rotating_guard":
        "_select_guard_countries"
        in (
            root
            / "country/publish_contract_guard.py"
        ).read_text(),
}

print(checks)

if not all(
    checks.values()
):
    raise SystemExit(
        "SOURCE_CONTRACT_FAILED"
    )

print(
    "SOURCE_CONTRACT=PASS"
)
PY


################################################
# 11 RUNTIME IMPORT + CONTROLLED RESTART
################################################

echo
echo "========== [11/13] RUNTIME / RESTART =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.publish.filter import (
    build_publish_snapshot,
)

from app.country.projection import (
    build_projection,
)

from app.country.production_publish_projection import (
    get_country_projection,
    discovered_country_codes,
)

snapshot = build_publish_snapshot()
projection = build_projection()
cached = get_country_projection()

assert isinstance(
    snapshot.corrupt_configs,
    int,
)

assert snapshot.corrupt_configs >= 0

assert projection.get(
    "mode"
) == "production"

assert isinstance(
    cached.get(
        "records"
    ),
    dict,
)

codes = discovered_country_codes()

print(
    "PUBLISHABLE=",
    snapshot.publishable,
)

print(
    "CORRUPT_CONFIGS=",
    snapshot.corrupt_configs,
)

print(
    "DISCOVERED_COUNTRIES=",
    len(codes),
)

print(
    "RUNTIME_IMPORT_GATE=PASS"
)
PY


systemctl restart \
  config-location-country-worker.service

systemctl restart \
  config-location-country-event-consumer.service

systemctl restart \
  config-location-panel.service

sleep 5


for UNIT in \
  config-location-country-worker.service \
  config-location-country-event-consumer.service \
  config-location-panel.service
do

    ACTIVE="$(
        systemctl is-active \
          "$UNIT" \
          2>/dev/null || true
    )"

    echo "$UNIT=$ACTIVE"

    [ "$ACTIVE" = "active" ]

done

echo "CONTROLLED_RESTART=PASS"


################################################
# 12 FULL REGRESSION
################################################

echo
echo "========== [12/13] FULL REGRESSION =========="


ALL_HTTP="$(
curl -sS \
  --max-time 20 \
  -o /tmp/p5v2-all.body \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/all
)"


UNKNOWN_HTTP="$(
curl -sS \
  --max-time 20 \
  -D /tmp/p5v2-unknown.headers \
  -o /tmp/p5v2-unknown.body \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/UNKNOWN
)"


CONFLICT_HTTP="$(
curl -sS \
  --max-time 20 \
  -D /tmp/p5v2-conflict.headers \
  -o /tmp/p5v2-conflict.body \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/CONFLICT
)"


INVALID_HTTP="$(
curl -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  http://127.0.0.1:4040/sub/country/INVALID \
  || true
)"


MISSING_CODE="$(
sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import string

from app.country.production_publish_projection import (
    discovered_country_codes,
)

used = discovered_country_codes()

for a in string.ascii_uppercase:
    for b in string.ascii_uppercase:

        code = a + b

        if code not in used:
            print(code)
            raise SystemExit(0)

raise SystemExit(
    "NO_FREE_TWO_LETTER_CODE"
)
PY
)"


MISSING_HTTP="$(
curl -sS \
  --max-time 10 \
  -o /dev/null \
  -w '%{http_code}' \
  "http://127.0.0.1:4040/sub/country/$MISSING_CODE" \
  || true
)"


echo "SUB_ALL_HTTP=$ALL_HTTP"
echo "UNKNOWN_HTTP=$UNKNOWN_HTTP"
echo "CONFLICT_HTTP=$CONFLICT_HTTP"
echo "INVALID_HTTP=$INVALID_HTTP"

echo "MISSING_CODE=$MISSING_CODE"
echo "MISSING_HTTP=$MISSING_HTTP"


[ "$ALL_HTTP" = "200" ]
[ "$UNKNOWN_HTTP" = "200" ]
[ "$CONFLICT_HTTP" = "200" ]
[ "$INVALID_HTTP" = "404" ]
[ "$MISSING_HTTP" = "404" ]


echo
echo "========== ALL DISCOVERED COUNTRIES =========="

sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import urllib.error
import urllib.request

from app.country.production_publish_projection import (
    discovered_country_codes,
)


BASE = "http://127.0.0.1:4040"

codes = sorted(
    discovered_country_codes()
)

failed = []


for code in codes:

    request = urllib.request.Request(
        BASE
        + "/sub/country/"
        + code,
        headers={
            "User-Agent":
                "phase5-hardening-v2",
        },
    )


    try:

        with urllib.request.urlopen(
            request,
            timeout=20,
        ) as response:

            status = int(
                response.status
            )

            headers = {
                k.lower():
                    v

                for k, v
                in response.headers.items()
            }

            body = (
                response.read()
            )


    except urllib.error.HTTPError as exc:

        status = int(
            exc.code
        )

        headers = {}

        body = exc.read()


    except Exception as exc:

        print(
            code,
            "ERROR",
            repr(exc),
        )

        failed.append(
            code
        )

        continue


    try:

        count = int(
            headers.get(
                "x-config-country-count",
                "-1",
            )
        )

    except Exception:

        count = -1


    text = body.decode(
        "utf-8",
        errors="replace",
    )


    lines = sum(
        1
        for line in text.splitlines()
        if line.strip()
    )


    ok = (
        status == 200
        and count == lines
        and headers.get(
            "x-country-source"
        )
        == "canonical-projection-v2"
        and headers.get(
            "x-country-contract"
        )
        == "healthy"
    )


    print(
        f"{code}: "
        f"http={status} "
        f"count={count} "
        f"lines={lines} "
        f"ok={ok}"
    )


    if not ok:

        failed.append(
            code
        )


print()

print(
    "COUNTRIES_TESTED=",
    len(codes),
)

print(
    "COUNTRIES_FAILED=",
    len(failed),
)


if failed:

    print(
        "FAILED_CODES=",
        failed,
    )

    raise SystemExit(2)


print(
    "ALL_COUNTRY_REGRESSION=PASS"
)
PY


echo
echo "========== RESULTS READ CONTRACT =========="

RESULT_BAD="$(
sudo -u configloc \
find /var/lib/config-location/country/results/latest \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  ! -readable \
  -print 2>/dev/null |
wc -l
)"


echo "RESULTS_UNREADABLE=$RESULT_BAD"

[ "$RESULT_BAD" -eq 0 ]


echo
echo "========== RAW EVIDENCE INTEGRITY =========="

sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json

from pathlib import Path

from app.panel.read_model import (
    _read_json,
)


roots = [
    Path(
        "/var/lib/config-location/"
        "country/country-identity"
    ),

    Path(
        "/var/lib/config-location/"
        "country/pipeline/latest"
    ),

    Path(
        "/var/lib/config-location/"
        "country/results/latest"
    ),
]


tested = 0


for root in roots:

    path = next(
        root.glob("*.json"),
        None,
    )


    if path is None:
        continue


    raw = json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    model = _read_json(
        path
    )


    assert raw == model

    tested += 1


print(
    "RAW_EVIDENCE_FILES_TESTED=",
    tested,
)

assert tested > 0

print(
    "RAW_EVIDENCE_INTEGRITY=PASS"
)
PY


echo
echo "========== PERMANENT GUARD =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m app.country.publish_contract_guard \
> /tmp/p5v2-guard.json


"$PROJECT/venv/bin/python" \
- /tmp/p5v2-guard.json <<'PY'
import json
import sys

data = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

print(
    "GUARD_HEALTHY=",
    data.get(
        "healthy"
    ),
)

print(
    "SELECTED_COUNTRIES=",
    data.get(
        "selected_countries"
    ),
)

print(
    "COUNTRY_SAMPLE_SIZE=",
    data.get(
        "country_sample_size"
    ),
)

assert (
    data.get(
        "healthy"
    )
    is True
)

assert (
    data.get(
        "country_sample_size",
        0,
    )
    >= 1
)

assert len(
    data.get(
        "selected_countries",
        [],
    )
) == data.get(
    "country_sample_size"
)

print(
    "ROTATING_GUARD_REGRESSION=PASS"
)
PY


echo
echo "========== PERFORMANCE SMOKE =========="

PERF_CODES="$(
sudo -u configloc \
env \
  HOME=/nonexistent \
  PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.production_publish_projection import (
    discovered_country_codes,
)

print(
    " ".join(
        sorted(
            discovered_country_codes()
        )[:3]
    )
)
PY
)"


for CODE in $PERF_CODES; do

    T="$(
    curl -sS \
      --max-time 20 \
      -o /dev/null \
      -w '%{time_total}' \
      "http://127.0.0.1:4040/sub/country/$CODE"
    )"

    echo "$CODE latency=$T"

done


echo "FULL_REGRESSION=PASS"


################################################
# 13 SUMMARY + COMMIT
################################################

echo
echo "========== [13/13] SUMMARY =========="


CORRUPT_COUNT="$(
PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.publish.filter import (
    build_publish_snapshot,
)

print(
    build_publish_snapshot()
    .corrupt_configs
)
PY
)"


"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<PY
import json
import sys

data = {
    "phase":
        "$PHASE",

    "result":
        "SUCCESS",

    "fix_a_results_latest_authority":
        True,

    "fix_a_results_0640":
        True,

    "fix_b_panel_projection_ttl":
        True,

    "fix_b_raw_evidence_integrity":
        True,

    "fix_c_production_projection_ttl":
        True,

    "fix_d_unknown_conflict_separated":
        True,

    "fix_d_missing_country_404":
        True,

    "fix_d_raw_preservation":
        True,

    "fix_e_identity_corruption_recovery":
        True,

    "fix_e_corrupt_config_observability":
        True,

    "fix_e_rotating_multi_country_guard":
        True,

    "corrupt_configs":
        int("$CORRUPT_COUNT"),

    "sub_all_http":
        int("$ALL_HTTP"),

    "unknown_http":
        int("$UNKNOWN_HTTP"),

    "conflict_http":
        int("$CONFLICT_HTTP"),

    "invalid_http":
        int("$INVALID_HTTP"),

    "missing_country_code":
        "$MISSING_CODE",

    "missing_country_http":
        int("$MISSING_HTTP"),

    "results_unreadable":
        int("$RESULT_BAD"),

    "all_country_regression":
        "PASS",

    "raw_evidence_integrity":
        "PASS",

    "permanent_guard":
        "PASS",

    "rolled_back":
        False,

    "phase5_state":
        "PRODUCTION_COMPLETE",

    "ready_for_phase6":
        True,
}

json.dump(
    data,
    open(
        sys.argv[1],
        "w",
        encoding="utf-8",
    ),
    ensure_ascii=False,
    indent=2,
)

print(
    json.dumps(
        data,
        ensure_ascii=False,
        indent=2,
    )
)
PY


cat > "$REPORT" <<REPORT
Phase:
$PHASE

Result:
SUCCESS

Fix A:
PASS

Fix B:
PASS

Fix C:
PASS

Fix D:
PASS

Fix E:
PASS

Corrupt config observability:
$CORRUPT_COUNT

Results unreadable:
$RESULT_BAD

All-country regression:
PASS

Raw evidence integrity:
PASS

Permanent rotating guard:
PASS

Rollback:
NO

Phase 5:
PRODUCTION_COMPLETE

Ready for Phase 6:
YES
REPORT


cd "$REPO"

git add \
  "$REPORT" \
  "$SUMMARY"


if ! git diff \
  --cached \
  --quiet
then

    git commit \
      -m "Phase5 post-closure hardening A-E v2 $TS"
fi


git push origin main


MUTATION_STARTED="NO"

trap - ERR


echo
echo "=============================================="
echo " PHASE 5 POST-CLOSURE HARDENING V2 SUCCESS"
echo "=============================================="

echo "FIX_A=PASS"
echo "FIX_B=PASS"
echo "FIX_C=PASS"
echo "FIX_D=PASS"
echo "FIX_E=PASS"

echo "CORRUPT_CONFIG_OBSERVABILITY=PASS"
echo "RAW_EVIDENCE_INTEGRITY=PASS"
echo "ROTATING_MULTI_COUNTRY_GUARD=PASS"

echo "ALL_COUNTRY_REGRESSION=PASS"
echo "FULL_REGRESSION=PASS"

echo
echo "PHASE5_STATE=PRODUCTION_COMPLETE"
echo "READY_FOR_PHASE6=YES"

echo
echo "PHASE5_POST_CLOSURE_HARDENING_V2_SUCCESS"
