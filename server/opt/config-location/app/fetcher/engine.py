from __future__ import annotations

import asyncio
import json
import os
import signal
import time

from datetime import datetime, timezone
from pathlib import Path

import httpx

from app.core.source_manager import (
    list_sources,
    get_source,
)

from app.core.source_runtime import (
    read_runtime,
    update_runtime,
)

from app.core.config_store import (
    upsert_config,
    config_stats,
    sync_source_snapshot,
)

from app.parser.detector import (
    extract_configs,
)


DATA = Path(
    "/var/lib/config-location"
)

STATUS_FILE = (
    DATA
    / "state"
    / "fetcher-status.json"
)

TRIGGER_FILE = (
    DATA
    / "state"
    / "fetch-now.trigger"
)

SOURCE_TRIGGER_DIR = (
    DATA
    / "source-triggers"
)

SOURCE_TRIGGER_DIR.mkdir(
    parents=True,
    exist_ok=True,
)

MAX_RESPONSE = (
    10 * 1024 * 1024
)

# -------------------------------------------------------
# Global network safety limit
#
# IMPORTANT:
# This limits simultaneous HTTP REQUESTS only.
# It does NOT lock an entire source worker.
#
# Therefore rotating source A cannot block worker B.
# -------------------------------------------------------

GLOBAL_REQUEST_CONCURRENCY = 12

CONNECT_TIMEOUT = 8.0
READ_TIMEOUT = 15.0
TOTAL_TIMEOUT = 30.0

# Rotating source discovery
ROTATING_MAX_REQUESTS = 100
ROTATING_DUPLICATE_STOP = 12

# Bulk source confirmation
BULK_MAX_REQUESTS = 2

# Empty/unknown source
UNKNOWN_MAX_REQUESTS = 5
UNKNOWN_EMPTY_STOP = 3

# Supervisor discovers source additions/removals/changes
SUPERVISOR_TICK = 1.0

# Minimum delay inside rotating loops
REQUEST_GAP = 0.08

# -------------------------------------------------------
# Per-source failure isolation V2
# -------------------------------------------------------

REQUEST_RETRIES = 3

RETRY_DELAYS = (
    0.35,
    0.75,
)

SOURCE_BACKOFF_STEPS = (
    2.0,
    4.0,
    8.0,
    16.0,
    30.0,
)

running = True

cycle_no = 0

worker_tasks: dict[str, asyncio.Task] = {}
worker_wake_events: dict[str, asyncio.Event] = {}
worker_signatures: dict[str, tuple] = {}

request_semaphore: asyncio.Semaphore | None = None


def now_iso():
    return datetime.now(
        timezone.utc
    ).isoformat()


def ensure_state_dir():
    STATUS_FILE.parent.mkdir(
        parents=True,
        exist_ok=True,
    )


def write_status(
    **changes
):
    global cycle_no

    ensure_state_dir()

    default = {
        "status": "running",
        "running": True,
        "last_cycle_at": None,
        "last_success_at": None,
        "heartbeat_at": now_iso(),

        # Kept for old panel compatibility.
        "current_source": None,

        # New worker architecture fields.
        "architecture": "independent-workers-v1",
        "worker_count": 0,
        "active_workers": 0,
        "enabled_sources": 0,

        "cycle": cycle_no,
        "total_configs": 0,
        "error": None,
    }

    try:
        if STATUS_FILE.exists():
            old = json.loads(
                STATUS_FILE.read_text(
                    encoding="utf-8"
                )
            )

            if isinstance(
                old,
                dict
            ):
                default.update(
                    old
                )

    except Exception:
        pass

    default.update(
        changes
    )

    default[
        "heartbeat_at"
    ] = now_iso()

    tmp = STATUS_FILE.with_suffix(
        ".tmp"
    )

    tmp.write_text(
        json.dumps(
            default,
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    os.replace(
        tmp,
        STATUS_FILE,
    )


def source_signature(
    source: dict
):
    """
    If one of these values changes, supervisor can restart only
    this source worker without touching the other workers.
    """

    return (
        str(
            source.get(
                "normalized_url"
            )
            or source.get(
                "url"
            )
            or ""
        ),

        int(
            source.get(
                "fetch_interval_seconds",
                60,
            )
            or 60
        ),

        str(
            source.get(
                "fetch_mode",
                "auto",
            )
            or "auto"
        ),

        bool(
            source.get(
                "enabled",
                True,
            )
        ),

        int(
            source.get(
                "url_generation",
                0,
            )
            or 0
        ),
    )


async def fetch_body(
    client: httpx.AsyncClient,
    url: str,
):
    """
    Only a single HTTP request occupies the global semaphore.

    A rotating source that performs 100 requests releases the semaphore
    after every request, allowing all other sources to progress.
    """

    global request_semaphore

    if request_semaphore is None:
        raise RuntimeError(
            "request_semaphore_not_initialized"
        )

    async with request_semaphore:

        async with client.stream(
            "GET",
            url,
        ) as response:

            response.raise_for_status()

            chunks = []
            size = 0

            async for chunk in response.aiter_bytes():

                size += len(
                    chunk
                )

                if size > MAX_RESPONSE:
                    raise RuntimeError(
                        "response_too_large"
                    )

                chunks.append(
                    chunk
                )

            raw = b"".join(
                chunks
            )

            content_type = (
                response.headers.get(
                    "content-type",
                    "",
                )
                .lower()
            )

            encoding = (
                response.encoding
                or "utf-8"
            )

            try:
                text = raw.decode(
                    encoding,
                    errors="replace",
                )

            except Exception:
                text = raw.decode(
                    "utf-8",
                    errors="replace",
                )

            return (
                text,
                response.status_code,
                content_type,
            )


async def fetch_body_with_retry(
    client: httpx.AsyncClient,
    url: str,
):
    """
    Retry ONE HTTP request only.

    Retry state belongs to the current source worker.
    No other source is blocked or restarted.
    """

    last_error = None

    for attempt in range(
        1,
        REQUEST_RETRIES + 1,
    ):
        try:
            body, status_code, content_type = (
                await fetch_body(
                    client,
                    url,
                )
            )

            return (
                body,
                status_code,
                content_type,
                attempt,
            )

        except asyncio.CancelledError:
            raise

        except Exception as e:
            last_error = e

            if attempt >= REQUEST_RETRIES:
                break

            delay_index = min(
                attempt - 1,
                len(RETRY_DELAYS) - 1,
            )

            await asyncio.sleep(
                RETRY_DELAYS[
                    delay_index
                ]
            )

    raise last_error


async def run_source_once(
    client: httpx.AsyncClient,
    source: dict,
):
    """
    One independent fetch session for exactly ONE source.

    No other source is awaited here.
    """

    source_id = str(
        source["id"]
    )

    url = str(
        source["url"]
    )

    started = now_iso()

    previous = read_runtime(
        source_id
    )

    total_fetches = int(
        previous.get(
            "total_fetches",
            0,
        )
        or 0
    )

    total_success = int(
        previous.get(
            "total_success",
            0,
        )
        or 0
    )

    total_errors = int(
        previous.get(
            "total_errors",
            0,
        )
        or 0
    )

    configured_mode = str(
        source.get(
            "fetch_mode",
            "auto",
        )
        or "auto"
    ).lower()

    if configured_mode not in {
        "auto",
        "bulk",
        "rotating",
    }:
        configured_mode = "auto"

    previous_inferred_mode = str(
        previous.get(
            "inferred_mode",
            "auto",
        )
        or "auto"
    ).lower()

    # Explicit per-source mode has priority.
    if configured_mode in {
        "bulk",
        "rotating",
    }:
        inferred_mode = configured_mode

    else:
        # Auto will be re-detected from the response.
        inferred_mode = "auto"

    update_runtime(
        source_id,

        state="fetching",
        current=True,

        worker_pid=os.getpid(),

        last_fetch_started_at=started,
        last_fetch_at=started,

        configured_mode=configured_mode,

        last_error=None,
    )

    seen_this_session = set()

    new_count = 0
    found_count = 0

    duplicate_streak = 0
    empty_streak = 0

    requests_done = 0

    successful_responses = 0
    stop_reason = None
    authoritative_snapshot = False

    last_status_code = None
    last_content_type = None

    try:

        while running:

            # Source may be disabled/deleted while this worker is busy.
            live_source = get_source(
                source_id
            )

            if (
                not live_source
                or not live_source.get(
                    "enabled",
                    True,
                )
            ):
                stop_reason = (
                    "source_removed_or_disabled"
                )
                break

            requests_done += 1

            try:

                (
                    body,
                    status_code,
                    content_type,
                    request_attempts,
                ) = await fetch_body_with_retry(
                    client,
                    url,
                )

                total_fetches += (
                    request_attempts
                )

                last_status_code = (
                    status_code
                )

                last_content_type = (
                    content_type
                )

                successful_responses += 1

            except asyncio.CancelledError:
                raise

            except Exception:

                # All retries for THIS request failed.
                total_fetches += (
                    REQUEST_RETRIES
                )

                total_errors += 1

                raise

            items = extract_configs(
                body
            )

            response_fingerprints = {
                x["fingerprint"]
                for x in items
                if x.get(
                    "fingerprint"
                )
            }

            session_new = (
                response_fingerprints
                - seen_this_session
            )

            # ------------------------------------------------
            # AUTO detection only.
            #
            # Explicit source fetch_mode is never overridden.
            # ------------------------------------------------

            if (
                configured_mode == "auto"
                and requests_done == 1
            ):

                if len(items) > 1:
                    inferred_mode = "bulk"

                elif len(items) == 1:
                    inferred_mode = "rotating"

                else:
                    inferred_mode = "unknown"

            if items:

                empty_streak = 0
                total_success += 1

                for item in items:

                    found_count += 1

                    _, created = upsert_config(
                        item,
                        source_id,
                    )

                    if created:
                        new_count += 1

                if session_new:
                    duplicate_streak = 0

                else:
                    duplicate_streak += 1

                seen_this_session.update(
                    response_fingerprints
                )

            else:

                empty_streak += 1
                duplicate_streak += 1

            # -----------------------------
            # BULK
            # -----------------------------

            if (
                inferred_mode == "bulk"
                and requests_done
                >= BULK_MAX_REQUESTS
            ):
                stop_reason = (
                    "bulk_complete"
                )

                authoritative_snapshot = (
                    successful_responses > 0
                )

                break

            # -----------------------------
            # ROTATING
            # -----------------------------

            if inferred_mode == "rotating":

                if (
                    duplicate_streak
                    >= ROTATING_DUPLICATE_STOP
                ):
                    stop_reason = (
                        "rotating_cycle_complete"
                    )

                    authoritative_snapshot = (
                        successful_responses > 0
                    )

                    break

                if (
                    requests_done
                    >= ROTATING_MAX_REQUESTS
                ):
                    # We reached the safety request ceiling.
                    #
                    # DO NOT remove ownership here because
                    # the source may have more configs than
                    # the configured request ceiling.
                    stop_reason = (
                        "rotating_request_limit"
                    )

                    authoritative_snapshot = False

                    break

            # -----------------------------
            # UNKNOWN
            # -----------------------------

            if inferred_mode in {
                "unknown",
                "auto",
            }:

                if (
                    empty_streak
                    >= UNKNOWN_EMPTY_STOP
                    or requests_done
                    >= UNKNOWN_MAX_REQUESTS
                ):
                    stop_reason = (
                        "unknown_source_limit"
                    )

                    # Unknown/undetermined source responses
                    # are not authoritative enough to prune
                    # previously owned configs.
                    authoritative_snapshot = False

                    break

            await asyncio.sleep(
                REQUEST_GAP
            )

        finished = now_iso()

        ownership_sync = {
            "source_id": source_id,
            "authoritative": False,
            "current": len(
                seen_this_session
            ),
            "previous": 0,
            "missing": 0,
            "detached": 0,
            "deleted": 0,
            "kept_shared": 0,
            "baseline_created": False,
            "snapshot_updated": False,
        }

        # ------------------------------------------------
        # Per-source ownership reconciliation
        #
        # Only a COMPLETE / AUTHORITATIVE source cycle may
        # remove old source ownership.
        # ------------------------------------------------

        if authoritative_snapshot:

            try:

                ownership_sync = (
                    sync_source_snapshot(
                        source_id,
                        seen_this_session,
                        authoritative=True,
                    )
                )

            except Exception as sync_error:

                # Fetch itself remains successful.
                # Never destroy the worker because cleanup
                # metadata failed.
                ownership_sync = {
                    "source_id":
                        source_id,

                    "authoritative":
                        True,

                    "current":
                        len(
                            seen_this_session
                        ),

                    "snapshot_updated":
                        False,

                    "error":
                        str(
                            sync_error
                        )[:450],
                }

        update_runtime(
            source_id,

            state="idle",
            current=False,

            last_fetch_at=finished,
            last_fetch_finished_at=finished,

            last_success_at=(
                finished
                if seen_this_session
                else previous.get(
                    "last_success_at"
                )
            ),

            last_error=None,

            configured_mode=configured_mode,
            inferred_mode=inferred_mode,

            requests_last_cycle=requests_done,

            configs_last_cycle=len(
                seen_this_session
            ),

            found_last_cycle=found_count,

            new_configs_last_cycle=new_count,

            total_fetches=total_fetches,
            total_success=total_success,
            total_errors=total_errors,

            last_http_status=last_status_code,
            last_content_type=last_content_type,

            stop_reason=stop_reason,

            authoritative_snapshot=(
                authoritative_snapshot
            ),

            successful_responses=(
                successful_responses
            ),

            ownership_sync=(
                ownership_sync
            ),

            last_fetch_epoch=time.time(),

            consecutive_failures=0,
            current_backoff_seconds=0,
            backoff_until_epoch=0,
        )

        return {
            "ok": True,

            "source_id":
                source_id,

            "mode":
                inferred_mode,

            "configured_mode":
                configured_mode,

            "requests":
                requests_done,

            "unique":
                len(
                    seen_this_session
                ),

            "new":
                new_count,

            "stop_reason":
                stop_reason,

            "authoritative_snapshot":
                authoritative_snapshot,

            "ownership_sync":
                ownership_sync,
        }

    except asyncio.CancelledError:

        update_runtime(
            source_id,

            state="cancelled",
            current=False,

            last_fetch_finished_at=now_iso(),

            last_fetch_epoch=time.time(),
        )

        raise

    except Exception as e:

        total_errors += 1

        failed_runtime = read_runtime(
            source_id
        )

        consecutive_failures = (
            int(
                failed_runtime.get(
                    "consecutive_failures",
                    0,
                )
                or 0
            )
            + 1
        )

        backoff_index = min(
            consecutive_failures - 1,
            len(SOURCE_BACKOFF_STEPS) - 1,
        )

        backoff_seconds = (
            SOURCE_BACKOFF_STEPS[
                backoff_index
            ]
        )

        backoff_until_epoch = (
            time.time()
            + backoff_seconds
        )

        update_runtime(
            source_id,

            state="error",
            current=False,

            last_fetch_at=now_iso(),
            last_fetch_finished_at=now_iso(),

            last_error=str(
                e
            )[:500],

            configured_mode=configured_mode,
            inferred_mode=inferred_mode,

            requests_last_cycle=requests_done,

            total_fetches=total_fetches,
            total_success=total_success,
            total_errors=total_errors,

            last_http_status=last_status_code,
            last_content_type=last_content_type,

            last_fetch_epoch=time.time(),

            consecutive_failures=(
                consecutive_failures
            ),

            current_backoff_seconds=(
                backoff_seconds
            ),

            backoff_until_epoch=(
                backoff_until_epoch
            ),
        )

        return {
            "ok": False,

            "source_id":
                source_id,

            "error":
                str(
                    e
                ),
        }


def seconds_until_due(
    source: dict,
):
    """
    Independent timer for one source.
    """

    source_id = str(
        source["id"]
    )

    runtime = read_runtime(
        source_id
    )

    last_epoch = float(
        runtime.get(
            "last_fetch_epoch",
            0,
        )
        or 0
    )

    backoff_until_epoch = float(
        runtime.get(
            "backoff_until_epoch",
            0,
        )
        or 0
    )

    interval = max(
        10,
        int(
            source.get(
                "fetch_interval_seconds",
                60,
            )
            or 60
        ),
    )

    if last_epoch <= 0:
        return 0.0

    due_at = (
        last_epoch
        + interval
    )

    # Backoff belongs ONLY to this source.
    #
    # Normal interval is still respected. Backoff never
    # pauses or changes another source worker.
    effective_due_at = max(
        due_at,
        backoff_until_epoch,
    )

    return max(
        0.0,
        effective_due_at - time.time(),
    )


async def wait_or_wake(
    event: asyncio.Event,
    timeout: float,
):
    """
    Wait for this source's own timer OR its own wake event.
    """

    if timeout <= 0:
        return "timer"

    try:

        await asyncio.wait_for(
            event.wait(),
            timeout=timeout,
        )

        event.clear()

        return "trigger"

    except asyncio.TimeoutError:

        return "timer"


async def source_worker(
    source_id: str,
    client: httpx.AsyncClient,
    wake_event: asyncio.Event,
):
    """
    Permanent independent worker for one source_id.
    """

    update_runtime(
        source_id,

        worker_state="started",
        worker_started_at=now_iso(),
        worker_pid=os.getpid(),
    )

    try:

        while running:

            source = get_source(
                source_id
            )

            # Deleted.
            if not source:
                break

            # Disabled sources remain isolated and sleep.
            if not source.get(
                "enabled",
                True,
            ):

                update_runtime(
                    source_id,

                    state="disabled",
                    current=False,
                    worker_state="waiting_disabled",
                )

                await wait_or_wake(
                    wake_event,
                    2.0,
                )

                continue

            delay = seconds_until_due(
                source
            )

            if delay > 0:

                update_runtime(
                    source_id,

                    worker_state="sleeping",
                    next_fetch_in_seconds=round(
                        delay,
                        2,
                    ),
                )

                await wait_or_wake(
                    wake_event,
                    delay,
                )

                if not running:
                    break

                # Re-read source after waking because its
                # URL/mode/interval may have changed.
                source = get_source(
                    source_id
                )

                if (
                    not source
                    or not source.get(
                        "enabled",
                        True,
                    )
                ):
                    continue

            update_runtime(
                source_id,

                worker_state="fetching",
                next_fetch_in_seconds=0,
            )

            result = await run_source_once(
                client,
                source,
            )

            update_runtime(
                source_id,

                worker_state="sleeping",

                last_worker_result=result,

                worker_heartbeat_at=now_iso(),
            )

            # Give the supervisor/event loop a scheduling point.
            await asyncio.sleep(
                0
            )

    except asyncio.CancelledError:

        update_runtime(
            source_id,

            worker_state="cancelled",
            current=False,
            worker_stopped_at=now_iso(),
        )

        raise

    except Exception as e:

        update_runtime(
            source_id,

            worker_state="crashed",
            current=False,

            worker_stopped_at=now_iso(),

            last_error=(
                "worker_crash: "
                + str(
                    e
                )[:450]
            ),
        )

    finally:

        try:
            update_runtime(
                source_id,

                current=False,
                worker_state="stopped",
                worker_stopped_at=now_iso(),
            )

        except Exception:
            pass


def active_worker_count():
    return sum(
        1
        for task in worker_tasks.values()
        if not task.done()
    )


def currently_fetching_count(
    source_ids
):
    count = 0

    for source_id in source_ids:

        runtime = read_runtime(
            source_id
        )

        if runtime.get(
            "state"
        ) == "fetching":
            count += 1

    return count


async def stop_worker(
    source_id: str,
):
    task = worker_tasks.pop(
        source_id,
        None,
    )

    worker_wake_events.pop(
        source_id,
        None,
    )

    worker_signatures.pop(
        source_id,
        None,
    )

    if not task:
        return

    if task.done():
        return

    task.cancel()

    try:
        await task

    except asyncio.CancelledError:
        pass

    except Exception:
        pass


async def start_worker(
    source: dict,
    client: httpx.AsyncClient,
):
    source_id = str(
        source["id"]
    )

    wake_event = asyncio.Event()

    task = asyncio.create_task(
        source_worker(
            source_id,
            client,
            wake_event,
        ),
        name=(
            "source-worker-"
            + source_id
        ),
    )

    worker_tasks[
        source_id
    ] = task

    worker_wake_events[
        source_id
    ] = wake_event

    worker_signatures[
        source_id
    ] = source_signature(
        source
    )


async def reconcile_workers(
    client: httpx.AsyncClient,
):
    """
    Hot reconciliation.

    - Add source -> create worker
    - Delete source -> cancel only that worker
    - Edit source -> restart only that worker
    """

    sources = {
        str(
            source["id"]
        ):
        source

        for source in list_sources()

        # Even disabled source gets a worker so enabling
        # it does not require a service restart.
    }

    desired_ids = set(
        sources
    )

    existing_ids = set(
        worker_tasks
    )

    # Deleted sources.
    for source_id in (
        existing_ids
        - desired_ids
    ):
        await stop_worker(
            source_id
        )

    # New or changed sources.
    for source_id, source in sources.items():

        signature = source_signature(
            source
        )

        task = worker_tasks.get(
            source_id
        )

        if task is None:

            await start_worker(
                source,
                client,
            )

            continue

        # Unexpected worker death -> recreate.
        if task.done():

            await stop_worker(
                source_id
            )

            await start_worker(
                source,
                client,
            )

            continue

        old_signature = worker_signatures.get(
            source_id
        )

        if old_signature != signature:

            # Only this worker is restarted.
            await stop_worker(
                source_id
            )

            await start_worker(
                source,
                client,
            )



def source_trigger_path(
    source_id: str
):
    return (
        SOURCE_TRIGGER_DIR
        / f"{source_id}.trigger"
    )


def consume_source_triggers():
    """
    Wake only requested source workers.

    Each trigger file belongs to exactly one source.
    """

    consumed = []

    try:
        paths = list(
            SOURCE_TRIGGER_DIR.glob(
                "*.trigger"
            )
        )
    except Exception:
        return consumed

    for path in paths:

        source_id = (
            path.name[
                :-len(".trigger")
            ]
        )

        event = worker_wake_events.get(
            source_id
        )

        if event is None:
            continue

        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except Exception:
            continue

        event.set()

        consumed.append(
            source_id
        )

    return consumed


def trigger_all_workers():
    """
    Fetch Now wakes every source independently.
    """

    for event in worker_wake_events.values():
        event.set()


async def supervisor():
    global request_semaphore
    global cycle_no

    request_semaphore = asyncio.Semaphore(
        GLOBAL_REQUEST_CONCURRENCY
    )

    limits = httpx.Limits(
        max_connections=(
            GLOBAL_REQUEST_CONCURRENCY
            * 2
        ),

        max_keepalive_connections=(
            GLOBAL_REQUEST_CONCURRENCY
        ),
    )

    timeout = httpx.Timeout(
        TOTAL_TIMEOUT,

        connect=CONNECT_TIMEOUT,
        read=READ_TIMEOUT,
    )

    headers = {
        "User-Agent":
            "ConfigLocationFetcher/2.0",

        "Accept":
            "text/plain,application/json,*/*",

        "Cache-Control":
            "no-cache",
    }

    async with httpx.AsyncClient(
        follow_redirects=True,
        max_redirects=5,

        timeout=timeout,
        limits=limits,

        headers=headers,

        verify=True,
    ) as client:

        write_status(
            status="running",
            running=True,

            architecture=(
                "independent-workers-v1"
            ),

            error=None,
        )

        while running:

            cycle_no += 1

            try:

                await reconcile_workers(
                    client
                )

                force = False

                if TRIGGER_FILE.exists():

                    force = True

                    try:
                        TRIGGER_FILE.unlink()

                    except Exception:
                        pass

                if force:
                    trigger_all_workers()

                # Independent Fetch Now requests.
                #
                # Unlike the global trigger, these wake only
                # the requested source worker.
                source_triggers = (
                    consume_source_triggers()
                )

                sources = list_sources()

                enabled_sources = [
                    source
                    for source in sources
                    if source.get(
                        "enabled",
                        True,
                    )
                ]

                source_ids = [
                    str(
                        source["id"]
                    )
                    for source in sources
                ]

                try:
                    stats = config_stats()
                    total_configs = int(
                        stats.get(
                            "total",
                            0,
                        )
                    )

                except Exception:
                    total_configs = 0

                active_fetches = (
                    currently_fetching_count(
                        source_ids
                    )
                )

                write_status(
                    status="running",
                    running=True,

                    architecture=(
                        "independent-workers-v1"
                    ),

                    cycle=cycle_no,

                    last_cycle_at=now_iso(),

                    current_source=None,

                    worker_count=len(
                        worker_tasks
                    ),

                    active_workers=(
                        active_worker_count()
                    ),

                    fetching_sources=(
                        active_fetches
                    ),

                    enabled_sources=len(
                        enabled_sources
                    ),

                    total_configs=(
                        total_configs
                    ),

                    error=None,
                )

            except asyncio.CancelledError:
                raise

            except Exception as e:

                write_status(
                    status="warning",
                    running=True,

                    architecture=(
                        "independent-workers-v1"
                    ),

                    error=(
                        "supervisor: "
                        + str(
                            e
                        )[:450]
                    ),
                )

            await asyncio.sleep(
                SUPERVISOR_TICK
            )

    # Graceful shutdown.
    tasks = list(
        worker_tasks.keys()
    )

    for source_id in tasks:
        await stop_worker(
            source_id
        )


async def main():
    global running

    ensure_state_dir()

    write_status(
        status="starting",
        running=True,

        architecture=(
            "independent-workers-v1"
        ),

        error=None,
    )

    try:

        await supervisor()

    finally:

        write_status(
            status="stopped",
            running=False,

            current_source=None,

            worker_count=0,
            active_workers=0,
        )


def stop_handler(
    *_args
):
    global running

    running = False

    # Wake workers so shutdown does not wait for timers.
    for event in list(
        worker_wake_events.values()
    ):
        try:
            event.set()
        except Exception:
            pass


if __name__ == "__main__":

    signal.signal(
        signal.SIGTERM,
        stop_handler,
    )

    signal.signal(
        signal.SIGINT,
        stop_handler,
    )

    asyncio.run(
        main()
    )
