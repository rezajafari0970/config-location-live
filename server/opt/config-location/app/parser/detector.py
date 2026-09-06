from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import re

from typing import Any
from urllib.parse import urlsplit


# ============================================================
# KNOWN URI PROTOCOLS
# ============================================================

KNOWN_SCHEMES = {
    "vless": "vless",
    "vmess": "vmess",
    "trojan": "trojan",

    "ss": "ss",
    "ssr": "ssr",

    "socks": "socks",
    "socks5": "socks5",

    "hysteria": "hysteria",
    "hysteria2": "hy2",
    "hy2": "hy2",

    "tuic": "tuic",

    "wireguard": "wireguard",
    "wg": "wireguard",

    "npv": "napsternet",
    "npvt": "napsternet",
    "nps": "napsternet",
    "napsternet": "napsternet",
}


URI_RE = re.compile(
    r'(?P<uri>[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"\']+)',
    re.I,
)


# ============================================================
# OBVIOUS NON-CONFIG OUTPUT
# ============================================================

HTML_MARKERS = (
    "<!doctype html",
    "<html",
    "<head",
    "<body",
    "<script",
    "<title>",
)

ERROR_PHRASES = (
    "404 not found",
    "403 forbidden",
    "502 bad gateway",
    "503 service unavailable",
    "504 gateway timeout",
    "access denied",
    "cloudflare ray id",
    "just a moment...",
    "database connection error",
    "fatal error:",
    "warning:",
    "notice:",
)


# ============================================================
# HELPERS
# ============================================================

def _clean(value: str) -> str:
    return (
        value
        .replace("\x00", "")
        .replace("\ufeff", "")
        .strip()
    )


def _compact_json(obj: Any) -> str:
    return json.dumps(
        obj,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=False,
    )


def _fingerprint(
    kind: str,
    canonical: str,
):
    return hashlib.sha256(
        (
            kind
            + "\0"
            + canonical
        ).encode(
            "utf-8",
            errors="ignore",
        )
    ).hexdigest()


def make_item(
    kind: str,
    raw: str,
    canonical: str | None = None,
    confidence: int = 100,
    preserve_raw: bool = True,
):
    if canonical is None:
        canonical = raw

    return {
        "type": kind,
        "raw": raw,
        "canonical": canonical,
        "fingerprint": _fingerprint(
            kind,
            canonical,
        ),
        "confidence": confidence,
        "preserve_raw": preserve_raw,
        "detector_version": "2.2",
    }


def b64decode_loose(
    value: str
):
    value = "".join(
        value.split()
    )

    if not value:
        return None

    try:
        value += "=" * (
            -len(value) % 4
        )

        return base64.urlsafe_b64decode(
            value.encode()
        )

    except Exception:
        try:
            return base64.b64decode(
                value.encode()
            )
        except Exception:
            return None


def obvious_non_config(
    text: str
):
    stripped = _clean(text)

    if not stripped:
        return True

    low = stripped[
        :3000
    ].lower()

    if any(
        marker in low
        for marker in HTML_MARKERS
    ):
        return True

    # Only reject error text when it has no
    # recognizable config indicators.
    has_config_signal = any(
        marker in low
        for marker in (
            "://",
            "\"outbounds\"",
            "\"inbounds\"",
            "[interface]",
            "[peer]",
            "privatekey",
            "publickey",
        )
    )

    if (
        not has_config_signal
        and any(
            phrase in low
            for phrase in ERROR_PHRASES
        )
    ):
        return True

    return False


# ============================================================
# URI VALIDATION
# ============================================================

def host_port_ok(
    uri: str
):
    try:
        parsed = urlsplit(
            uri
        )

        if not parsed.hostname:
            return False

        port = parsed.port

        if port is None:
            return False

        return (
            1 <= int(port) <= 65535
        )

    except Exception:
        return False


def valid_vmess(
    uri: str
):
    if not uri.lower().startswith(
        "vmess://"
    ):
        return None

    encoded = uri[
        len("vmess://"):
    ].strip()

    raw = b64decode_loose(
        encoded
    )

    if not raw:
        return None

    try:
        obj = json.loads(
            raw.decode(
                "utf-8",
                errors="strict",
            )
        )
    except Exception:
        return None

    if not isinstance(
        obj,
        dict
    ):
        return None

    # VMess variants are not always identical.
    # Require only the essential identity fields.
    address = (
        obj.get("add")
        or obj.get("address")
        or obj.get("server")
    )

    port = (
        obj.get("port")
        or obj.get("server_port")
    )

    user = (
        obj.get("id")
        or obj.get("uuid")
    )

    if not (
        address
        and port
        and user
    ):
        return None

    return obj


def detect_uri(
    uri: str
):
    uri = (
        uri.strip()
        .rstrip(
            ".,;)]}>،؛"
        )
    )

    if "://" not in uri:
        return None

    scheme = (
        uri.split(
            "://",
            1
        )[0]
        .lower()
    )

    # HTTP URLs are source URLs, not configs.
    if scheme in {
        "http",
        "https",
        "ftp",
        "file",
    }:
        return None

    kind = KNOWN_SCHEMES.get(
        scheme
    )

    if kind == "vmess":
        obj = valid_vmess(
            uri
        )

        if not obj:
            return None

        canonical_obj = dict(
            obj
        )

        # Display label must not affect dedup.
        canonical_obj.pop(
            "ps",
            None
        )

        return make_item(
            "vmess",
            uri,
            _compact_json(
                canonical_obj
            ),
        )

    if kind in {
        "vless",
        "trojan",
        "tuic",
    }:
        if not host_port_ok(
            uri
        ):
            return None

        return make_item(
            kind,
            uri,
            uri.split(
                "#",
                1
            )[0],
        )

    if kind in {
        "hysteria",
        "hy2",
        "ss",
        "ssr",
        "socks",
        "socks5",
        "wireguard",
        "napsternet",
    }:
        if len(uri) < 8:
            return None

        return make_item(
            kind,
            uri,
            uri.split(
                "#",
                1
            )[0],
        )

    # ========================================================
    # CUSTOM URI
    # ========================================================
    #
    # Important:
    # Unknown schemes are accepted.
    # Raw content is preserved completely.
    #
    # Examples:
    #
    # custom://...
    # ssh://...
    # sshws://...
    # darkvpn://...
    # proprietary://...
    #
    # ========================================================

    if (
        re.fullmatch(
            r'[A-Za-z][A-Za-z0-9+.-]*',
            scheme
        )
        and len(uri) >= 8
    ):
        return make_item(
            "custom_uri",
            uri,
            uri,
            confidence=90,
            preserve_raw=True,
        )

    return None


# ============================================================
# WIREGUARD
# ============================================================

def detect_wireguard_text(
    text: str
):
    stripped = _clean(
        text
    )

    low = stripped.lower()

    if (
        "[interface]" not in low
        or "[peer]" not in low
    ):
        return []

    signals = 0

    for token in (
        "privatekey",
        "publickey",
        "endpoint",
        "address",
        "allowedips",
        "dns",
        "listenport",
        "presharedkey",
    ):
        if token in low:
            signals += 1

    if signals < 3:
        return []

    return [
        make_item(
            "wireguard_native",
            stripped,
            stripped,
            confidence=100,
            preserve_raw=True,
        )
    ]


# ============================================================
# JSON CLASSIFICATION
# ============================================================

def json_type(
    obj: Any
):
    if not isinstance(
        obj,
        dict
    ):
        return None

    keys = {
        str(k).lower()
        for k in obj.keys()
    }

    # --------------------------------------------------------
    # Xray / V2Ray full config
    # --------------------------------------------------------

    if (
        "outbounds" in keys
        or "inbounds" in keys
    ):
        return "json_xray"

    if (
        "routing" in keys
        and (
            "dns" in keys
            or "policy" in keys
        )
    ):
        return "json_xray"

    # --------------------------------------------------------
    # Sing-box
    # --------------------------------------------------------

    if (
        "route" in keys
        and "outbounds" in keys
    ):
        return "json_singbox"

    # --------------------------------------------------------
    # WireGuard JSON
    # --------------------------------------------------------

    wg_signals = {
        "privatekey",
        "private_key",
        "publickey",
        "public_key",
        "allowedips",
        "allowed_ips",
        "endpoint",
    }

    if len(
        keys & wg_signals
    ) >= 2:
        return "json_wireguard"

    # --------------------------------------------------------
    # VMess JSON
    # --------------------------------------------------------

    if (
        (
            "add" in keys
            or "address" in keys
            or "server" in keys
        )
        and
        (
            "id" in keys
            or "uuid" in keys
        )
        and
        "port" in keys
    ):
        return "json_vmess"

    # --------------------------------------------------------
    # Generic structured proxy/custom JSON
    # --------------------------------------------------------

    config_signals = {
        "server",
        "server_port",
        "address",
        "host",
        "hostname",
        "port",

        "protocol",
        "type",
        "network",

        "uuid",
        "id",
        "password",
        "passwd",
        "method",

        "security",
        "tls",
        "reality",
        "sni",

        "path",
        "service_name",

        "privatekey",
        "private_key",
        "publickey",
        "public_key",

        "proxy",
        "config",
        "configuration",
    }

    score = len(
        keys & config_signals
    )

    if score >= 2:
        return "json_custom"

    return None


def walk_json_for_embedded(
    value: Any,
    depth: int = 0,
):
    if depth > 8:
        return []

    results = []

    if isinstance(
        value,
        str
    ):
        results.extend(
            extract_configs(
                value,
                depth=depth + 1,
            )
        )

    elif isinstance(
        value,
        list
    ):
        for child in value:
            results.extend(
                walk_json_for_embedded(
                    child,
                    depth + 1,
                )
            )

    elif isinstance(
        value,
        dict
    ):
        for child in value.values():
            results.extend(
                walk_json_for_embedded(
                    child,
                    depth + 1,
                )
            )

    return results


def detect_json(
    text: str
):
    stripped = _clean(
        text
    )

    try:
        obj = json.loads(
            stripped
        )
    except Exception:
        return []

    results = []

    # A complete JSON config.
    kind = json_type(
        obj
    )

    if kind:
        raw = _compact_json(
            obj
        )

        results.append(
            make_item(
                kind,
                raw,
                raw,
                confidence=100,
                preserve_raw=True,
            )
        )

    # Arrays/wrappers may contain configs.
    results.extend(
        walk_json_for_embedded(
            obj
        )
    )

    # --------------------------------------------------------
    # Controlled-source fallback
    # --------------------------------------------------------
    #
    # If JSON itself wasn't recognized but still contains
    # configuration-like words, preserve it as custom JSON.
    #
    # Ordinary API metadata is not automatically accepted.
    #
    # --------------------------------------------------------

    if (
        not kind
        and isinstance(
            obj,
            dict
        )
    ):
        serialized = stripped.lower()

        signals = sum(
            1
            for token in (
                "server",
                "host",
                "port",
                "proxy",
                "config",
                "uuid",
                "password",
                "protocol",
                "privatekey",
                "publickey",
                "endpoint",
                "outbound",
                "inbound",
                "sni",
                "tls",
            )
            if token in serialized
        )

        if signals >= 2:
            raw = _compact_json(
                obj
            )

            results.append(
                make_item(
                    "json_custom",
                    raw,
                    raw,
                    confidence=85,
                    preserve_raw=True,
                )
            )

    return results


# ============================================================
# CUSTOM TEXT
# ============================================================

HOST_PORT_RE = re.compile(
    r'''
    (?:
        \[[0-9A-Fa-f:]+\]
        |
        [A-Za-z0-9._-]+
    )
    :
    [0-9]{1,5}
    ''',
    re.X,
)


def config_like_text(
    text: str
):
    stripped = _clean(
        text
    )

    if len(stripped) < 12:
        return False

    low = stripped.lower()

    signals = 0

    # host:port
    if HOST_PORT_RE.search(
        stripped
    ):
        signals += 2

    for token in (
        "server=",
        "server:",
        "host=",
        "host:",
        "port=",
        "port:",
        "uuid=",
        "uuid:",
        "password=",
        "password:",
        "proxy=",
        "proxy:",
        "sni=",
        "sni:",
        "tls=",
        "network=",
        "privatekey",
        "publickey",
        "endpoint",
        "allowedips",
    ):
        if token in low:
            signals += 1

    return signals >= 3


# ============================================================
# BASE64
# ============================================================

def looks_base64(
    text: str
):
    compact = "".join(
        text.split()
    )

    if not (
        16 <= len(
            compact
        ) <= 10_000_000
    ):
        return False

    return bool(
        re.fullmatch(
            r'[A-Za-z0-9+/=_-]+',
            compact
        )
    )


# ============================================================
# MAIN EXTRACTOR
# ============================================================

def extract_configs(
    text: str,
    depth: int = 0,
):
    if not isinstance(
        text,
        str
    ):
        return []

    if depth > 4:
        return []

    text = _clean(
        text
    )

    if not text:
        return []

    if obvious_non_config(
        text
    ):
        return []

    results = []

    # --------------------------------------------------------
    # JSON
    # --------------------------------------------------------

    if (
        text.startswith("{")
        or text.startswith("[")
    ):
        results.extend(
            detect_json(
                text
            )
        )

    # --------------------------------------------------------
    # WireGuard native
    # --------------------------------------------------------

    results.extend(
        detect_wireguard_text(
            text
        )
    )

    # --------------------------------------------------------
    # URI configs
    # --------------------------------------------------------

    for match in URI_RE.finditer(
        text
    ):
        item = detect_uri(
            match.group(
                "uri"
            )
        )

        if item:
            results.append(
                item
            )

    # --------------------------------------------------------
    # Base64 subscription
    # --------------------------------------------------------

    if (
        depth < 4
        and looks_base64(
            text
        )
    ):
        raw = b64decode_loose(
            text
        )

        if raw:
            try:
                decoded = raw.decode(
                    "utf-8"
                )

                if (
                    decoded.strip()
                    and decoded.strip()
                    != text
                ):
                    results.extend(
                        extract_configs(
                            decoded,
                            depth + 1,
                        )
                    )

            except Exception:
                pass

    # --------------------------------------------------------
    # Custom text fallback
    # --------------------------------------------------------

    #
    # This is intentionally permissive because the source list
    # is controlled by the administrator.
    #
    # It still requires multiple config-related signals.
    #

    if (
        not results
        and config_like_text(
            text
        )
    ):
        results.append(
            make_item(
                "custom_text",
                text,
                text,
                confidence=80,
                preserve_raw=True,
            )
        )

    # --------------------------------------------------------
    # Deduplicate response
    # --------------------------------------------------------

    unique = {}

    for item in results:
        fp = item.get(
            "fingerprint"
        )

        if fp:
            unique[
                fp
            ] = item

    return list(
        unique.values()
    )


# ============================================================
# CONFIG_LOCATION_EXACT_BULK_V4_BEGIN
# ============================================================
#
# اهداف V4:
#
# 1) تمام URI Configها به صورت مستقل استخراج شوند.
# 2) تمام JSON Configهای واقعی به صورت مستقل استخراج شوند.
# 3) URI و JSON به یکدیگر نچسبند.
# 4) Raw دقیقاً همان چیزی باشد که Source تحویل داده.
# 5) JSON parse/rebuild نشود.
# 6) fingerprint براساس RAW دقیق باشد.
# 7) فقط RAW کاملاً یکسان Duplicate محسوب شود.
# 8) URIهای داخل JSON دوباره به عنوان Config مستقل استخراج نشوند.
# 9) Legacy detector برای Custom / Native / موارد قدیمی حفظ شود.
#
# ============================================================

import hashlib as _cl_hashlib
import json as _cl_json
import re as _cl_re


_cl_legacy_extract_configs = extract_configs


# ------------------------------------------------------------
# CONFIG URI SCHEMES
# ------------------------------------------------------------

_CL_CONFIG_SCHEMES = {
    "vless",
    "vmess",
    "trojan",

    "ss",
    "ssr",

    "hysteria",
    "hysteria2",
    "hy",
    "hy2",

    "tuic",

    "wireguard",
    "wg",

    "socks",
    "socks5",

    "npv",
    "npvt",
    "nps",
    "napsternet",
}


_CL_SCHEME_CANONICAL = {
    "vless": "vless",
    "vmess": "vmess",
    "trojan": "trojan",

    "ss": "ss",
    "ssr": "ssr",

    "hysteria": "hysteria",
    "hysteria2": "hy2",
    "hy": "hysteria",
    "hy2": "hy2",

    "tuic": "tuic",

    "wireguard": "wireguard",
    "wg": "wireguard",

    "socks": "socks",
    "socks5": "socks5",

    "npv": "napsternet",
    "npvt": "napsternet",
    "nps": "napsternet",
    "napsternet": "napsternet",
}


_CL_URI_START_RE = _cl_re.compile(
    r"""(?ix)
    (?P<scheme>
        vless
        |
        vmess
        |
        trojan
        |
        ssr
        |
        ss
        |
        hysteria2
        |
        hysteria
        |
        hy2
        |
        hy
        |
        tuic
        |
        wireguard
        |
        wg
        |
        socks5
        |
        socks
        |
        napsternet
        |
        npvt
        |
        npv
        |
        nps
    )
    ://
    """
)


def _cl_sha256_raw(raw):
    if not isinstance(raw, str):
        raw = str(raw)

    return _cl_hashlib.sha256(
        raw.encode(
            "utf-8",
            errors="surrogatepass",
        )
    ).hexdigest()


# ------------------------------------------------------------
# JSON CLASSIFICATION
# ------------------------------------------------------------

def _cl_json_kind(obj):
    """
    فقط JSONهایی را Exact Config حساب می‌کنیم که
    نشانه کافی برای Config واقعی داشته باشند.
    """

    if not isinstance(obj, dict):
        return None

    keys = {
        str(k).lower()
        for k in obj.keys()
    }

    # Xray / V2Ray
    if (
        "outbounds" in keys
        or "inbounds" in keys
    ):
        return "json_xray"

    if (
        "routing" in keys
        and (
            "dns" in keys
            or "policy" in keys
        )
    ):
        return "json_xray"

    # Sing-box
    if (
        "route" in keys
        and "outbounds" in keys
    ):
        return "json_singbox"

    # WireGuard JSON
    wg = {
        "privatekey",
        "private_key",
        "publickey",
        "public_key",
        "allowedips",
        "allowed_ips",
        "endpoint",
    }

    if len(keys & wg) >= 2:
        return "json_wireguard"

    # VMess style JSON
    if (
        (
            "add" in keys
            or "address" in keys
            or "server" in keys
        )
        and
        (
            "id" in keys
            or "uuid" in keys
        )
        and
        (
            "port" in keys
            or "server_port" in keys
        )
    ):
        return "json_vmess"

    # Custom structured proxy JSON
    signals = {
        "server",
        "server_port",
        "address",
        "host",
        "hostname",
        "port",

        "protocol",
        "network",

        "uuid",
        "id",
        "password",
        "passwd",
        "method",

        "security",
        "tls",
        "reality",
        "sni",

        "path",
        "service_name",

        "privatekey",
        "private_key",
        "publickey",
        "public_key",

        "proxy",
        "config",
        "configuration",
    }

    score = len(keys & signals)

    if score >= 3:
        return "json_custom"

    return None


# ------------------------------------------------------------
# EXACT JSON SCANNER
# ------------------------------------------------------------

def _cl_json_start_boundary(text, pos):
    """
    جلوگیری از اینکه { داخل URI یا متن معمولی
    به اشتباه JSON مستقل تشخیص داده شود.
    """

    if pos <= 0:
        return True

    prev = text[pos - 1]

    if prev.isspace():
        return True

    return prev in (
        "[",
        ",",
        ";",
        "=",
        ":",
        "(",
    )


def _cl_exact_json_spans(text):
    """
    تمام JSON Configهای واقعی را با Span دقیق پیدا می‌کند.

    نکته مهم:
    RAW از خود متن Source بریده می‌شود.
    json.dumps یا rebuild انجام نمی‌شود.
    """

    if not isinstance(text, str):
        return []

    decoder = _cl_json.JSONDecoder()

    results = []
    occupied = []

    n = len(text)

    pos = 0

    while pos < n:

        ch = text[pos]

        if ch != "{":
            pos += 1
            continue

        if not _cl_json_start_boundary(
            text,
            pos,
        ):
            pos += 1
            continue

        # اگر داخل JSON قبلی هستیم، دوباره Scan نکن.
        inside_existing = False

        for a, b in occupied:
            if a <= pos < b:
                inside_existing = True
                break

        if inside_existing:
            pos += 1
            continue

        try:
            obj, consumed = decoder.raw_decode(
                text[pos:]
            )
        except Exception:
            pos += 1
            continue

        if consumed <= 1:
            pos += 1
            continue

        end = pos + consumed

        kind = _cl_json_kind(
            obj
        )

        if not kind:
            pos += 1
            continue

        raw = text[
            pos:end
        ]

        item = {
            "type": kind,
            "raw": raw,
            "canonical": raw,
            "fingerprint": _cl_sha256_raw(
                raw
            ),
            "confidence": 100,
            "preserve_raw": True,
            "detector_version": "4.0",
            "_cl_start": pos,
            "_cl_end": end,
        }

        results.append(
            item
        )

        occupied.append(
            (
                pos,
                end,
            )
        )

        pos = end

    return results


def _cl_pos_inside_json(
    pos,
    json_items,
):
    for item in json_items:
        a = item.get(
            "_cl_start"
        )

        b = item.get(
            "_cl_end"
        )

        if (
            isinstance(a, int)
            and isinstance(b, int)
            and a <= pos < b
        ):
            return True

    return False


# ------------------------------------------------------------
# EXACT URI SCANNER
# ------------------------------------------------------------

def _cl_exact_uri_items(
    text,
    json_items=None,
):
    """
    URIها را مستقل استخراج می‌کند.

    انتهای URI:
      - URI بعدی
      - JSON واقعی بعدی
      - پایان متن

    URIهایی که داخل JSON هستند نادیده گرفته می‌شوند.
    """

    if not isinstance(text, str):
        return []

    if json_items is None:
        json_items = []

    matches = []

    for match in _CL_URI_START_RE.finditer(
        text
    ):
        start = match.start(
            "scheme"
        )

        if _cl_pos_inside_json(
            start,
            json_items,
        ):
            continue

        scheme = (
            match.group(
                "scheme"
            )
            .lower()
        )

        if scheme not in _CL_CONFIG_SCHEMES:
            continue

        matches.append(
            (
                start,
                scheme,
            )
        )

    if not matches:
        return []

    boundaries = {
        len(text)
    }

    for start, _ in matches:
        boundaries.add(
            start
        )

    for item in json_items:
        jstart = item.get(
            "_cl_start"
        )

        if isinstance(
            jstart,
            int
        ):
            boundaries.add(
                jstart
            )

    sorted_boundaries = sorted(
        boundaries
    )

    output = []

    for start, scheme in matches:

        end = len(text)

        for boundary in sorted_boundaries:
            if boundary > start:
                end = boundary
                break

        raw = text[
            start:end
        ]

        # فقط whitespace جداکننده بین Configها حذف می‌شود.
        raw = raw.rstrip(
            " \t\r\n"
        )

        if not raw:
            continue

        output.append(
            {
                "type": _CL_SCHEME_CANONICAL.get(
                    scheme,
                    scheme,
                ),
                "raw": raw,
                "canonical": raw,
                "fingerprint": _cl_sha256_raw(
                    raw
                ),
                "confidence": 100,
                "preserve_raw": True,
                "detector_version": "4.0",
                "_cl_start": start,
                "_cl_end": end,
            }
        )

    return output


# ------------------------------------------------------------
# REAL WIREGUARD NATIVE
# ------------------------------------------------------------

def _cl_is_real_wireguard_native(raw):

    if not isinstance(
        raw,
        str
    ):
        return False

    low = raw.lower()

    if _CL_URI_START_RE.search(
        raw
    ):
        return False

    return (
        "[interface]" in low
        and
        "[peer]" in low
        and
        "privatekey" in low
        and
        "publickey" in low
    )


# ------------------------------------------------------------
# LEGACY CLEANER
# ------------------------------------------------------------

def _cl_clean_legacy_items(
    items,
):
    output = []

    if not isinstance(
        items,
        list
    ):
        return output

    for item in items:

        if not isinstance(
            item,
            dict
        ):
            continue

        item = dict(
            item
        )

        raw = item.get(
            "raw"
        )

        if not isinstance(
            raw,
            str
        ):
            output.append(
                item
            )
            continue

        item_type = str(
            item.get(
                "type",
                ""
            )
        ).lower()

        # Legacy multi URI chunk نباید Store شود.
        uri_count = len(
            list(
                _CL_URI_START_RE.finditer(
                    raw
                )
            )
        )

        if uri_count > 1:
            continue

        # WireGuard Native false positive
        if item_type in {
            "wireguard_native",
            "wireguard-native",
        }:
            if not _cl_is_real_wireguard_native(
                raw
            ):
                continue

        item["fingerprint"] = \
            _cl_sha256_raw(
                raw
            )

        output.append(
            item
        )

    return output


# ------------------------------------------------------------
# REMOVE PRIVATE SCAN METADATA
# ------------------------------------------------------------

def _cl_finalize_item(
    item,
):
    item = dict(
        item
    )

    item.pop(
        "_cl_start",
        None,
    )

    item.pop(
        "_cl_end",
        None,
    )

    raw = item.get(
        "raw"
    )

    if isinstance(
        raw,
        str
    ):
        item["fingerprint"] = \
            _cl_sha256_raw(
                raw
            )

    return item


# ------------------------------------------------------------
# MAIN V4 WRAPPER
# ------------------------------------------------------------

def extract_configs(text):
    """
    Exact Bulk V4

                  SOURCE BODY
                       |
                 JSON scanner
                       |
                  URI scanner
                       |
                Legacy detector
                       |
                   merge
                       |
                RAW exact dedupe
                       |
                     Store
    """

    if not isinstance(
        text,
        str
    ):
        return []

    # --------------------------------------------------------
    # Exact JSON first
    # --------------------------------------------------------

    json_items = \
        _cl_exact_json_spans(
            text
        )

    # --------------------------------------------------------
    # Exact URI
    # --------------------------------------------------------

    uri_items = \
        _cl_exact_uri_items(
            text,
            json_items=json_items,
        )

    # --------------------------------------------------------
    # Legacy
    # --------------------------------------------------------

    legacy = []

    try:
        legacy = \
            _cl_legacy_extract_configs(
                text
            )
    except Exception:
        legacy = []

    legacy = \
        _cl_clean_legacy_items(
            legacy
        )

    # --------------------------------------------------------
    # Exact RAW merge
    # --------------------------------------------------------

    output = []
    seen_raw = set()

    # URI و JSON Exact اولویت دارند.
    for group in (
        uri_items,
        json_items,
        legacy,
    ):

        for item in group:

            if not isinstance(
                item,
                dict
            ):
                continue

            raw = item.get(
                "raw"
            )

            if not isinstance(
                raw,
                str
            ):
                continue

            if not raw:
                continue

            key = _cl_sha256_raw(
                raw
            )

            # فقط RAW کاملاً یکسان Duplicate است.
            if key in seen_raw:
                continue

            seen_raw.add(
                key
            )

            item["fingerprint"] = key

            output.append(
                _cl_finalize_item(
                    item
                )
            )

    return output


# ============================================================
# CONFIG_LOCATION_EXACT_BULK_V4_END
# ============================================================



# ============================================================
# CONFIG_LOCATION_STRICT_NATIVE_V5
# ============================================================

import hashlib as _cl_hashlib
import json as _cl_json
import re as _cl_re


def _cl_raw_sha256_v5(raw):
    if not isinstance(raw, str):
        raw = str(raw)
    return _cl_hashlib.sha256(
        raw.encode("utf-8", errors="surrogatepass")
    ).hexdigest()


def _cl_real_wireguard_native_v5(raw):
    """
    Strict WireGuard-native recognition.

    Accepted:
      - wireguard:// URI
      - wg:// URI
      - INI-style WireGuard:
            [Interface]
            PrivateKey = ...
            Address = ...
            [Peer]
            PublicKey = ...
            Endpoint = ...

    Explicitly rejected:
      - arbitrary mixed subscription text
      - ss:// + vless:// concatenations
      - chunks merely containing words related to WireGuard
    """
    if not isinstance(raw, str):
        return False

    s = raw.strip()
    if not s:
        return False

    low = s.lower()

    if low.startswith("wireguard://") or low.startswith("wg://"):
        return True

    # Any normal proxy URI inside a supposedly native WG block makes it invalid.
    foreign = (
        "vless://",
        "vmess://",
        "trojan://",
        "ss://",
        "ssr://",
        "hysteria://",
        "hysteria2://",
        "hy2://",
        "tuic://",
        "socks://",
        "socks5://",
    )

    if any(x in low for x in foreign):
        return False

    has_interface = bool(
        _cl_re.search(
            r"(?im)^\s*\[\s*interface\s*\]\s*$",
            s,
        )
    )

    has_peer = bool(
        _cl_re.search(
            r"(?im)^\s*\[\s*peer\s*\]\s*$",
            s,
        )
    )

    has_private = bool(
        _cl_re.search(
            r"(?im)^\s*privatekey\s*=\s*\S+",
            s,
        )
    )

    has_public = bool(
        _cl_re.search(
            r"(?im)^\s*publickey\s*=\s*\S+",
            s,
        )
    )

    has_endpoint = bool(
        _cl_re.search(
            r"(?im)^\s*endpoint\s*=\s*\S+",
            s,
        )
    )

    return (
        has_interface
        and has_peer
        and has_private
        and has_public
        and has_endpoint
    )


def _cl_valid_json_raw_v5(raw):
    if not isinstance(raw, str):
        return False

    s = raw.strip()

    if not s:
        return False

    if not (
        (s.startswith("{") and s.endswith("}"))
        or
        (s.startswith("[") and s.endswith("]"))
    ):
        return False

    try:
        _cl_json.loads(s)
        return True
    except Exception:
        return False


def _cl_clean_items_v5(items):
    """
    Final protection layer before items leave detector.

    Rules:
      - exact raw SHA256 dedupe
      - reject fake wireguard_native
      - preserve RAW byte-for-byte as Python string
    """
    out = []
    seen = set()

    for item in items or []:
        if not isinstance(item, dict):
            continue

        raw = item.get("raw")

        if not isinstance(raw, str):
            continue

        if raw == "":
            continue

        typ = str(
            item.get("type")
            or item.get("kind")
            or item.get("protocol")
            or ""
        ).strip().lower()

        if typ in {
            "wireguard_native",
            "wireguard-native",
            "wg_native",
            "wg-native",
        }:
            if not _cl_real_wireguard_native_v5(raw):
                continue

        fp = _cl_raw_sha256_v5(raw)

        if fp in seen:
            continue

        seen.add(fp)

        item["fingerprint"] = fp
        out.append(item)

    return out


# Wrap the existing extract_configs() without changing its internal detector.
try:
    _cl_original_extract_configs_v5 = extract_configs
except NameError:
    _cl_original_extract_configs_v5 = None


if _cl_original_extract_configs_v5 is not None:
    def extract_configs(text):
        result = _cl_original_extract_configs_v5(text)
        return _cl_clean_items_v5(result)

# ============================================================
# CONFIG_LOCATION_STRICT_NATIVE_V5_END
# ============================================================

# ============================================================
# CONFIG_LOCATION_EXACT_BOUNDARY_V6
# ============================================================

import hashlib as _cl_v6_hashlib
import re as _cl_v6_re


_cl_extract_configs_before_v6 = extract_configs


def _cl_v6_hash(raw):
    return _cl_v6_hashlib.sha256(
        raw.encode(
            "utf-8",
            errors="surrogatepass",
        )
    ).hexdigest()


def _cl_v6_native_wireguard_blocks(text):
    """
    Extract WireGuard INI blocks exactly as one config.

    Start:
        [Interface]

    Must contain:
        [Peer]
        PrivateKey
        PublicKey

    End:
        next proxy URI
        next [Interface]
        next standalone JSON start
        EOF
    """

    if not isinstance(text, str):
        return []

    lines = text.splitlines(
        keepends=True
    )

    results = []

    offsets = []
    current = 0

    for line in lines:
        offsets.append(current)
        current += len(line)

    i = 0

    while i < len(lines):

        if (
            lines[i].strip().lower()
            != "[interface]"
        ):
            i += 1
            continue

        start_i = i
        j = i + 1
        seen_peer = False

        while j < len(lines):

            stripped = lines[j].strip()
            low = stripped.lower()

            if low == "[peer]":
                seen_peer = True
                j += 1
                continue

            if (
                low == "[interface]"
                and j > start_i
            ):
                break

            if _CL_URI_START_RE.search(
                stripped
            ):
                break

            if (
                stripped.startswith("{")
                or stripped.startswith("[")
            ):
                if low not in {
                    "[peer]",
                    "[interface]",
                }:
                    break

            j += 1

        end_i = j

        raw = "".join(
            lines[start_i:end_i]
        ).rstrip(
            "\r\n"
        )

        low_raw = raw.lower()

        if (
            seen_peer
            and "privatekey" in low_raw
            and "publickey" in low_raw
        ):

            start_pos = offsets[start_i]

            if end_i < len(offsets):
                end_pos = offsets[end_i]
            else:
                end_pos = len(text)

            results.append(
                {
                    "type": "wireguard_native",
                    "raw": raw,
                    "canonical": raw,
                    "fingerprint": _cl_v6_hash(raw),
                    "confidence": 100,
                    "preserve_raw": True,
                    "detector_version": "6.0",
                    "_cl_start": start_pos,
                    "_cl_end": end_pos,
                }
            )

        i = max(
            j,
            i + 1,
        )

    return results


def _cl_v6_inside_span(
    pos,
    spans,
):
    for a, b in spans:
        if a <= pos < b:
            return True
    return False


def _cl_v6_exact_uri_items(
    text,
    json_items=None,
    wg_items=None,
):
    """
    V6 URI extraction.

    Critical change:
    newline / CR / tab are hard URI boundaries.

    URI can also end before:
      - next URI
      - exact JSON
      - WireGuard Native
      - EOF
    """

    if not isinstance(text, str):
        return []

    json_items = json_items or []
    wg_items = wg_items or []

    occupied = []

    for item in json_items + wg_items:
        a = item.get("_cl_start")
        b = item.get("_cl_end")

        if (
            isinstance(a, int)
            and isinstance(b, int)
        ):
            occupied.append(
                (a, b)
            )

    matches = []

    for match in _CL_URI_START_RE.finditer(
        text
    ):

        start = match.start(
            "scheme"
        )

        if _cl_v6_inside_span(
            start,
            occupied,
        ):
            continue

        scheme = (
            match.group(
                "scheme"
            )
            .lower()
        )

        matches.append(
            (
                start,
                scheme,
            )
        )

    output = []

    for index, (
        start,
        scheme,
    ) in enumerate(matches):

        candidates = [
            len(text)
        ]

        # next URI
        if index + 1 < len(matches):
            candidates.append(
                matches[index + 1][0]
            )

        # JSON / WG start
        for a, _ in occupied:
            if a > start:
                candidates.append(a)

        # hard line boundaries
        for token in (
            "\n",
            "\r",
            "\t",
        ):
            p = text.find(
                token,
                start,
            )

            if p != -1:
                candidates.append(p)

        end = min(candidates)

        raw = text[
            start:end
        ].rstrip(
            " \t\r\n"
        )

        if not raw:
            continue

        typ = _CL_SCHEME_CANONICAL.get(
            scheme,
            scheme,
        )

        output.append(
            {
                "type": typ,
                "raw": raw,
                "canonical": raw,
                "fingerprint": _cl_v6_hash(
                    raw
                ),
                "confidence": 100,
                "preserve_raw": True,
                "detector_version": "6.0",
                "_cl_start": start,
                "_cl_end": end,
            }
        )

    return output


def extract_configs(text):
    """
    Exact Bulk V6:
      JSON + WireGuard Native + URI
      with strict line boundaries.
    """

    if not isinstance(text, str):
        return []

    json_items = _cl_exact_json_spans(
        text
    )

    wg_items = _cl_v6_native_wireguard_blocks(
        text
    )

    uri_items = _cl_v6_exact_uri_items(
        text,
        json_items=json_items,
        wg_items=wg_items,
    )

    legacy = []

    try:
        legacy = _cl_extract_configs_before_v6(
            text
        )
    except Exception:
        legacy = []

    output = []
    seen = set()

    for group in (
        uri_items,
        json_items,
        wg_items,
        legacy,
    ):

        for item in group:

            if not isinstance(
                item,
                dict
            ):
                continue

            raw = item.get(
                "raw"
            )

            if not isinstance(
                raw,
                str
            ):
                continue

            if not raw:
                continue

            # Reject legacy multi-config chunks.
            uri_count = len(
                list(
                    _CL_URI_START_RE.finditer(
                        raw
                    )
                )
            )

            if (
                group is legacy
                and uri_count > 1
            ):
                continue

            fp = _cl_v6_hash(
                raw
            )

            if fp in seen:
                continue

            seen.add(fp)

            new_item = dict(item)

            new_item.pop(
                "_cl_start",
                None,
            )

            new_item.pop(
                "_cl_end",
                None,
            )

            new_item[
                "fingerprint"
            ] = fp

            output.append(
                new_item
            )

    return output


# ============================================================
# CONFIG_LOCATION_EXACT_BOUNDARY_V6_END
# ============================================================


# ================================================================
# CONFIG_LOCATION_STRICT_INTEGRITY_V7_START
# ================================================================

import re as _cl_v7_re
import json as _cl_v7_json
import hashlib as _cl_v7_hashlib


# تمام scheme هایی که یک کانفیگ مستقل محسوب می‌شوند.
_CL_V7_URI_START_RE = _cl_v7_re.compile(
    r'(?i)(?:'
    r'vless|'
    r'vmess|'
    r'trojan|'
    r'ss|'
    r'ssr|'
    r'socks|'
    r'socks5|'
    r'hysteria|'
    r'hysteria2|'
    r'hy|'
    r'hy2|'
    r'wireguard|'
    r'tuic|'
    r'juicity|'
    r'naive|'
    r'anytls'
    r')://'
)


def _cl_v7_sha256_raw(raw):
    if isinstance(raw, str):
        data = raw.encode("utf-8", errors="surrogatepass")
    elif isinstance(raw, bytes):
        data = raw
    else:
        data = str(raw).encode("utf-8", errors="surrogatepass")

    return _cl_v7_hashlib.sha256(data).hexdigest()


def _cl_v7_json_is_single(raw):
    """
    JSON باید دقیقاً یک document کامل باشد.
    raw هیچ تغییری نمی‌کند.
    """
    if not isinstance(raw, str):
        return False

    s = raw.strip()

    if not s:
        return False

    if not (s.startswith("{") or s.startswith("[")):
        return False

    try:
        decoder = _cl_v7_json.JSONDecoder()
        obj, end = decoder.raw_decode(s)
    except Exception:
        return False

    # بعد از JSON اصلی فقط whitespace مجاز است.
    if s[end:].strip():
        return False

    return isinstance(obj, (dict, list))


def _cl_v7_wireguard_native_is_single(raw):
    """
    Validate exactly one WireGuard native config.

    Supports both:
      - real newline characters
      - literal escaped \\n sequences

    RAW itself is NEVER modified.
    """
    if not isinstance(raw, str):
        return False

    if not raw.strip():
        return False

    # فقط برای تشخیص یک view موقت می‌سازیم.
    # خود raw بدون تغییر باقی می‌ماند.
    view = raw

    if "\\n" in view and "\n" not in view:
        view = view.replace("\\r\\n", "\n")
        view = view.replace("\\n", "\n")
        view = view.replace("\\r", "\n")

    interface_count = len(
        _cl_v7_re.findall(
            r'(?im)^[ \t]*\[interface\][ \t]*$',
            view
        )
    )

    peer_count = len(
        _cl_v7_re.findall(
            r'(?im)^[ \t]*\[peer\][ \t]*$',
            view
        )
    )

    if interface_count != 1:
        return False

    if peer_count < 1:
        return False

    # URI مستقل نباید به WG Native چسبیده باشد.
    if _CL_V7_URI_START_RE.search(view):
        return False

    return True

def _cl_v7_uri_is_single(raw):
    """
    URI باید دقیقاً با یک scheme کانفیگ شروع شود
    و scheme کانفیگ دوم داخل همان RAW وجود نداشته باشد.
    """
    if not isinstance(raw, str):
        return False

    s = raw.strip()

    if not s:
        return False

    m = _CL_V7_URI_START_RE.match(s)

    if not m:
        return False

    matches = list(_CL_V7_URI_START_RE.finditer(s))

    # یک RAW = یک URI
    if len(matches) != 1:
        return False

    # جلوگیری از چسبیدن WireGuard native بعد از URI
    if _cl_v7_re.search(
        r'(?im)^[ \t]*\[interface\][ \t]*$',
        s
    ):
        return False

    return True


def _cl_v7_is_custom_type(item):
    t = str(
        item.get("type")
        or item.get("protocol")
        or ""
    ).strip().lower()

    return t in {
        "custom",
        "raw",
        "unknown",
        "napsternet_custom",
        "custom_config",
    }


def _cl_v7_item_integrity(item):
    """
    نتیجه:
        True  = رکورد سالم و تک‌کانفیگ
        False = چسبیده / خراب / چند کانفیگی

    مهم:
    هیچ normalization روی raw انجام نمی‌شود.
    """
    if not isinstance(item, dict):
        return False

    raw = item.get("raw")

    if not isinstance(raw, str):
        return False

    if not raw:
        return False

    stripped = raw.strip()

    if not stripped:
        return False

    item_type = str(
        item.get("type")
        or item.get("protocol")
        or ""
    ).strip().lower()

    # ------------------------------------------------
    # JSON
    # ------------------------------------------------
    if (
        item_type.startswith("json")
        or stripped.startswith("{")
        or stripped.startswith("[")
    ):
        return _cl_v7_json_is_single(raw)

    # ------------------------------------------------
    # WireGuard Native
    # ------------------------------------------------
    if (
        item_type == "wireguard_native"
        or _cl_v7_re.search(
            r'(?im)^[ \t]*\[interface\][ \t]*$',
            stripped
        )
    ):
        return _cl_v7_wireguard_native_is_single(raw)

    # ------------------------------------------------
    # URI
    # ------------------------------------------------
    if _CL_V7_URI_START_RE.match(stripped):
        return _cl_v7_uri_is_single(raw)

    # ------------------------------------------------
    # Custom واقعی
    # ------------------------------------------------
    if _cl_v7_is_custom_type(item):

        # Custom نباید دو URI استاندارد چسبیده داشته باشد.
        if len(list(_CL_V7_URI_START_RE.finditer(raw))) > 1:
            return False

        # Custom نباید چند WG block چسبیده داشته باشد.
        if len(
            _cl_v7_re.findall(
                r'(?im)^[ \t]*\[interface\][ \t]*$',
                raw
            )
        ) > 1:
            return False

        return True

    # Legacy ناشناخته:
    # اگر هیچ نشانه‌ای از یک config معتبر ندارد،
    # اجازه ورود به Store داده نمی‌شود.
    return False


# نگهداری extractor واقعی V6
_cl_v7_original_extract_configs = extract_configs


def extract_configs(text):
    """
    V7 final integrity gate

    Pipeline:
        existing detector
              ↓
        strict single-record validation
              ↓
        exact RAW dedupe
              ↓
        store

    هیچ کاراکتری از raw تغییر نمی‌کند.
    """

    original_items = _cl_v7_original_extract_configs(text)

    if not isinstance(original_items, list):
        return original_items

    output = []
    seen_raw = set()

    for item in original_items:

        if not isinstance(item, dict):
            continue

        raw = item.get("raw")

        if not isinstance(raw, str):
            continue

        # مهم:
        # raw همان چیزی است که source تحویل داده.
        # strip / decode / urlencode / normalization نمی‌شود.

        if not _cl_v7_item_integrity(item):
            continue

        key = _cl_v7_sha256_raw(raw)

        if key in seen_raw:
            continue

        seen_raw.add(key)

        # fingerprint فقط metadata است.
        item["fingerprint"] = key

        output.append(item)

    return output


# ================================================================
# CONFIG_LOCATION_STRICT_INTEGRITY_V7_END
# ================================================================



# ============================================================
# FIX20_6_UNIVERSAL_JSON_WRAPPER
# Universal JSON -> protocol URI -> existing protocol parser.
#
# Important:
# - source input is never mutated
# - unknown JSON falls back to legacy behavior
# - non-JSON behavior stays legacy
# ============================================================

_legacy_extract_configs_fix20_6 = extract_configs


def extract_configs(text):
    from app.parser.universal_json import (
        analyze_json,
    )

    analysis = analyze_json(text)

    # Not JSON / undecodable:
    # exact legacy path.
    if not analysis.decoded:
        return _legacy_extract_configs_fix20_6(
            text
        )

    # Valid JSON but no confidently generated URI:
    # preserve legacy/raw handling rather than guessing.
    if not analysis.uris:
        return _legacy_extract_configs_fix20_6(
            text
        )

    merged = []
    seen = set()

    for uri in analysis.uris:
        try:
            items = (
                _legacy_extract_configs_fix20_6(
                    uri
                )
            )
        except Exception:
            items = []

        if items is None:
            continue

        if not isinstance(items,(list,tuple)):
            items=[items]

        for item in items:
            key=repr(item)

            if key in seen:
                continue

            seen.add(key)
            merged.append(item)

    # If a recognized JSON schema produced URIs but the
    # legacy protocol parser cannot consume any of them,
    # preserve original JSON rather than losing it.
    if not merged:
        return _legacy_extract_configs_fix20_6(
            text
        )

    return merged
