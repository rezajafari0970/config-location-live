from __future__ import annotations

import base64
import json
import re

from dataclasses import dataclass, field
from typing import Any
from urllib.parse import quote, urlencode


_INTERNAL_PROTOCOLS = {
    "direct",
    "freedom",
    "block",
    "blackhole",
    "dns",
    "selector",
    "urltest",
    "url-test",
}


_PROTOCOL_ALIASES = {
    "hy2": "hysteria2",
    "hysteria2": "hysteria2",
    "hysteria": "hysteria",
    "shadowsocks": "shadowsocks",
    "ss": "shadowsocks",
    "socks5": "socks",
    "socks": "socks",
    "wireguard": "wireguard",
    "wireguard-out": "wireguard",
    "vless": "vless",
    "vmess": "vmess",
    "trojan": "trojan",
    "tuic": "tuic",
    "anytls": "anytls",
    "naive": "naive",
    "juicity": "juicity",
    "http": "http",
    "https": "http",
}


@dataclass
class JsonOutbound:
    schema: str
    protocol: str
    tag: str | None
    raw: dict[str, Any]
    path: str
    selected: bool = False
    generated_uri: str | None = None
    warnings: list[str] = field(
        default_factory=list
    )


@dataclass
class JsonParseResult:
    source_raw: str
    decoded: bool
    schema: str | None
    outbounds: list[JsonOutbound]
    uris: list[str]
    unknown_protocols: list[str]
    warnings: list[str]
    json_documents: int


def _b64decode(value: str) -> bytes | None:
    value=value.strip()

    if not value:
        return None

    padding="="*((4-len(value)%4)%4)

    for decoder in (
        base64.urlsafe_b64decode,
        base64.b64decode,
    ):
        try:
            return decoder(
                value+padding
            )
        except Exception:
            pass

    return None


def _json_load(value: str) -> Any | None:
    try:
        return json.loads(value)
    except Exception:
        return None


def _decode_layers(
    text: str,
    *,
    max_depth: int = 5,
) -> list[Any]:

    found=[]
    seen=set()

    def walk(value: Any, depth: int):
        if depth > max_depth:
            return

        if isinstance(value,(dict,list)):
            marker=repr(value)[:10000]

            if marker not in seen:
                seen.add(marker)
                found.append(value)

            if isinstance(value,dict):
                for child in value.values():
                    walk(child,depth+1)

            else:
                for child in value:
                    walk(child,depth+1)

            return

        if not isinstance(value,str):
            return

        s=value.strip()

        if not s:
            return

        obj=_json_load(s)

        if obj is not None:
            walk(obj,depth+1)
            return

        # Quoted/escaped JSON frequently appears inside
        # wrapper fields such as config/raw/payload.
        if (
            ("\\" in s or s.startswith('"'))
            and
            len(s) > 2
        ):
            try:
                u=json.loads(
                    '"'
                    + s.replace('"','\\"')
                    + '"'
                )
            except Exception:
                u=None

            if isinstance(u,str):
                obj=_json_load(u)

                if obj is not None:
                    walk(obj,depth+1)
                    return

        # Conservative base64 JSON detection.
        if (
            len(s) >= 16
            and
            re.fullmatch(
                r"[A-Za-z0-9_\-+/=\s]+",
                s,
            )
        ):
            raw=_b64decode(s)

            if raw:
                try:
                    decoded=raw.decode("utf-8")
                except Exception:
                    decoded=None

                if decoded:
                    obj=_json_load(
                        decoded.strip()
                    )

                    if obj is not None:
                        walk(obj,depth+1)

    root=_json_load(
        text.strip()
    )

    if root is not None:
        walk(root,0)

    return found


def _schema_of(obj: Any) -> str | None:
    if not isinstance(obj,dict):
        return None

    if isinstance(
        obj.get("outbounds"),
        list
    ):
        # sing-box uses outbound.type;
        # Xray/V2Ray uses outbound.protocol.
        obs=obj["outbounds"]

        if any(
            isinstance(x,dict)
            and "type" in x
            for x in obs
        ):
            return "sing-box"

        if any(
            isinstance(x,dict)
            and "protocol" in x
            for x in obs
        ):
            return "xray"

    if (
        "protocol" in obj
        and
        isinstance(
            obj.get("protocol"),
            str,
        )
    ):
        return "xray-outbound"

    if (
        "type" in obj
        and
        isinstance(
            obj.get("type"),
            str,
        )
    ):
        return "sing-box-outbound"

    return None


def _selected_tags(
    obj: dict[str,Any],
) -> set[str]:

    selected=set()

    # sing-box route.final
    route=obj.get("route")

    if isinstance(route,dict):
        final=route.get("final")

        if isinstance(final,str):
            selected.add(final)

        rules=route.get("rules")

        if isinstance(rules,list):
            for rule in rules:
                if not isinstance(rule,dict):
                    continue

                outbound=rule.get("outbound")

                if isinstance(outbound,str):
                    selected.add(outbound)


    # Xray/V2Ray routing rules.
    routing=obj.get("routing")

    if isinstance(routing,dict):
        rules=routing.get("rules")

        if isinstance(rules,list):
            for rule in rules:
                if not isinstance(rule,dict):
                    continue

                tag=(
                    rule.get("outboundTag")
                    or
                    rule.get("balancerTag")
                )

                if isinstance(tag,str):
                    selected.add(tag)

    return selected


def _host_port(
    host: Any,
    port: Any,
) -> tuple[str,int] | None:

    if host is None or port is None:
        return None

    host=str(host).strip()

    try:
        port=int(port)
    except Exception:
        return None

    if not host or not (1 <= port <= 65535):
        return None

    return host,port


def _netloc(
    host: str,
    port: int,
) -> str:

    if ":" in host and not host.startswith("["):
        host=f"[{host}]"

    return f"{host}:{port}"


def _stream_query(
    stream: dict[str,Any],
) -> dict[str,str]:

    q={}

    network=(
        stream.get("network")
        or
        stream.get("type")
    )

    if isinstance(network,str) and network:
        q["type"]=network


    security=stream.get("security")

    if isinstance(security,str) and security:
        q["security"]=security


    tls=stream.get("tlsSettings")

    if isinstance(tls,dict):
        sni=(
            tls.get("serverName")
            or
            tls.get("server_name")
        )

        if sni:
            q["sni"]=str(sni)

        if tls.get("allowInsecure") is True:
            q["allowInsecure"]="1"

        fp=(
            tls.get("fingerprint")
            or
            tls.get("fingerPrint")
        )

        if fp:
            q["fp"]=str(fp)


    reality=stream.get(
        "realitySettings"
    )

    if isinstance(reality,dict):
        q["security"]="reality"

        sni=(
            reality.get("serverName")
            or
            reality.get("server_name")
        )

        if sni:
            q["sni"]=str(sni)

        pbk=(
            reality.get("publicKey")
            or
            reality.get("public_key")
        )

        if pbk:
            q["pbk"]=str(pbk)

        sid=(
            reality.get("shortId")
            or
            reality.get("short_id")
        )

        if sid:
            q["sid"]=str(sid)

        spx=(
            reality.get("spiderX")
            or
            reality.get("spider_x")
        )

        if spx:
            q["spx"]=str(spx)


    ws=stream.get("wsSettings")

    if isinstance(ws,dict):
        if ws.get("path"):
            q["path"]=str(ws["path"])

        headers=ws.get("headers")

        if isinstance(headers,dict):
            host=(
                headers.get("Host")
                or
                headers.get("host")
            )

            if host:
                q["host"]=str(host)


    grpc=stream.get("grpcSettings")

    if isinstance(grpc,dict):
        service=(
            grpc.get("serviceName")
            or
            grpc.get("service_name")
        )

        if service:
            q["serviceName"]=str(service)


    xhttp=(
        stream.get("xhttpSettings")
        or
        stream.get("splithttpSettings")
    )

    if isinstance(xhttp,dict):
        if xhttp.get("path"):
            q["path"]=str(xhttp["path"])

        if xhttp.get("host"):
            q["host"]=str(xhttp["host"])


    hu=stream.get(
        "httpupgradeSettings"
    )

    if isinstance(hu,dict):
        if hu.get("path"):
            q["path"]=str(hu["path"])

        if hu.get("host"):
            q["host"]=str(hu["host"])


    tcp=stream.get("tcpSettings")

    if isinstance(tcp,dict):
        header=tcp.get("header")

        if isinstance(header,dict):
            htype=header.get("type")

            if htype:
                q["headerType"]=str(htype)


    kcp=stream.get("kcpSettings")

    if isinstance(kcp,dict):
        seed=kcp.get("seed")

        if seed:
            q["seed"]=str(seed)

        header=kcp.get("header")

        if isinstance(header,dict) and header.get("type"):
            q["headerType"]=str(
                header["type"]
            )


    return q


def _xray_vless(o: dict[str,Any]) -> str | None:
    settings=o.get("settings")

    if not isinstance(settings,dict):
        return None

    vnext=settings.get("vnext")

    if not isinstance(vnext,list) or not vnext:
        return None

    server=vnext[0]

    if not isinstance(server,dict):
        return None

    hp=_host_port(
        server.get("address"),
        server.get("port"),
    )

    if not hp:
        return None

    users=server.get("users")

    if not isinstance(users,list) or not users:
        return None

    user=users[0]

    if not isinstance(user,dict):
        return None

    uid=(
        user.get("id")
        or
        user.get("uuid")
    )

    if not uid:
        return None

    host,port=hp

    q={
        "encryption":
            str(
                user.get(
                    "encryption",
                    "none",
                )
            )
    }

    flow=user.get("flow")

    if flow:
        q["flow"]=str(flow)

    stream=o.get("streamSettings")

    if isinstance(stream,dict):
        q.update(
            _stream_query(stream)
        )

    tag=o.get("tag") or "JSON-VLESS"

    return (
        f"vless://{quote(str(uid),safe='')}"
        f"@{_netloc(host,port)}"
        f"?{urlencode(q)}"
        f"#{quote(str(tag))}"
    )


def _xray_vmess(o: dict[str,Any]) -> str | None:
    settings=o.get("settings")

    if not isinstance(settings,dict):
        return None

    vnext=settings.get("vnext")

    if not isinstance(vnext,list) or not vnext:
        return None

    server=vnext[0]

    if not isinstance(server,dict):
        return None

    hp=_host_port(
        server.get("address"),
        server.get("port"),
    )

    if not hp:
        return None

    users=server.get("users")

    if not isinstance(users,list) or not users:
        return None

    user=users[0]

    if not isinstance(user,dict):
        return None

    uid=user.get("id")

    if not uid:
        return None

    host,port=hp

    obj={
        "v":"2",
        "ps":str(
            o.get("tag")
            or
            "JSON-VMess"
        ),
        "add":host,
        "port":str(port),
        "id":str(uid),
        "aid":str(
            user.get("alterId",0)
        ),
        "scy":str(
            user.get("security","auto")
        ),
        "net":"",
        "type":"none",
        "host":"",
        "path":"",
        "tls":"",
        "sni":"",
    }

    stream=o.get("streamSettings")

    if isinstance(stream,dict):
        obj["net"]=str(
            stream.get("network","")
        )

        sec=stream.get("security")

        if sec in ("tls","reality"):
            obj["tls"]=str(sec)

        tls=stream.get("tlsSettings")

        if isinstance(tls,dict):
            obj["sni"]=str(
                tls.get("serverName","")
            )

        ws=stream.get("wsSettings")

        if isinstance(ws,dict):
            obj["path"]=str(
                ws.get("path","")
            )

            headers=ws.get("headers")

            if isinstance(headers,dict):
                obj["host"]=str(
                    headers.get("Host","")
                )

        grpc=stream.get("grpcSettings")

        if isinstance(grpc,dict):
            obj["path"]=str(
                grpc.get(
                    "serviceName",
                    "",
                )
            )

    raw=json.dumps(
        obj,
        ensure_ascii=False,
        separators=(",",":"),
    ).encode()

    encoded=base64.b64encode(
        raw
    ).decode()

    return "vmess://"+encoded


def _xray_server_uri(
    o: dict[str,Any],
    scheme: str,
) -> str | None:

    settings=o.get("settings")

    if not isinstance(settings,dict):
        return None

    servers=(
        settings.get("servers")
        or
        settings.get("server")
    )

    if isinstance(servers,dict):
        servers=[servers]

    if not isinstance(servers,list) or not servers:
        return None

    s=servers[0]

    if not isinstance(s,dict):
        return None

    hp=_host_port(
        s.get("address")
        or s.get("server"),
        s.get("port")
        or s.get("server_port"),
    )

    if not hp:
        return None

    host,port=hp

    password=(
        s.get("password")
        or
        s.get("pass")
        or
        s.get("uuid")
        or
        s.get("token")
    )

    if scheme == "shadowsocks":
        method=(
            s.get("method")
            or
            s.get("cipher")
            or
            "aes-128-gcm"
        )

        if not password:
            return None

        auth=(
            f"{method}:{password}"
        )

        b64=base64.urlsafe_b64encode(
            auth.encode()
        ).decode().rstrip("=")

        return (
            f"ss://{b64}"
            f"@{_netloc(host,port)}"
            f"#{quote(str(o.get('tag') or 'JSON-SS'))}"
        )

    if not password:
        return None

    q={}

    stream=o.get("streamSettings")

    if isinstance(stream,dict):
        q.update(
            _stream_query(stream)
        )

    return (
        f"{scheme}://"
        f"{quote(str(password),safe='')}"
        f"@{_netloc(host,port)}"
        +
        (
            "?"
            + urlencode(q)
            if q
            else ""
        )
        +
        f"#{quote(str(o.get('tag') or 'JSON'))}"
    )


def _singbox_uri(o: dict[str,Any]) -> str | None:
    protocol=str(
        o.get("type","")
    ).lower()

    protocol=_PROTOCOL_ALIASES.get(
        protocol,
        protocol,
    )

    host=(
        o.get("server")
        or
        o.get("address")
    )

    port=(
        o.get("server_port")
        or
        o.get("port")
    )

    hp=_host_port(host,port)

    if not hp:
        return None

    host,port=hp
    tag=o.get("tag") or f"JSON-{protocol}"

    q={}

    tls=o.get("tls")

    if isinstance(tls,dict) and tls.get("enabled"):
        q["security"]="tls"

        sni=(
            tls.get("server_name")
            or
            tls.get("serverName")
        )

        if sni:
            q["sni"]=str(sni)

        if tls.get("insecure") is True:
            q["allowInsecure"]="1"

        reality=tls.get("reality")

        if isinstance(reality,dict) and reality.get("enabled"):
            q["security"]="reality"

            if reality.get("public_key"):
                q["pbk"]=str(
                    reality["public_key"]
                )

            if reality.get("short_id"):
                q["sid"]=str(
                    reality["short_id"]
                )


    transport=o.get("transport")

    if isinstance(transport,dict):
        t=transport.get("type")

        if t:
            q["type"]=str(t)

        if transport.get("path"):
            q["path"]=str(
                transport["path"]
            )

        headers=transport.get("headers")

        if isinstance(headers,dict):
            host_header=(
                headers.get("Host")
                or
                headers.get("host")
            )

            if host_header:
                q["host"]=str(
                    host_header
                )

        service=(
            transport.get("service_name")
            or
            transport.get("serviceName")
        )

        if service:
            q["serviceName"]=str(service)


    if protocol == "vless":
        uid=(
            o.get("uuid")
            or
            o.get("id")
        )

        if not uid:
            return None

        q["encryption"]=str(
            o.get("encryption","none")
        )

        if o.get("flow"):
            q["flow"]=str(o["flow"])

        return (
            f"vless://{quote(str(uid),safe='')}"
            f"@{_netloc(host,port)}"
            f"?{urlencode(q)}"
            f"#{quote(str(tag))}"
        )


    if protocol == "trojan":
        password=o.get("password")

        if not password:
            return None

        return (
            f"trojan://{quote(str(password),safe='')}"
            f"@{_netloc(host,port)}"
            +
            (
                "?"
                + urlencode(q)
                if q
                else ""
            )
            +
            f"#{quote(str(tag))}"
        )


    if protocol == "shadowsocks":
        method=(
            o.get("method")
            or
            o.get("cipher")
        )

        password=o.get("password")

        if not method or password is None:
            return None

        auth=f"{method}:{password}"

        token=base64.urlsafe_b64encode(
            auth.encode()
        ).decode().rstrip("=")

        return (
            f"ss://{token}"
            f"@{_netloc(host,port)}"
            f"#{quote(str(tag))}"
        )


    if protocol == "hysteria2":
        password=(
            o.get("password")
            or
            o.get("auth")
        )

        if not password:
            return None

        return (
            f"hy2://{quote(str(password),safe='')}"
            f"@{_netloc(host,port)}/"
            +
            (
                "?"
                + urlencode(q)
                if q
                else ""
            )
            +
            f"#{quote(str(tag))}"
        )


    if protocol == "hysteria":
        auth=(
            o.get("auth_str")
            or
            o.get("auth")
            or
            o.get("password")
        )

        if not auth:
            return None

        return (
            f"hysteria://{quote(str(auth),safe='')}"
            f"@{_netloc(host,port)}"
            +
            (
                "?"
                + urlencode(q)
                if q
                else ""
            )
            +
            f"#{quote(str(tag))}"
        )


    if protocol == "tuic":
        uid=o.get("uuid")
        password=o.get("password")

        if not uid or password is None:
            return None

        return (
            f"tuic://"
            f"{quote(str(uid),safe='')}:"
            f"{quote(str(password),safe='')}"
            f"@{_netloc(host,port)}"
            +
            (
                "?"
                + urlencode(q)
                if q
                else ""
            )
            +
            f"#{quote(str(tag))}"
        )


    if protocol == "anytls":
        password=o.get("password")

        if not password:
            return None

        return (
            f"anytls://{quote(str(password),safe='')}"
            f"@{_netloc(host,port)}"
            +
            (
                "?"
                + urlencode(q)
                if q
                else ""
            )
            +
            f"#{quote(str(tag))}"
        )


    if protocol == "naive":
        username=o.get("username","")
        password=o.get("password","")

        auth=""

        if username or password:
            auth=(
                quote(str(username),safe="")
                + ":"
                + quote(str(password),safe="")
                + "@"
            )

        return (
            f"naive+https://{auth}"
            f"{_netloc(host,port)}"
            f"#{quote(str(tag))}"
        )


    if protocol == "juicity":
        uid=o.get("uuid")
        password=o.get("password")

        if not uid or password is None:
            return None

        return (
            f"juicity://"
            f"{quote(str(uid),safe='')}:"
            f"{quote(str(password),safe='')}"
            f"@{_netloc(host,port)}"
            +
            (
                "?"
                + urlencode(q)
                if q
                else ""
            )
            +
            f"#{quote(str(tag))}"
        )


    if protocol == "socks":
        username=o.get("username")
        password=o.get("password")

        auth=""

        if username is not None:
            auth=quote(str(username),safe="")

            if password is not None:
                auth += ":"+quote(
                    str(password),
                    safe="",
                )

            auth += "@"

        return (
            f"socks://{auth}"
            f"{_netloc(host,port)}"
            f"#{quote(str(tag))}"
        )


    return None


def _extract_xray(
    obj: dict[str,Any],
    path: str,
) -> list[JsonOutbound]:

    selected=_selected_tags(obj)

    raw_outbounds=obj.get("outbounds")

    if not isinstance(raw_outbounds,list):
        if isinstance(
            obj.get("protocol"),
            str
        ):
            raw_outbounds=[obj]
        else:
            return []

    result=[]

    for index,o in enumerate(raw_outbounds):
        if not isinstance(o,dict):
            continue

        protocol=str(
            o.get("protocol","")
        ).lower()

        if not protocol:
            continue

        tag=(
            str(o.get("tag"))
            if o.get("tag") is not None
            else None
        )

        normalized=_PROTOCOL_ALIASES.get(
            protocol,
            protocol,
        )

        item=JsonOutbound(
            schema="xray",
            protocol=normalized,
            tag=tag,
            raw=o,
            path=f"{path}.outbounds[{index}]",
            selected=bool(
                tag and tag in selected
            ),
        )

        if normalized in _INTERNAL_PROTOCOLS:
            result.append(item)
            continue

        if normalized == "vless":
            item.generated_uri=_xray_vless(o)

        elif normalized == "vmess":
            item.generated_uri=_xray_vmess(o)

        elif normalized in (
            "trojan",
            "hysteria",
            "hysteria2",
        ):
            item.generated_uri=_xray_server_uri(
                o,
                (
                    "hy2"
                    if normalized == "hysteria2"
                    else normalized
                ),
            )

        elif normalized == "shadowsocks":
            item.generated_uri=_xray_server_uri(
                o,
                "shadowsocks",
            )

        result.append(item)

    return result


def _extract_singbox(
    obj: dict[str,Any],
    path: str,
) -> list[JsonOutbound]:

    selected=_selected_tags(obj)

    raw_outbounds=obj.get("outbounds")

    if not isinstance(raw_outbounds,list):
        if isinstance(
            obj.get("type"),
            str
        ):
            raw_outbounds=[obj]
        else:
            return []

    result=[]

    for index,o in enumerate(raw_outbounds):
        if not isinstance(o,dict):
            continue

        protocol=str(
            o.get("type","")
        ).lower()

        if not protocol:
            continue

        normalized=_PROTOCOL_ALIASES.get(
            protocol,
            protocol,
        )

        tag=(
            str(o.get("tag"))
            if o.get("tag") is not None
            else None
        )

        item=JsonOutbound(
            schema="sing-box",
            protocol=normalized,
            tag=tag,
            raw=o,
            path=f"{path}.outbounds[{index}]",
            selected=bool(
                tag and tag in selected
            ),
        )

        if normalized not in _INTERNAL_PROTOCOLS:
            item.generated_uri=_singbox_uri(o)

        result.append(item)

    return result


def _walk_objects(
    value: Any,
    path: str="$",
):
    if isinstance(value,dict):
        yield path,value

        for key,child in value.items():
            yield from _walk_objects(
                child,
                f"{path}.{key}",
            )

    elif isinstance(value,list):
        for i,child in enumerate(value):
            yield from _walk_objects(
                child,
                f"{path}[{i}]",
            )


def analyze_json(
    text: str,
) -> JsonParseResult:

    docs=_decode_layers(text)

    outbounds=[]
    schemas=[]

    for doc_index,doc in enumerate(docs):
        for path,obj in _walk_objects(
            doc,
            f"$doc[{doc_index}]",
        ):
            schema=_schema_of(obj)

            if not schema:
                continue

            schemas.append(schema)

            if schema.startswith("xray"):
                outbounds.extend(
                    _extract_xray(
                        obj,
                        path,
                    )
                )

            elif schema.startswith("sing-box"):
                outbounds.extend(
                    _extract_singbox(
                        obj,
                        path,
                    )
                )

    # Deduplicate by schema/path/protocol/tag/URI.
    unique=[]
    seen=set()

    for o in outbounds:
        key=(
            o.schema,
            o.path,
            o.protocol,
            o.tag,
            o.generated_uri,
        )

        if key in seen:
            continue

        seen.add(key)
        unique.append(o)

    proxy=[
        x for x in unique
        if x.protocol not in _INTERNAL_PROTOCOLS
    ]

    # Prefer explicitly routed/selected proxies,
    # but retain all valid proxy outbounds.
    proxy.sort(
        key=lambda x:(
            not x.selected,
            x.path,
        )
    )

    uris=[]
    uri_seen=set()

    for x in proxy:
        if not x.generated_uri:
            continue

        if x.generated_uri in uri_seen:
            continue

        uri_seen.add(x.generated_uri)
        uris.append(x.generated_uri)

    unknown=sorted({
        x.protocol
        for x in proxy
        if not x.generated_uri
    })

    warnings=[]

    if docs and not proxy:
        warnings.append(
            "valid_json_but_no_proxy_outbound_found"
        )

    if unknown:
        warnings.append(
            "unsupported_or_unknown_outbound:"
            + ",".join(unknown)
        )

    schema=None

    if schemas:
        schema=schemas[0]

    return JsonParseResult(
        source_raw=text,
        decoded=bool(docs),
        schema=schema,
        outbounds=proxy,
        uris=uris,
        unknown_protocols=unknown,
        warnings=warnings,
        json_documents=len(docs),
    )


def extract_json_uris(
    text: str,
) -> list[str]:

    return analyze_json(
        text
    ).uris


def looks_like_json(
    text: str,
) -> bool:

    s=text.lstrip()

    if s.startswith("{") or s.startswith("["):
        return True

    return bool(
        _decode_layers(text)
    )
