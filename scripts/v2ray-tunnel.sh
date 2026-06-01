#!/usr/bin/env bash
set -euo pipefail

# Starts a whole-system tunnel from a proxy config stored in ENV.
#
# Required ENV, one of:
#   V2RAY_CONFIG, V2RAY_URI, PROXY_CONFIG, PROXY_URI
#
# Sample ENV
#   V2RAY_CONFIG=sub-link
#   TUNNEL_IFACE=tun0
#   TUNNEL_ADDRESS=172.19.0.1/30
#   TUNNEL_IPV6_ROUTE=false
#   TUNNEL_IPV6_ADDRESS=fdfe:dcba:9876::1/126
#   TUNNEL_STACK=system
#   TUNNEL_STRICT_ROUTE=true
#   TUNNEL_RESOLVE_DESTINATION=false
#   TUNNEL_ENABLE_DNS_ROUTING=true
#   TUNNEL_REMOTE_DNS=1.1.1.1
#   TUNNEL_REMOTE_DNS_PORT=53
#   TUNNEL_DIRECT_DNS=local
#   TUNNEL_DIRECT_DNS_PORT=53
#   TUNNEL_TEST_URL=https://www.gstatic.com/generate_204
#   TUNNEL_LOG_LEVEL=info
#
# Supported input:
#   - sing-box JSON config: passed through as-is
#   - subscription URLs
#   - share links: vless://, vmess://, trojan://, ss://, socks://, http://, https://
#
# Container note:
#   TUN mode needs /dev/net/tun and NET_ADMIN.
#   Docker example:
#     docker run --cap-add=NET_ADMIN --device=/dev/net/tun ...

CONFIG_ENV="${V2RAY_CONFIG:-${V2RAY_URI:-${PROXY_CONFIG:-${PROXY_URI:-}}}}"
STATE_DIR="${TUNNEL_STATE_DIR:-/tmp/system-v2ray-tunnel}"
SING_BOX_BIN="${SING_BOX_BIN:-sing-box}"
SING_BOX_VERSION="1.13.12"
LOG_LEVEL="${TUNNEL_LOG_LEVEL:-info}"
TUN_IFACE="${TUNNEL_IFACE:-tun0}"
TUN_ADDRESS="${TUNNEL_ADDRESS:-172.19.0.1/30}"
TUN_IPV6_ROUTE="${TUNNEL_IPV6_ROUTE:-false}"
TUN_IPV6_ADDRESS="${TUNNEL_IPV6_ADDRESS:-fdfe:dcba:9876::1/126}"
TUN_STACK="${TUNNEL_STACK:-system}"
STRICT_ROUTE="${TUNNEL_STRICT_ROUTE:-true}"
RESOLVE_DESTINATION="${TUNNEL_RESOLVE_DESTINATION:-false}"
ENABLE_DNS_ROUTING="${TUNNEL_ENABLE_DNS_ROUTING:-true}"
REMOTE_DNS="${TUNNEL_REMOTE_DNS:-1.1.1.1}"
REMOTE_DNS_PORT="${TUNNEL_REMOTE_DNS_PORT:-53}"
DIRECT_DNS="${TUNNEL_DIRECT_DNS:-local}"
DIRECT_DNS_PORT="${TUNNEL_DIRECT_DNS_PORT:-53}"
TEST_URL="${TUNNEL_TEST_URL:-https://www.gstatic.com/generate_204}"

die() {
  echo "system-v2ray-tunnel: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

bool_json() {
  case "${1,,}" in
    1|true|yes|on) printf true ;;
    0|false|no|off) printf false ;;
    *) die "invalid boolean value: $1" ;;
  esac
}

install_sing_box_if_needed() {
  if [[ "$SING_BOX_BIN" != "sing-box" ]]; then
    command -v "$SING_BOX_BIN" >/dev/null 2>&1 || \
      die "SING_BOX_BIN is set to '$SING_BOX_BIN' but it is not executable"
    return
  fi

  local current_version=""
  if command -v "$SING_BOX_BIN" >/dev/null 2>&1; then
    local version_output
    version_output="$("$SING_BOX_BIN" version 2>/dev/null || true)"
    current_version="${version_output#sing-box version }"
    current_version="${current_version%%$'\n'*}"
  fi

  if [[ "$current_version" == "$SING_BOX_VERSION" ]]; then
    return
  fi

  if [[ -n "$current_version" ]]; then
    echo "system-v2ray-tunnel: sing-box $current_version found; replacing with $SING_BOX_VERSION" >&2
  else
    echo "system-v2ray-tunnel: sing-box not found; installing $SING_BOX_VERSION" >&2
  fi

  need_cmd curl
  need_cmd tar

  local arch url tmpdir
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported CPU architecture for auto-install: $(uname -m)" ;;
  esac

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  url="https://iamshakeri.ir/fs/sing-box-${SING_BOX_VERSION}-linux-${arch}.tar.gz"

  echo "system-v2ray-tunnel: downloading ${url}" >&2
  curl -fsSL "$url" -o "$tmpdir/sing-box.tar.gz"
  tar -xzf "$tmpdir/sing-box.tar.gz" -C "$tmpdir"
  install -m 0755 "$tmpdir/sing-box-${SING_BOX_VERSION}-linux-${arch}/sing-box" /usr/local/bin/sing-box
}

mkdir -p "$STATE_DIR"
[[ -n "$CONFIG_ENV" ]] || die "set V2RAY_CONFIG, V2RAY_URI, PROXY_CONFIG, or PROXY_URI"

need_cmd python3
install_sing_box_if_needed

CONFIG_FILE="$STATE_DIR/config.json"
STRICT_ROUTE_JSON="$(bool_json "$STRICT_ROUTE")"
RESOLVE_DESTINATION_JSON="$(bool_json "$RESOLVE_DESTINATION")"
ENABLE_DNS_ROUTING_JSON="$(bool_json "$ENABLE_DNS_ROUTING")"
TUN_IPV6_ROUTE_JSON="$(bool_json "$TUN_IPV6_ROUTE")"

export CONFIG_ENV CONFIG_FILE LOG_LEVEL TUN_IFACE TUN_ADDRESS TUN_STACK STRICT_ROUTE_JSON
export RESOLVE_DESTINATION_JSON ENABLE_DNS_ROUTING_JSON TUN_IPV6_ROUTE_JSON TUN_IPV6_ADDRESS
export REMOTE_DNS REMOTE_DNS_PORT DIRECT_DNS DIRECT_DNS_PORT TEST_URL

python3 - <<'PY'
import base64
import json
import os
import re
import sys
from urllib.parse import parse_qs, unquote, urlparse, urlunparse
from urllib.request import Request, urlopen


raw = os.environ["CONFIG_ENV"].strip()
config_file = os.environ["CONFIG_FILE"]


def fail(message):
    raise SystemExit(f"system-v2ray-tunnel: {message}")


def b64decode_text(value):
    value = value.strip()
    value += "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value.encode()).decode()


def single(params, key, default=None):
    value = params.get(key)
    if not value:
        return default
    return value[-1]


def as_bool(value, default=False):
    if value is None:
        return default
    return str(value).lower() in {"1", "true", "yes", "on"}


def split_host_port(netloc, default_port=None):
    if "@" in netloc:
        userinfo, hostport = netloc.rsplit("@", 1)
    else:
        userinfo, hostport = "", netloc

    if hostport.startswith("["):
        end = hostport.find("]")
        if end == -1:
            fail("invalid IPv6 host")
        host = hostport[1:end]
        rest = hostport[end + 1 :]
        port = int(rest[1:]) if rest.startswith(":") and rest[1:] else default_port
    elif ":" in hostport:
        host, port_text = hostport.rsplit(":", 1)
        port = int(port_text) if port_text else default_port
    else:
        host, port = hostport, default_port

    if not host:
        fail("proxy host is empty")
    if port is None:
        fail("proxy port is missing")
    return userinfo, host, port


def add_tls(outbound, params, enabled):
    if not enabled:
        return
    tls = {
        "enabled": True,
        "server_name": single(params, "sni") or single(params, "peer") or outbound["server"],
    }
    if as_bool(single(params, "allowInsecure")) or as_bool(single(params, "insecure")):
        tls["insecure"] = True
    fingerprint = single(params, "fp") or single(params, "fingerprint")
    if fingerprint:
        tls["utls"] = {"enabled": True, "fingerprint": fingerprint}

    if single(params, "security") == "reality" or single(params, "pbk"):
        reality = {"enabled": True}
        public_key = single(params, "pbk") or single(params, "publicKey")
        short_id = single(params, "sid") or single(params, "shortId")
        if public_key:
            reality["public_key"] = public_key
        if short_id:
            reality["short_id"] = short_id
        tls["reality"] = reality

    outbound["tls"] = tls


def add_transport(outbound, params):
    network = single(params, "type") or single(params, "net")
    if not network or network in {"tcp", "raw"}:
        return

    if network == "ws":
        transport = {"type": "ws"}
        path = single(params, "path")
        host = single(params, "host")
        if path:
            transport["path"] = unquote(path)
        if host:
            transport["headers"] = {"Host": unquote(host)}
        outbound["transport"] = transport
        return

    if network == "grpc":
        service_name = single(params, "serviceName") or single(params, "service_name") or single(params, "path")
        transport = {"type": "grpc"}
        if service_name:
            transport["service_name"] = unquote(service_name)
        outbound["transport"] = transport
        return

    if network == "http":
        outbound["transport"] = {"type": "http"}
        return

    fail(f"unsupported transport type: {network}")


def parse_vless(parsed):
    params = parse_qs(parsed.query, keep_blank_values=True)
    _, host, port = split_host_port(parsed.netloc)
    uuid = unquote(parsed.username or "")
    if not uuid:
        fail("vless UUID is empty")
    outbound = {
        "type": "vless",
        "tag": "proxy",
        "server": host,
        "server_port": port,
        "uuid": uuid,
    }
    flow = single(params, "flow")
    if flow:
        outbound["flow"] = flow
    security = single(params, "security")
    add_tls(outbound, params, security in {"tls", "reality"})
    add_transport(outbound, params)
    return outbound


def parse_trojan(parsed):
    params = parse_qs(parsed.query, keep_blank_values=True)
    _, host, port = split_host_port(parsed.netloc, 443)
    password = unquote(parsed.username or "")
    if not password:
        fail("trojan password is empty")
    outbound = {
        "type": "trojan",
        "tag": "proxy",
        "server": host,
        "server_port": port,
        "password": password,
    }
    add_tls(outbound, params, single(params, "security", "tls") != "none")
    add_transport(outbound, params)
    return outbound


def parse_vmess(raw_link):
    encoded = raw_link[len("vmess://") :]
    try:
        data = json.loads(b64decode_text(encoded))
    except Exception as exc:
        fail(f"invalid vmess link: {exc}")

    outbound = {
        "type": "vmess",
        "tag": "proxy",
        "server": data.get("add"),
        "server_port": int(data.get("port")),
        "uuid": data.get("id"),
        "security": data.get("scy") or data.get("security") or "auto",
        "alter_id": int(data.get("aid") or 0),
    }
    if not outbound["server"] or not outbound["uuid"]:
        fail("vmess server or UUID is empty")

    params = {
        "type": [data.get("net") or "tcp"],
        "security": [data.get("tls") or "none"],
        "sni": [data.get("sni") or data.get("host") or data.get("add")],
        "path": [data.get("path") or ""],
        "host": [data.get("host") or ""],
    }
    add_tls(outbound, params, data.get("tls") == "tls")
    add_transport(outbound, params)
    return outbound


def parse_shadowsocks(raw_link):
    parsed = urlparse(raw_link)
    plugin = parse_qs(parsed.query).get("plugin")
    if plugin:
        fail("shadowsocks plugin links are not supported; provide a full sing-box JSON config")

    userinfo, host, port = split_host_port(parsed.netloc)
    if not userinfo:
        encoded = raw_link[len("ss://") :].split("#", 1)[0].split("?", 1)[0]
        decoded = b64decode_text(encoded)
        match = re.match(r"(?P<method>[^:]+):(?P<password>.+)@(?P<host>[^:]+):(?P<port>\d+)$", decoded)
        if not match:
            fail("invalid shadowsocks link")
        method = match.group("method")
        password = match.group("password")
        host = match.group("host")
        port = int(match.group("port"))
    else:
        decoded_userinfo = unquote(userinfo)
        if ":" not in decoded_userinfo:
            decoded_userinfo = b64decode_text(decoded_userinfo)
        method, password = decoded_userinfo.split(":", 1)

    return {
        "type": "shadowsocks",
        "tag": "proxy",
        "server": host,
        "server_port": port,
        "method": method,
        "password": password,
    }


def parse_simple_auth_proxy(parsed, proxy_type):
    _, host, port = split_host_port(parsed.netloc, 1080 if proxy_type == "socks" else 8080)
    outbound = {
        "type": proxy_type,
        "tag": "proxy",
        "server": host,
        "server_port": port,
    }
    if parsed.username:
        outbound["username"] = unquote(parsed.username)
    if parsed.password:
        outbound["password"] = unquote(parsed.password)
    return outbound


def subscription_candidates(text):
    text = text.strip()
    candidates = []

    for payload in (text,):
        candidates.extend(re.split(r"[\r\n\s]+", payload))
        try:
            decoded = b64decode_text(payload)
        except Exception:
            decoded = ""
        if decoded:
            candidates.extend(re.split(r"[\r\n\s]+", decoded.strip()))

    for item in candidates:
        item = item.strip()
        if not item:
            continue
        if item.startswith(("vless://", "vmess://", "trojan://", "ss://")):
            yield item


def parse_subscription_url(raw_url):
    parsed = urlparse(raw_url)
    download_url = urlunparse(parsed._replace(fragment=""))
    selector = unquote(parsed.fragment or "").strip().lower()
    request = Request(download_url, headers={"User-Agent": "system-v2ray-tunnel/1.0"})
    try:
        with urlopen(request, timeout=20) as response:
            body = response.read(4 * 1024 * 1024).decode("utf-8", "replace")
    except Exception as exc:
        fail(f"failed to download subscription URL: {exc}")

    candidates = list(subscription_candidates(body))
    if selector:
        selected = [
            item for item in candidates
            if selector in unquote(urlparse(item).fragment or "").lower()
        ]
        if selected:
            candidates = selected

    outbounds = []
    for candidate in candidates:
        try:
            outbounds.append(parse_outbound(candidate))
        except (SystemExit, Exception):
            continue

    if outbounds:
        print(f"system-v2ray-tunnel: loaded {len(outbounds)} subscription outbound(s)", file=sys.stderr)
        return outbounds

    fail("subscription URL did not contain a supported vless/vmess/trojan/ss link")


def looks_like_subscription_url(parsed):
    has_proxy_userinfo = bool(parsed.username or parsed.password)
    has_explicit_port = parsed.port is not None
    has_path = bool(parsed.path and parsed.path != "/")
    return not has_proxy_userinfo and (has_path or parsed.fragment) and not has_explicit_port


def parse_outbound(raw_link):
    parsed = urlparse(raw_link)
    scheme = parsed.scheme.lower()
    if scheme == "vless":
        return parse_vless(parsed)
    if scheme == "vmess":
        return parse_vmess(raw_link)
    if scheme == "trojan":
        return parse_trojan(parsed)
    if scheme == "ss":
        return parse_shadowsocks(raw_link)
    if scheme in {"socks", "socks5"}:
        return parse_simple_auth_proxy(parsed, "socks")
    if scheme in {"http", "https"}:
        if looks_like_subscription_url(parsed):
            return parse_subscription_url(raw_link)
        return parse_simple_auth_proxy(parsed, "http")

    fail(
        f"unsupported config scheme '{scheme}'. "
        "Use a subscription URL, vless/vmess/trojan/ss/socks/http link, or full sing-box JSON."
    )


def build_proxy_outbounds(parsed_outbound):
    if isinstance(parsed_outbound, list):
        if not parsed_outbound:
            fail("subscription URL did not contain any usable outbound")
        if len(parsed_outbound) == 1:
            parsed_outbound[0]["tag"] = "proxy"
            return parsed_outbound

        tags = []
        outbounds = []
        for index, outbound in enumerate(parsed_outbound, 1):
            tag = f"proxy-{index}"
            outbound["tag"] = tag
            tags.append(tag)
            outbounds.append(outbound)

        outbounds.append({
            "type": "urltest",
            "tag": "proxy",
            "outbounds": tags,
            "url": os.environ["TEST_URL"],
            "interval": "3m",
            "tolerance": 50,
        })
        return outbounds

    parsed_outbound["tag"] = "proxy"
    return [parsed_outbound]


def build_dns_server(tag, address, port):
    if address.strip().lower() == "local":
        return {"type": "local", "tag": tag}

    return {
        "type": "udp",
        "tag": tag,
        "server": address.strip(),
        "server_port": int(port),
    }


def build_config(parsed_outbound):
    proxy_outbounds = build_proxy_outbounds(parsed_outbound)
    tun_addresses = [os.environ["TUN_ADDRESS"]]
    if json.loads(os.environ["TUN_IPV6_ROUTE_JSON"]):
        tun_addresses.append(os.environ["TUN_IPV6_ADDRESS"])

    route_rules = []
    sniff_rule = {"inbound": "tun-in", "action": "sniff"}
    route_rules.append(sniff_rule)

    if json.loads(os.environ["RESOLVE_DESTINATION_JSON"]):
        route_rules.append({
            "inbound": "tun-in",
            "action": "resolve",
            "server": "remote-dns",
            "strategy": "prefer_ipv4",
        })

    if json.loads(os.environ["ENABLE_DNS_ROUTING_JSON"]):
        route_rules.extend([
            {"protocol": "dns", "action": "hijack-dns"},
            {"port": 53, "action": "hijack-dns"},
        ])

    return {
        "log": {"level": os.environ["LOG_LEVEL"]},
        "dns": {
            "servers": [
                build_dns_server("remote-dns", os.environ["REMOTE_DNS"], os.environ["REMOTE_DNS_PORT"]),
                build_dns_server("direct-dns", os.environ["DIRECT_DNS"], os.environ["DIRECT_DNS_PORT"]),
            ],
            "final": "remote-dns",
            "strategy": "prefer_ipv4",
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": os.environ["TUN_IFACE"],
                "address": tun_addresses,
                "auto_route": True,
                "strict_route": json.loads(os.environ["STRICT_ROUTE_JSON"]),
                "stack": os.environ["TUN_STACK"],
            }
        ],
        "outbounds": [
            *proxy_outbounds,
            {"type": "direct", "tag": "direct"},
            {"type": "block", "tag": "block"},
        ],
        "route": {
            "auto_detect_interface": True,
            "default_domain_resolver": {
                "server": "direct-dns",
                "strategy": "prefer_ipv4",
            },
            "rules": route_rules,
            "final": "proxy",
        },
    }


if raw.startswith("{"):
    try:
        config = json.loads(raw)
    except Exception as exc:
        fail(f"invalid JSON config: {exc}")
else:
    config = build_config(parse_outbound(raw))

with open(config_file, "w", encoding="utf-8") as fh:
    json.dump(config, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

echo "system-v2ray-tunnel: starting sing-box with $CONFIG_FILE" >&2
exec "$SING_BOX_BIN" run -c "$CONFIG_FILE"
