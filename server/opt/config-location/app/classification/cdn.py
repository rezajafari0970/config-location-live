from __future__ import annotations

import base64
import ipaddress
import json
import socket

from urllib.parse import (
    parse_qs,
    unquote,
    urlsplit,
)


# High-confidence Cloudflare network ranges.
CF_NETWORKS = tuple(
    ipaddress.ip_network(x)
    for x in (
        "173.245.48.0/20",
        "103.21.244.0/22",
        "103.22.200.0/22",
        "103.31.4.0/22",
        "141.101.64.0/18",
        "108.162.192.0/18",
        "190.93.240.0/20",
        "188.114.96.0/20",
        "197.234.240.0/22",
        "198.41.128.0/17",
        "162.158.0.0/15",
        "104.16.0.0/13",
        "104.24.0.0/14",
        "172.64.0.0/13",
        "131.0.72.0/22",
        "2400:cb00::/32",
        "2606:4700::/32",
        "2803:f800::/32",
        "2405:b500::/32",
        "2405:8100::/32",
        "2a06:98c0::/29",
        "2c0f:f248::/32",
    )
)


PROVIDER_SUFFIXES = {
    "cloudfront": (
        ".cloudfront.net",
    ),
    "fastly": (
        ".fastly.net",
        ".fastlylb.net",
    ),
    "akamai": (
        ".akamaiedge.net",
        ".akamaized.net",
        ".edgekey.net",
        ".edgesuite.net",
    ),
    "bunny": (
        ".b-cdn.net",
        ".bunnycdn.com",
    ),
    "azure": (
        ".azureedge.net",
        ".trafficmanager.net",
        ".azurefd.net",
    ),
}


WORKER_SUFFIXES = (
    ".workers.dev",
)


def _host(value):
    value = str(value or "").strip().lower()

    if not value:
        return None

    value = value.strip("[]")

    if "://" in value:
        try:
            value = (
                urlsplit(value).hostname
                or value
            )
        except Exception:
            pass

    if value.count(":") == 1:
        left, right = value.rsplit(":", 1)

        if right.isdigit():
            value = left

    return value.rstrip(".") or None


def _decode_vmess(raw):
    try:
        payload = raw.split("://", 1)[1]
        payload += "=" * (-len(payload) % 4)

        decoded = base64.urlsafe_b64decode(
            payload.encode()
        ).decode(
            "utf-8",
            errors="ignore",
        )

        obj = json.loads(decoded)

        return obj if isinstance(obj, dict) else {}
    except Exception:
        return {}


def _walk_json(obj, out):
    if isinstance(obj, dict):
        for key, value in obj.items():

            k = str(key).lower()

            if k in {
                "address",
                "server",
                "host",
                "hostname",
                "sni",
                "servername",
                "server_name",
            }:
                if isinstance(value, str):
                    h = _host(value)

                    if h:
                        out.add(h)

            _walk_json(value, out)

    elif isinstance(obj, list):
        for value in obj:
            _walk_json(value, out)


def extract_hosts(raw):
    raw = str(raw or "").strip()

    hosts = set()

    if not raw:
        return []

    # URI forms
    if "://" in raw:
        scheme = raw.split("://", 1)[0].lower()

        if scheme == "vmess":
            obj = _decode_vmess(raw)

            _walk_json(obj, hosts)

            return sorted(hosts)

        try:
            u = urlsplit(raw)

            if u.hostname:
                hosts.add(
                    u.hostname.lower()
                )

            query = parse_qs(
                u.query,
                keep_blank_values=True,
            )

            for key in (
                "host",
                "sni",
                "servername",
                "peer",
            ):
                for value in query.get(key, []):
                    h = _host(
                        unquote(value)
                    )

                    if h:
                        hosts.add(h)

        except Exception:
            pass

    # JSON configs stay JSON.
    stripped = raw.lstrip()

    if stripped.startswith(
        ("{", "[")
    ):
        try:
            obj = json.loads(raw)

            _walk_json(obj, hosts)

        except Exception:
            pass

    return sorted(hosts)


def _resolve(host):
    try:
        ipaddress.ip_address(host)
        return [host]
    except Exception:
        pass

    found = set()

    try:
        for row in socket.getaddrinfo(
            host,
            None,
            type=socket.SOCK_STREAM,
        ):
            if row and row[4]:
                found.add(
                    str(row[4][0])
                )
    except Exception:
        pass

    return sorted(found)


def _is_cloudflare_ip(value):
    try:
        ip = ipaddress.ip_address(value)

        return any(
            ip in net
            for net in CF_NETWORKS
        )
    except Exception:
        return False


def classify_cdn(raw, runtime_metadata=None):
    hosts = extract_hosts(raw)

    evidence = []
    resolved = {}

    runtime_metadata = (
        runtime_metadata
        if isinstance(
            runtime_metadata,
            dict,
        )
        else {}
    )

    endpoint = runtime_metadata.get(
        "endpoint",
        {},
    )

    runtime_hosts = set()

    if isinstance(endpoint, dict):

        for key in (
            "address",
            "host",
            "sni",
            "authority",
        ):
            value = endpoint.get(key)

            if isinstance(value, str):
                h = _host(value)

                if h:
                    runtime_hosts.add(h)

        for key in (
            "addresses",
            "hosts",
            "sni",
        ):
            values = endpoint.get(key)

            if isinstance(values, list):
                for value in values:
                    h = _host(value)

                    if h:
                        runtime_hosts.add(h)

    if runtime_hosts:
        evidence.append(
            "xray_runtime_endpoint:"
            + ",".join(
                sorted(runtime_hosts)
            )
        )

    hosts = sorted(
        set(hosts)
        | runtime_hosts
    )

    # 1. Explicit Worker hostname = strongest evidence.
    for host in hosts:
        if host.endswith(
            WORKER_SUFFIXES
        ):
            evidence.append(
                "worker_hostname:" + host
            )

            return {
                "cdn_class":
                    "cloudflare_worker",
                "cdn_provider":
                    "cloudflare_workers",
                "cdn_confidence":
                    1.0,
                "cdn_evidence":
                    evidence,
                "cdn_hosts":
                    hosts,
                "cdn_resolved_ips":
                    resolved,
            }

    # 2. Explicit known CDN provider hostname.
    for provider, suffixes in (
        PROVIDER_SUFFIXES.items()
    ):
        for host in hosts:
            if host.endswith(
                suffixes
            ):
                evidence.append(
                    "provider_hostname:"
                    + provider
                    + ":"
                    + host
                )

                return {
                    "cdn_class":
                        "other_cdn",
                    "cdn_provider":
                        provider,
                    "cdn_confidence":
                        0.98,
                    "cdn_evidence":
                        evidence,
                    "cdn_hosts":
                        hosts,
                    "cdn_resolved_ips":
                        resolved,
                }

    # 3. DNS/IP evidence.
    cf_hits = 0
    total_ips = 0

    for host in hosts:
        ips = _resolve(host)

        resolved[host] = ips

        for ip in ips:
            total_ips += 1

            if _is_cloudflare_ip(ip):
                cf_hits += 1

                evidence.append(
                    "cloudflare_ip:"
                    + host
                    + "="
                    + ip
                )

    if cf_hits > 0:
        runtime_agreement = bool(
            runtime_hosts
            and any(
                host in runtime_hosts
                for host in hosts
            )
        )

        confidence = (
            0.995
            if (
                total_ips > 0
                and cf_hits == total_ips
                and runtime_agreement
            )
            else (
                0.99
                if (
                    total_ips > 0
                    and cf_hits == total_ips
                )
                else 0.94
            )
        )

        return {
            "cdn_class":
                "cloudflare_cdn",
            "cdn_provider":
                "cloudflare",
            "cdn_confidence":
                confidence,
            "cdn_evidence":
                evidence,
            "cdn_hosts":
                hosts,
            "cdn_resolved_ips":
                resolved,
        }

    # No host information means we cannot safely decide.
    if not hosts:
        return {
            "cdn_class":
                "unknown",
            "cdn_provider":
                "unknown",
            "cdn_confidence":
                0.0,
            "cdn_evidence": [
                "no_endpoint_evidence"
            ],
            "cdn_hosts": [],
            "cdn_resolved_ips": {},
        }

    # Important:
    # hostname resolving outside known CDN space alone is
    # not enough to guarantee direct/non-CDN.
    #
    # Only literal direct IP endpoint gets high confidence.
    literal_ips = []

    for host in hosts:
        try:
            ipaddress.ip_address(host)

            literal_ips.append(host)
        except Exception:
            pass

    if literal_ips and len(
        literal_ips
    ) == len(hosts):
        return {
            "cdn_class":
                "non_cdn",
            "cdn_provider":
                "none",
            "cdn_confidence":
                0.95,
            "cdn_evidence": [
                "literal_direct_ip:"
                + x
                for x in literal_ips
            ],
            "cdn_hosts":
                hosts,
            "cdn_resolved_ips":
                resolved,
        }

    return {
        "cdn_class":
            "unknown",
        "cdn_provider":
            "unknown",
        "cdn_confidence":
            0.35,
        "cdn_evidence": [
            "insufficient_cdn_evidence"
        ],
        "cdn_hosts":
            hosts,
        "cdn_resolved_ips":
            resolved,
    }
