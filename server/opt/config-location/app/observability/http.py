from __future__ import annotations

import html

from aiohttp import web

from .lifecycle import (
    build_lifecycle_observability,
)


def esc(
    value,
) -> str:

    return html.escape(
        str(
            value
        )
    )


def _fa_status(
    value,
) -> tuple[str, str]:

    normalized = str(
        value
    ).strip().lower()


    if normalized in {
        "healthy",
        "synced",
        "idle",
        "active",
        "running",
    }:
        return (
            "سالم",
            "green",
        )


    if normalized in {
        "warning",
        "recover",
        "degraded",
    }:
        return (
            "هشدار",
            "",
        )


    if normalized in {
        "error",
        "stale",
        "critical",
        "failed",
    }:
        return (
            "مشکل‌دار",
            "red",
        )


    return (
        "نامشخص",
        "secondary",
    )


def _display_time(
    value,
) -> str:

    text = str(
        value
        or ""
    ).strip()

    if not text:
        return "نامشخص"

    return (
        text
        .replace(
            "T",
            " "
        )
        .replace(
            "+00:00",
            " UTC"
        )
    )


def _seconds(
    value,
) -> str:

    if value is None:
        return "نامشخص"

    try:

        number = float(
            value
        )

        if number < 1:
            return (
                f"{number:.2f} ثانیه"
            )

        if number < 60:
            return (
                f"{number:.1f} ثانیه"
            )

        return (
            f"{number / 60:.1f} دقیقه"
        )

    except Exception:

        return esc(
            value
        )


async def lifecycle_status(
    request: web.Request,
):

    return web.json_response(
        build_lifecycle_observability()
    )


async def lifecycle_page(
    request: web.Request,
):

    # Import here intentionally.
    # This avoids circular imports during app startup.
    from app.panel.server import page


    try:

        data = (
            build_lifecycle_observability()
        )

    except Exception as exc:

        content = f"""
<div class="card">

<h3>
سلامت / چرخه عمر
</h3>

<div class="error">
امکان خواندن وضعیت Lifecycle وجود ندارد.
<br>
{esc(type(exc).__name__)}
</div>

<a
 class="button secondary"
 href="/"
>
بازگشت به پنل
</a>

</div>
"""

        return page(
            "سلامت / چرخه عمر",
            content,
        )


    policy = data.get(
        "policy",
        {}
    )

    tracker = data.get(
        "tracker",
        {}
    )

    sync = data.get(
        "sync",
        {}
    )

    watchdog = data.get(
        "watchdog",
        {}
    )

    freshness = data.get(
        "freshness",
        {}
    )

    safety = data.get(
        "safety",
        {}
    )


    (
        overall_fa,
        overall_class,
    ) = _fa_status(
        data.get(
            "state",
            "unknown",
        )
    )


    (
        sync_fa,
        sync_class,
    ) = _fa_status(
        sync.get(
            "state",
            "unknown",
        )
    )


    (
        watchdog_fa,
        watchdog_class,
    ) = _fa_status(
        watchdog.get(
            "state",
            "unknown",
        )
    )


    warnings = (
        data.get(
            "warnings"
        )
        or []
    )


    if warnings:

        warning_html = (
            "<div class=\"notice\">"
            "<strong>هشدارها</strong>"
            "<ul>"
            + "".join(
                "<li>"
                + esc(item)
                + "</li>"
                for item
                in warnings
            )
            + "</ul>"
            "</div>"
        )

    else:

        warning_html = """
<div class="msg">
هیچ هشدار فعالی وجود ندارد.
</div>
"""


    production_delete = (
        "فعال"
        if safety.get(
            "production_delete"
        )
        else "غیرفعال"
    )


    panel_read_only = (
        "بله"
        if safety.get(
            "panel_read_only"
        )
        else "خیر"
    )


    mutation_from_panel = (
        "فعال"
        if safety.get(
            "lifecycle_mutation_from_panel"
        )
        else "غیرفعال"
    )


    content = f"""

<div class="source-tools">

<a
 class="button secondary"
 href="/"
>
بازگشت به پنل
</a>

<a
 class="button"
 href="/api/lifecycle/status"
>
API JSON
</a>

<a
 class="button"
 href="/api/publish/status"
>
وضعیت انتشار
</a>

</div>


<div class="card">

<h3>
سلامت / چرخه عمر
</h3>

<div class="grid">


<div class="stat">

<strong>
{esc(
    policy.get(
        "healthy",
        0,
    )
)}
</strong>

سالم

</div>


<div class="stat">

<strong>
{esc(
    policy.get(
        "recovered",
        0,
    )
)}
</strong>

بازیابی‌شده

</div>


<div class="stat">

<strong>
{esc(
    policy.get(
        "publish_eligible",
        0,
    )
)}
</strong>

قابل انتشار

</div>


<div class="stat">

<strong>
{esc(
    policy.get(
        "quarantine",
        0,
    )
)}
</strong>

قرنطینه

</div>


<div class="stat">

<strong>
{esc(
    policy.get(
        "deep_quarantine",
        0,
    )
)}
</strong>

قرنطینه عمیق

</div>


<div class="stat">

<strong>
{esc(
    policy.get(
        "delete_candidate_shadow",
        0,
    )
)}
</strong>

کاندید حذف

</div>


<div class="stat">

<strong>
{esc(
    policy.get(
        "error_retry",
        0,
    )
)}
</strong>

تلاش مجدد خطا

</div>


<div class="stat">

<strong>
{esc(
    policy.get(
        "unknown",
        0,
    )
)}
</strong>

نامشخص

</div>


</div>

</div>


<div class="grid">


<div class="card">

<h3>
وضعیت کلی
</h3>

<p>
وضعیت:
<span class="button {overall_class}">
{esc(overall_fa)}
</span>
</p>

<p>
تعداد ردیابی:
<strong>
{esc(
    policy.get(
        "tracked_count",
        0,
    )
)}
</strong>
</p>

<p>
حذف از انتشار:
<strong>
{esc(
    policy.get(
        "suppressed",
        0,
    )
)}
</strong>
</p>

<p>
حذف Production:
<strong>
{esc(production_delete)}
</strong>
</p>

</div>


<div class="card">

<h3>
ردیاب
</h3>

<p>
در دسترس:
<strong>
{esc(
    tracker.get(
        "available",
        False,
    )
)}
</strong>
</p>

<p>
تعداد ردیابی:
<strong>
{esc(
    tracker.get(
        "tracked_count",
        0,
    )
)}
</strong>
</p>

<p>
رکوردها:
<strong>
{esc(
    tracker.get(
        "record_count",
        0,
    )
)}
</strong>
</p>

<p>
نتایج جدید:
<strong>
{esc(
    tracker.get(
        "processed_new_results",
        0,
    )
)}
</strong>
</p>

<p>
بدون تغییر:
<strong>
{esc(
    tracker.get(
        "unchanged_results",
        0,
    )
)}
</strong>
</p>

</div>


<div class="card">

<h3>
همگام‌سازی چرخه عمر
</h3>

<p>
وضعیت:
<span class="button {sync_class}">
{esc(sync_fa)}
</span>
</p>

<p>
چرخه:
<strong>
{esc(
    sync.get(
        "cycle",
        0,
    )
)}
</strong>
</p>

<p>
تعداد Sync:
<strong>
{esc(
    sync.get(
        "sync_count",
        0,
    )
)}
</strong>
</p>

<p>
تعداد خطا:
<strong>
{esc(
    sync.get(
        "error_count",
        0,
    )
)}
</strong>
</p>

<p>
نتایج جدید:
<strong>
{esc(
    sync.get(
        "processed_new_results",
        0,
    )
)}
</strong>
</p>

<p>
مدت اجرا:
<strong>
{esc(
    sync.get(
        "sync_duration_ms"
    )
)}
 ms
</strong>
</p>

<p>
فاصله خواب:
<strong>
{esc(
    sync.get(
        "sleep_seconds"
    )
)}
 s
</strong>
</p>

<p>
Write علت:
<strong>
{esc(
    sync.get(
        "write_reason"
    )
)}
</strong>
</p>

</div>


<div class="card">

<h3>
نگهبان
</h3>

<p>
وضعیت:
<span class="button {watchdog_class}">
{esc(watchdog_fa)}
</span>
</p>

<p>
علت:
<strong>
{esc(
    watchdog.get(
        "reason",
        "unknown",
    )
)}
</strong>
</p>

<p>
تعداد بازیابی:
<strong>
{esc(
    watchdog.get(
        "recovery_count",
        0,
    )
)}
</strong>
</p>

<p>
خطای Restart:
<strong>
{esc(
    watchdog.get(
        "restart_failures",
        0,
    )
)}
</strong>
</p>

<p>
سرویس Sync فعال:
<strong>
{esc(
    watchdog.get(
        "sync_service_active",
        False,
    )
)}
</strong>
</p>

<p>
Write علت:
<strong>
{esc(
    watchdog.get(
        "write_reason"
    )
)}
</strong>
</p>

</div>


</div>


<!-- UI19.5 DETAIL INDICATORS -->

<div class="card">

<h3>
شاخص‌های هشدار
</h3>

<div class="grid">


<div class="stat">

<strong>
{esc(
    len(
        data.get(
            "warnings"
        )
        or []
    )
)}
</strong>

تعداد هشدار

</div>


<div class="stat">

<strong>
{esc(
    "فعال"
    if safety.get(
        "global_freeze"
    )
    else "غیرفعال"
)}
</strong>

Global Freeze

</div>


<div class="stat">

<strong>
{esc(
    "سالم"
    if sync.get(
        "state"
    )
    in {
        "synced",
        "idle",
    }
    else "نیازمند بررسی"
)}
</strong>

وضعیت Sync

</div>


<div class="stat">

<strong>
{esc(
    "سالم"
    if watchdog.get(
        "state"
    )
    == "healthy"
    else "نیازمند بررسی"
)}
</strong>

وضعیت Watchdog

</div>


</div>

</div>


<div class="card">

<h3>
تازگی داده‌ها
</h3>

<div class="grid">


<div class="stat">

<strong>
{_seconds(
    freshness.get(
        "tracker_seconds"
    )
)}
</strong>

ردیاب

</div>


<div class="stat">

<strong>
{_seconds(
    freshness.get(
        "policy_seconds"
    )
)}
</strong>

Policy

</div>


<div class="stat">

<strong>
{_seconds(
    freshness.get(
        "sync_seconds"
    )
)}
</strong>

Sync Status

</div>


<div class="stat">

<strong>
{_seconds(
    freshness.get(
        "watchdog_seconds"
    )
)}
</strong>

نگهبان

</div>


</div>

</div>


<div class="card">

<h3>
ایمنی
</h3>

<div class="grid">


<div class="stat">

<strong>
{esc(
    production_delete
)}
</strong>

حذف Production

</div>


<div class="stat">

<strong>
{esc(
    panel_read_only
)}
</strong>

Panel Read Only

</div>


<div class="stat">

<strong>
{esc(
    mutation_from_panel
)}
</strong>

Lifecycle Mutation

</div>


</div>

<div class="notice">
این صفحه فقط برای مشاهده وضعیت است و هیچ Configی را تغییر یا حذف نمی‌کند.
</div>

</div>


<div class="card">

<h3>
هشدارها
</h3>

{warning_html}

</div>


<div class="card">

<h3>
اطلاعات Snapshot
</h3>

<p>
زمان Snapshot:
<strong>
{esc(
    _display_time(
        data.get(
            "generated_at",
            ""
        )
    )
)}
</strong>
</p>

</div>

"""


    response = page(
        "سلامت / چرخه عمر",
        content,
    )

    response.headers[
        "Cache-Control"
    ] = "no-store"

    return response


def install_lifecycle_observability_routes(
    app: web.Application,
) -> None:

    if app.get(
        "_ht18_lifecycle_observability"
    ):
        return


    app[
        "_ht18_lifecycle_observability"
    ] = True


    app.router.add_get(
        "/lifecycle",
        lifecycle_page,
    )


    app.router.add_get(
        "/api/lifecycle/status",
        lifecycle_status,
    )
