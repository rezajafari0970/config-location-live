from __future__ import annotations

import html
import json

from aiohttp import web

from app.panel.page_renderer import (
    page,
)

from app.settings import (
    SettingsCorruptError,
    SettingsFeatureNotWiredError,
    SettingsRevisionConflictError,
    get_feature_runtime_contracts,
    get_setting_runtime_contracts,
    get_settings,
    get_settings_status,
    prune_settings_history,
    update_settings,
)


def _esc(
    value,
) -> str:

    return html.escape(
        str(
            value
        )
    )


def _minutes(
    seconds,
) -> int:

    try:

        return max(
            1,
            int(
                seconds
            )
            // 60,
        )

    except Exception:

        return 5


def _json_headers():
    return {
        "Cache-Control":
            "no-store",
    }


def _error_response(
    error: str,
    *,
    status: int,
    code: str,
    extra: dict | None = None,
):

    body = {
        "ok": False,
        "error":
            str(
                error
            ),
        "code":
            str(
                code
            ),
    }


    if isinstance(
        extra,
        dict,
    ):

        body.update(
            extra
        )


    return web.json_response(
        body,
        status=status,
        headers=_json_headers(),
    )


def _parse_revision(
    value,
) -> int:

    try:

        revision = int(
            value
        )

    except (
        TypeError,
        ValueError,
    ):

        raise ValueError(
            "expected_revision is required and must be integer"
        )


    if revision < 0:

        raise ValueError(
            "expected_revision must be >= 0"
        )


    return revision


# ============================================================
# API — READ
# ============================================================

async def api_settings(
    request,
):

    try:

        return web.json_response(
            {
                "ok": True,

                "settings":
                    get_settings(),

                "status":
                    get_settings_status(),

                "feature_contracts":
                    get_feature_runtime_contracts(),

                "setting_contracts":
                    get_setting_runtime_contracts(),
            },
            headers=_json_headers(),
        )

    except SettingsCorruptError as exc:

        return _error_response(
            str(
                exc
            ),
            status=503,
            code="settings_store_blocked",
            extra={
                "status":
                    get_settings_status(),
            },
        )


async def api_settings_status(
    request,
):

    return web.json_response(
        {
            "ok": True,
            "status":
                get_settings_status(),
        },
        headers=_json_headers(),
    )


async def api_settings_capabilities(
    request,
):

    return web.json_response(
        {
            "ok": True,

            "features":
                get_feature_runtime_contracts(),

            "settings":
                get_setting_runtime_contracts(),
        },
        headers=_json_headers(),
    )


async def api_settings_history_preview(
    request,
):

    try:

        max_entries = int(
            request.rel_url.query.get(
                "max_entries",
                50,
            )
        )


        max_age_raw = (
            request.rel_url.query.get(
                "max_age_days"
            )
        )


        max_age_days = (
            int(
                max_age_raw
            )
            if max_age_raw
            not in (
                None,
                "",
            )
            else None
        )


        result = prune_settings_history(
            max_entries=max_entries,
            max_age_days=max_age_days,
            dry_run=True,
        )


        return web.json_response(
            {
                "ok": True,
                "preview":
                    result,
            },
            headers=_json_headers(),
        )


    except ValueError as exc:

        return _error_response(
            str(
                exc
            ),
            status=400,
            code="invalid_retention_request",
        )


# ============================================================
# API — UPDATE WITH CAS
# ============================================================

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
                "JSON body must be object"
            )


        if "expected_revision" not in obj:

            raise ValueError(
                "expected_revision is required"
            )


        expected_revision = (
            _parse_revision(
                obj.get(
                    "expected_revision"
                )
            )
        )


        if "patch" in obj:

            patch = obj.get(
                "patch"
            )


            if not isinstance(
                patch,
                dict,
            ):

                raise ValueError(
                    "patch must be object"
                )


            unknown_envelope = (
                set(
                    obj.keys()
                )
                - {
                    "expected_revision",
                    "patch",
                }
            )


            if unknown_envelope:

                raise ValueError(
                    "unknown API envelope key(s): "
                    + ", ".join(
                        sorted(
                            unknown_envelope
                        )
                    )
                )


        else:

            patch = {
                key: value
                for key, value
                in obj.items()
                if key
                != "expected_revision"
            }


        updated = update_settings(
            patch,
            updated_by="panel-api",
            expected_revision=
                expected_revision,
        )


        return web.json_response(
            {
                "ok": True,

                "settings":
                    updated,

                "status":
                    get_settings_status(),
            },
            headers=_json_headers(),
        )


    except SettingsRevisionConflictError as exc:

        return _error_response(
            str(
                exc
            ),
            status=409,
            code="settings_revision_conflict",
            extra={
                "status":
                    get_settings_status(),
            },
        )


    except SettingsFeatureNotWiredError as exc:

        return _error_response(
            str(
                exc
            ),
            status=409,
            code="feature_not_wired",
            extra={
                "feature_contracts":
                    get_feature_runtime_contracts(),
            },
        )


    except SettingsCorruptError as exc:

        return _error_response(
            str(
                exc
            ),
            status=503,
            code="settings_store_blocked",
            extra={
                "status":
                    get_settings_status(),
            },
        )


    except (
        ValueError,
        json.JSONDecodeError,
    ) as exc:

        return _error_response(
            str(
                exc
            ),
            status=400,
            code="invalid_settings_request",
        )


# ============================================================
# FORM — CAS
# ============================================================

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
            str(
                value
            ).strip()
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
            str(
                value
            ).strip()
        )


    try:

        expected_revision = (
            _parse_revision(
                data.get(
                    "expected_revision"
                )
            )
        )


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
            expected_revision=
                expected_revision,
        )


    except SettingsRevisionConflictError:

        raise HTTPFound(
            "/settings?"
            "error="
            "تنظیمات در یک درخواست دیگر تغییر کرده است؛ "
            "صفحه را دوباره بارگذاری کنید."
        )


    except SettingsFeatureNotWiredError as exc:

        raise HTTPFound(
            "/settings?error="
            + str(
                exc
            )
        )


    except SettingsCorruptError:

        raise HTTPFound(
            "/settings?"
            "error="
            "Settings Store در وضعیت Blocked قرار دارد."
        )


    except Exception as exc:

        raise HTTPFound(
            "/settings?error="
            + str(
                exc
            )
        )


    raise HTTPFound(
        "/settings?saved=1"
    )


# ============================================================
# HTML HELPERS
# ============================================================

def _state_badge(
    state: str,
) -> str:

    state = str(
        state
    )


    if state == "wired":

        return (
            '<span style="'
            'display:inline-block;'
            'padding:4px 9px;'
            'border-radius:999px;'
            'background:#dcfce7;'
            'color:#166534;'
            'font-size:12px;'
            'font-weight:700">'
            'WIRED'
            '</span>'
        )


    if state == "implemented":

        return (
            '<span style="'
            'display:inline-block;'
            'padding:4px 9px;'
            'border-radius:999px;'
            'background:#dbeafe;'
            'color:#1d4ed8;'
            'font-size:12px;'
            'font-weight:700">'
            'IMPLEMENTED'
            '</span>'
        )


    return (
        '<span style="'
        'display:inline-block;'
        'padding:4px 9px;'
        'border-radius:999px;'
        'background:#f1f5f9;'
        'color:#475569;'
        'font-size:12px;'
        'font-weight:700">'
        'SCAFFOLD'
        '</span>'
    )


def _feature_rows(
    feature_contracts: dict,
) -> str:

    rows = []


    for key in sorted(
        feature_contracts
    ):

        contract = (
            feature_contracts[
                key
            ]
        )


        state = str(
            contract.get(
                "state",
                "scaffold",
            )
        )


        reason = str(
            contract.get(
                "reason",
                "",
            )
        )


        rows.append(
            f"""
<tr>
<td dir="ltr">
{_esc(key)}
</td>
<td>
{_state_badge(state)}
</td>
<td style="color:#64748b">
{_esc(reason)}
</td>
</tr>
"""
        )


    return "".join(
        rows
    )


# ============================================================
# PAGE
# ============================================================

async def settings_page(
    request,
):

    try:

        settings = get_settings()

        status = get_settings_status()


    except SettingsCorruptError as exc:

        content = f"""
<div class="card">

<h2>
⚠️ Central Settings Blocked
</h2>

<div class="notice error">
{_esc(exc)}
</div>

<p>
Settings Store به دلیل تشخیص corruption در حالت Fail-Closed قرار گرفته است.
تا Recovery معتبر انجام نشود، ذخیره تنظیمات مجاز نیست.
</p>

<a
 class="button secondary"
 href="/"
>
بازگشت به Dashboard
</a>

</div>
"""

        return page(
            "Central Settings — Blocked",
            content,
        )


    feature_contracts = (
        get_feature_runtime_contracts()
    )

    setting_contracts = (
        get_setting_runtime_contracts()
    )


    revision = int(
        status[
            "revision"
        ]
    )


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
تنظیمات با موفقیت و با کنترل Revision ذخیره شد.
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


    feature_rows = (
        _feature_rows(
            feature_contracts
        )
    )


    wired_count = sum(
        1
        for item
        in feature_contracts.values()
        if item.get(
            "state"
        )
        == "wired"
    )


    scaffold_count = sum(
        1
        for item
        in feature_contracts.values()
        if item.get(
            "state"
        )
        == "scaffold"
    )


    setting_wired_count = sum(
        1
        for item
        in setting_contracts.values()
        if item.get(
            "state"
        )
        == "wired"
    )


    content = f"""
{notice}

<div class="card">

<h2>
⚙️ Settings Foundation V2
</h2>

<p style="color:#64748b;line-height:1.9">
Central Settings اکنون Source of Truth رسمی پروژه است.
ذخیره تنظیمات با Revision/CAS انجام می‌شود و قابلیت‌هایی
که Runtime آنها هنوز متصل نشده است با وضعیت SCAFFOLD
نمایش داده می‌شوند.
</p>


<div class="grid">

<div class="stat">
<strong>
Schema {status["schema_version"]}
</strong>
Schema Version
</div>


<div class="stat">
<strong>
Revision {revision}
</strong>
Revision فعلی
</div>


<div class="stat">
<strong>
{status["history_count"]}
</strong>
History
</div>


<div class="stat">
<strong style="font-size:12px;word-break:break-all">
{_esc(status["checksum"][:16])}…
</strong>
Checksum
</div>


<div class="stat">
<strong>
{wired_count}
</strong>
Featureهای Wired
</div>


<div class="stat">
<strong>
{scaffold_count}
</strong>
Featureهای Scaffold
</div>


<div class="stat">
<strong>
{setting_wired_count}
</strong>
Settingهای Runtime Wired
</div>


<div class="stat">

<strong>
{
    "BLOCKED"
    if status["blocked"]
    else "READY"
}
</strong>

Settings Store

</div>

</div>

</div>


<div class="card">

<h2>
🧩 Runtime Capability Map
</h2>

<p style="color:#64748b;line-height:1.9">
WIRED یعنی Runtime واقعاً Central Settings را مصرف می‌کند.
SCAFFOLD یعنی قرارداد تنظیمات آماده است اما موتور مربوطه
هنوز نباید از پنل فعال شود.
</p>


<div style="overflow:auto">

<table>

<thead>
<tr>
<th>Feature</th>
<th>Status</th>
<th>Runtime Contract</th>
</tr>
</thead>

<tbody>

{feature_rows}

</tbody>

</table>

</div>

</div>


<form
 method="post"
 action="/settings/save"
>


<input
 type="hidden"
 name="expected_revision"
 value="{revision}"
>


<div class="card">

<h2>
🧠 Source Intelligence
{_state_badge(
    feature_contracts[
        "source_intelligence"
    ][
        "state"
    ]
)}
</h2>

<label>
پنجره Source بدون کانفیگ سالم
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
بر حسب ساعت. ذخیره مقدار مجاز است؛
فعال‌سازی موتور Source Intelligence تا زمان Wired شدن انجام نمی‌شود.
</small>

</div>


<div class="card">

<h2>
❤️ Health Retest
{_state_badge(
    feature_contracts[
        "health_retest"
    ][
        "state"
    ]
)}
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
بر حسب دقیقه. این بخش Runtime Wired است.
</small>

</div>


<div class="card">

<h2>
⏳ Config Lifetime
{_state_badge(
    feature_contracts[
        "config_lifetime"
    ][
        "state"
    ]
)}
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
بر حسب ساعت. موتور Lifetime هنوز Scaffold است.
</small>

</div>


<div class="card">

<h2>
🌍 Country / Remark
{_state_badge(
    feature_contracts[
        "country_remark"
    ][
        "state"
    ]
)}
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
📡 Subscription / Publish
{_state_badge(
    feature_contracts[
        "publish_country_routes"
    ][
        "state"
    ]
)}
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
🧹 Cleanup / Retention
{_state_badge(
    feature_contracts[
        "retention_manager"
    ][
        "state"
    ]
)}
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
بر حسب روز. Retention Manager هنوز Scaffold است.
</small>

</div>


<div class="card">

<h2>
🖥 Resource Thresholds
{_state_badge(
    feature_contracts[
        "resource_guardian"
    ][
        "state"
    ]
)}
</h2>


<div class="grid">

<div>

<label>
CPU Warning %
</label>

<input
 type="number"
 step="0.1"
 name="cpu_warning"
 value="{resources["cpu_warning_percent"]}"
>

</div>


<div>

<label>
CPU Critical %
</label>

<input
 type="number"
 step="0.1"
 name="cpu_critical"
 value="{resources["cpu_critical_percent"]}"
>

</div>


<div>

<label>
RAM Warning %
</label>

<input
 type="number"
 step="0.1"
 name="ram_warning"
 value="{resources["ram_warning_percent"]}"
>

</div>


<div>

<label>
RAM Critical %
</label>

<input
 type="number"
 step="0.1"
 name="ram_critical"
 value="{resources["ram_critical_percent"]}"
>

</div>


<div>

<label>
Disk Warning %
</label>

<input
 type="number"
 step="0.1"
 name="disk_warning"
 value="{resources["disk_warning_percent"]}"
>

</div>


<div>

<label>
Disk Critical %
</label>

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
🔐 Concurrency Protection
</h2>

<p style="line-height:1.9;color:#64748b">

این فرم با Revision

<strong>
{revision}
</strong>

بارگذاری شده است.

اگر قبل از ذخیره، درخواست دیگری Settings را تغییر دهد،
CAS اجازه overwrite کردن تغییر جدید را نمی‌دهد و باید صفحه
دوباره بارگذاری شود.

</p>

</div>


<div class="card">

<h2>
🗄 Settings Store
</h2>

<table>

<tbody>

<tr>
<td>Source of Truth</td>
<td>
<strong>
{_esc(status["source_of_truth"])}
</strong>
</td>
</tr>

<tr>
<td>Legacy Config</td>
<td>
{_esc(status["legacy_inputs"])}
</td>
</tr>

<tr>
<td>History Limit</td>
<td>
{_esc(status["history_limit"])}
</td>
</tr>

<tr>
<td>Blocked</td>
<td>
{_esc(status["blocked"])}
</td>
</tr>

<tr>
<td>Valid</td>
<td>
{_esc(status["valid"])}
</td>
</tr>

</tbody>

</table>

</div>
"""


    return page(
        "Central Settings",
        content,
    )


# ============================================================
# ROUTES
# ============================================================

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


    app.router.add_get(
        "/api/settings/status",
        api_settings_status,
    )


    app.router.add_get(
        "/api/settings/capabilities",
        api_settings_capabilities,
    )


    app.router.add_get(
        "/api/settings/history/preview",
        api_settings_history_preview,
    )


    app[
        marker
    ] = True
