from __future__ import annotations
from app.panel.page_renderer import page

import json

from aiohttp import web

from app.settings.engine import (
    get_settings,
    get_settings_status,
    update_settings,
)


def _esc(value) -> str:

    import html

    return html.escape(
        str(value)
    )


def _minutes(
    seconds,
) -> int:

    try:
        return max(
            1,
            int(seconds) // 60,
        )
    except Exception:
        return 5


async def api_settings(
    request,
):

    return web.json_response(
        {
            "ok": True,
            "settings":
                get_settings(),
            "status":
                get_settings_status(),
        },
        headers={
            "Cache-Control":
                "no-store",
        },
    )


async def api_settings_update(
    request,
):

    try:
        obj = await request.json()

        if not isinstance(
            obj,
            dict,
        ):
            raise ValueError(
                "JSON body must "
                "be object"
            )

        updated = update_settings(
            obj,
            updated_by="panel-api",
        )

        return web.json_response(
            {
                "ok": True,
                "settings": updated,
                "status":
                    get_settings_status(),
            },
            headers={
                "Cache-Control":
                    "no-store",
            },
        )

    except (
        ValueError,
        json.JSONDecodeError,
    ) as exc:

        return web.json_response(
            {
                "ok": False,
                "error": str(exc),
            },
            status=400,
        )


async def settings_save(
    request,
):

    from aiohttp.web_exceptions import (
        HTTPFound,
    )

    data = await request.post()

    def intval(
        name,
        default,
    ):
        value = data.get(
            name,
            default,
        )

        return int(
            str(value).strip()
        )

    def floatval(
        name,
        default,
    ):
        value = data.get(
            name,
            default,
        )

        return float(
            str(value).strip()
        )

    try:

        patch = {
            "source_intelligence": {
                "healthy_window_hours":
                    intval(
                        "source_window",
                        12,
                    ),
            },

            "health_retest": {
                "interval_seconds":
                    intval(
                        "retest_minutes",
                        5,
                    )
                    * 60,
            },

            "config_lifetime": {
                "max_age_hours":
                    intval(
                        "lifetime_hours",
                        48,
                    ),
            },

            "cleanup": {
                "default_retention_days":
                    intval(
                        "cleanup_days",
                        7,
                    ),
            },

            "resources": {
                "cpu_warning_percent":
                    floatval(
                        "cpu_warning",
                        75,
                    ),

                "cpu_critical_percent":
                    floatval(
                        "cpu_critical",
                        94,
                    ),

                "ram_warning_percent":
                    floatval(
                        "ram_warning",
                        80,
                    ),

                "ram_critical_percent":
                    floatval(
                        "ram_critical",
                        92,
                    ),

                "disk_warning_percent":
                    floatval(
                        "disk_warning",
                        75,
                    ),

                "disk_critical_percent":
                    floatval(
                        "disk_critical",
                        90,
                    ),
            },

            "country": {
                "unknown_name":
                    str(
                        data.get(
                            "unknown_name",
                            "Unknown",
                        )
                    ),

                "remark_format":
                    str(
                        data.get(
                            "remark_format",
                            "{flag} {country}",
                        )
                    ),
            },

            "publish": {
                "public_port":
                    intval(
                        "public_port",
                        80,
                    ),

                "fair_rotation_default_ed":
                    intval(
                        "default_ed",
                        0,
                    ),
            },
        }

        update_settings(
            patch,
            updated_by="panel-form",
        )

    except Exception as exc:

        raise HTTPFound(
            "/settings?error="
            + str(exc)
        )

    raise HTTPFound(
        "/settings?saved=1"
    )


async def settings_page(
    request,
):

    # Lazy import avoids module cycle.
    # page renderer dependency removed from settings_ui

    settings = get_settings()
    status = get_settings_status()

    source_window = settings[
        "source_intelligence"
    ][
        "healthy_window_hours"
    ]

    retest_minutes = _minutes(
        settings[
            "health_retest"
        ][
            "interval_seconds"
        ]
    )

    lifetime = settings[
        "config_lifetime"
    ][
        "max_age_hours"
    ]

    cleanup = settings[
        "cleanup"
    ][
        "default_retention_days"
    ]

    resources = settings[
        "resources"
    ]

    country = settings[
        "country"
    ]

    publish = settings[
        "publish"
    ]

    notice = ""

    if request.query.get(
        "saved"
    ) == "1":

        notice = """
<div class="notice success">
تنظیمات با موفقیت و به‌صورت Atomic ذخیره شد.
</div>
"""

    error = request.query.get(
        "error"
    )

    if error:

        notice += f"""
<div class="notice error">
{_esc(error)}
</div>
"""

    content = f"""
{notice}

<div class="card">

<h2>
⚙️ تنظیمات مرکزی پروژه
</h2>

<p style="color:#64748b;line-height:1.9">
این صفحه Source of Truth تنظیمات نسل جدید پروژه است.
در Phase 1 تنظیمات به‌صورت Versioned و Crash-Safe ذخیره
می‌شوند. اتصال Retest، Lifetime، Source Intelligence،
Publish v2 و Resource Guardian در مراحل بعد انجام می‌شود.
</p>

<div class="grid">

<div class="stat">
<strong>
Schema {status["schema_version"]}
</strong>
نسخه تنظیمات
</div>

<div class="stat">
<strong>
Revision {status["revision"]}
</strong>
Revision فعلی
</div>

<div class="stat">
<strong>
{status["history_count"]}
</strong>
نسخه‌های History
</div>

<div class="stat">
<strong style="font-size:12px;word-break:break-all">
{_esc(status["checksum"][:16])}…
</strong>
Checksum
</div>

</div>

</div>


<form
 method="post"
 action="/settings/save"
>

<div class="card">

<h2>
🧠 Source Intelligence
</h2>

<label>
پنجره بررسی Source بدون کانفیگ سالم
</label>

<input
 type="number"
 name="source_window"
 min="1"
 max="720"
 value="{source_window}"
 required
>

<small>
بر حسب ساعت — مقدار هدف فعلی: 12 ساعت
</small>

</div>


<div class="card">

<h2>
❤️ Health Retest
</h2>

<label>
فاصله تست مجدد هر کانفیگ
</label>

<input
 type="number"
 name="retest_minutes"
 min="1"
 max="1440"
 value="{retest_minutes}"
 required
>

<small>
بر حسب دقیقه؛ مثلاً 5 یا 20 دقیقه.
</small>

</div>


<div class="card">

<h2>
⏳ Config Lifetime
</h2>

<label>
حداکثر عمر کانفیگ
</label>

<input
 type="number"
 name="lifetime_hours"
 min="1"
 max="8760"
 value="{lifetime}"
 required
>

<small>
بر حسب ساعت؛ مقدار هدف فعلی: 48 ساعت.
</small>

</div>


<div class="card">

<h2>
🌍 Country / Remark
</h2>

<label>
نام Country ناشناخته
</label>

<input
 type="text"
 name="unknown_name"
 value="{_esc(country["unknown_name"])}"
 required
>

<label>
Remark Format
</label>

<input
 type="text"
 name="remark_format"
 value="{_esc(country["remark_format"])}"
 required
>

<small>
باید شامل {{country}} باشد.
مثال: {{flag}} {{country}}
</small>

</div>


<div class="card">

<h2>
📡 Subscription
</h2>

<label>
Public Port
</label>

<input
 type="number"
 name="public_port"
 min="1"
 max="65535"
 value="{publish["public_port"]}"
 required
>

<label>
Default ED
</label>

<input
 type="number"
 name="default_ed"
 min="0"
 max="10000"
 value="{publish["fair_rotation_default_ed"]}"
 required
>

</div>


<div class="card">

<h2>
🧹 Cleanup
</h2>

<label>
Retention پیش‌فرض
</label>

<input
 type="number"
 name="cleanup_days"
 min="1"
 max="3650"
 value="{cleanup}"
 required
>

<small>
بر حسب روز؛ مقدار هدف فعلی: 7 روز.
</small>

</div>


<div class="card">

<h2>
🖥 Resource Guardian
</h2>

<div class="grid">

<div>
<label>CPU Warning %</label>
<input
 type="number"
 step="0.1"
 name="cpu_warning"
 value="{resources["cpu_warning_percent"]}"
>
</div>

<div>
<label>CPU Critical %</label>
<input
 type="number"
 step="0.1"
 name="cpu_critical"
 value="{resources["cpu_critical_percent"]}"
>
</div>

<div>
<label>RAM Warning %</label>
<input
 type="number"
 step="0.1"
 name="ram_warning"
 value="{resources["ram_warning_percent"]}"
>
</div>

<div>
<label>RAM Critical %</label>
<input
 type="number"
 step="0.1"
 name="ram_critical"
 value="{resources["ram_critical_percent"]}"
>
</div>

<div>
<label>Disk Warning %</label>
<input
 type="number"
 step="0.1"
 name="disk_warning"
 value="{resources["disk_warning_percent"]}"
>
</div>

<div>
<label>Disk Critical %</label>
<input
 type="number"
 step="0.1"
 name="disk_critical"
 value="{resources["disk_critical_percent"]}"
>
</div>

</div>

</div>


<div class="card">

<button
 type="submit"
 class="button"
>
ذخیره تنظیمات
</button>

<a
 class="button secondary"
 href="/"
>
بازگشت به Dashboard
</a>

</div>

</form>


<div class="card">

<h2>
🔒 وضعیت Activation
</h2>

<p style="line-height:1.9;color:#64748b">
Phase 1 فقط Foundation را فعال کرده است.
هیچ Health Retest، حذف خودکار، Lifetime،
Country Remark یا Port 80 جدید در این مرحله
بدون مرحله مربوطه فعال نمی‌شود.
این رفتار برای جلوگیری از تغییر ناگهانی Production عمدی است.
</p>

</div>
"""

    return page(
        "Central Settings",
        content,
    )


def install_settings_routes(
    app,
) -> None:

    marker = (
        "_configloc_settings_routes"
    )

    if app.get(
        marker
    ):
        return

    app.router.add_get(
        "/settings",
        settings_page,
    )

    app.router.add_post(
        "/settings/save",
        settings_save,
    )

    app.router.add_get(
        "/api/settings",
        api_settings,
    )

    app.router.add_post(
        "/api/settings",
        api_settings_update,
    )

    app[
        marker
    ] = True
