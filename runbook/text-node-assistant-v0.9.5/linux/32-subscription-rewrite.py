#!/usr/bin/env python3
"""Local-only subscription adapter for CDN XHTTP profiles.

3x-ui quite correctly stores the XHTTP inbound as ``security=none`` because
TLS is terminated by Nginx.  Its generic subscription exporter cannot infer
that the public client endpoint needs TLS, SNI and Host, so this tiny adapter
repairs only XHTTP links before returning the subscription.  It never listens
on a public address and never logs request paths, subscription IDs or bodies.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import re
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen


STATE_FILE = "/root/.config/text-node-assistant/cdn-xhttp.env"
ENV_FILE = "/etc/text-node-assistant/subscription-proxy.env"
DEFAULT_UPSTREAM_PORT = 2096
MAX_BODY = 2 * 1024 * 1024
DOMAIN_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")
PATH_RE = re.compile(r"^/[0-9a-f]{32}/$")


def read_kv_file(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        with open(path, "r", encoding="utf-8") as stream:
            for raw in stream:
                line = raw.rstrip("\r\n")
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key] = value
    except OSError:
        pass
    return values


def runtime_config() -> tuple[str, str, int, str]:
    env = read_kv_file(ENV_FILE)
    state = read_kv_file(STATE_FILE)
    subscription_host = env.get("SUBSCRIPTION_HOST", "")
    xhttp_domain = state.get("XHTTP_DOMAIN", "")
    xhttp_path = state.get("XHTTP_PATH", "")
    try:
        xhttp_port = int(state.get("XHTTP_PUBLIC_PORT", "8443"))
    except ValueError:
        xhttp_port = 8443
    if not DOMAIN_RE.fullmatch(subscription_host):
        raise RuntimeError("subscription host is not configured")
    if not DOMAIN_RE.fullmatch(xhttp_domain):
        raise RuntimeError("XHTTP public domain is not configured")
    if not PATH_RE.fullmatch(xhttp_path):
        raise RuntimeError("XHTTP path is not configured")
    if not 1 <= xhttp_port <= 65535:
        raise RuntimeError("XHTTP public port is invalid")
    return subscription_host, xhttp_domain, xhttp_port, xhttp_path


def _protocol_text(value: str) -> bool:
    return bool(re.search(r"(?:^|\n)(?:vless|vmess|trojan|ss|hysteria2?)://", value, re.I))


def decode_subscription(body: bytes) -> tuple[str, bool]:
    text = body.decode("utf-8-sig", errors="strict").strip()
    if _protocol_text(text):
        return text, False
    compact = re.sub(r"\s+", "", text)
    if not compact:
        raise ValueError("empty subscription")
    compact += "=" * ((4 - len(compact) % 4) % 4)
    try:
        decoded = base64.b64decode(compact, altchars=b"-_", validate=False)
        decoded_text = decoded.decode("utf-8-sig", errors="strict").strip()
    except (binascii.Error, UnicodeDecodeError, ValueError) as exc:
        raise ValueError("subscription is neither plain text nor base64") from exc
    if not _protocol_text(decoded_text):
        raise ValueError("decoded subscription contains no supported links")
    return decoded_text, True


def encode_subscription(text: str, was_base64: bool) -> bytes:
    payload = text.strip().encode("utf-8")
    return base64.b64encode(payload) if was_base64 else payload + b"\n"


def _set_query(query: list[tuple[str, str]], key: str, value: str) -> None:
    query[:] = [(name, item) for name, item in query if name.lower() != key.lower()]
    query.append((key, value))


def rewrite_link(link: str, xhttp_domain: str, xhttp_port: int, xhttp_path: str) -> tuple[str, bool]:
    if not link.lower().startswith("vless://"):
        return link, False
    try:
        parts = urlsplit(link)
        query = parse_qsl(parts.query, keep_blank_values=True)
    except ValueError:
        return link, False
    lookup = {name.lower(): value for name, value in query}
    link_type = lookup.get("type", "").lower()
    mode = lookup.get("mode", "").lower()
    if link_type != "xhttp" and mode != "packet-up":
        return link, False
    _set_query(query, "encryption", "none")
    _set_query(query, "security", "tls")
    _set_query(query, "sni", xhttp_domain)
    _set_query(query, "fp", "chrome")
    _set_query(query, "type", "xhttp")
    _set_query(query, "host", xhttp_domain)
    _set_query(query, "path", xhttp_path)
    _set_query(query, "mode", "packet-up")
    # The public endpoint is represented by the external proxy metadata, but
    # generic exporters may preserve the loopback address/port.  Always
    # converge an XHTTP link to the current external domain and port; Reality
    # and direct links never enter this branch.
    userinfo = ""
    if "@" in parts.netloc:
        userinfo = parts.netloc.rsplit("@", 1)[0] + "@"
    host_part = xhttp_domain
    if ":" in host_part and not host_part.startswith("["):
        host_part = f"[{host_part}]"
    rewritten = urlunsplit((parts.scheme, f"{userinfo}{host_part}:{xhttp_port}", parts.path, urlencode(query), parts.fragment))
    return rewritten, True


def rewrite_subscription(text: str, xhttp_domain: str, xhttp_port: int, xhttp_path: str) -> tuple[str, int]:
    lines = text.splitlines()
    changed = 0
    output: list[str] = []
    for line in lines:
        candidate = line.strip()
        if candidate.lower().startswith("vless://"):
            rewritten, did_change = rewrite_link(candidate, xhttp_domain, xhttp_port, xhttp_path)
            output.append(rewritten)
            changed += int(did_change)
        else:
            output.append(line)
    return "\n".join(output), changed


class Handler(BaseHTTPRequestHandler):
    server_version = "TextNodeSubscription/1"

    def log_message(self, _format: str, *_args: object) -> None:
        # Request paths contain the subscription credential.  Deliberately do
        # not emit access logs to stdout/journald.
        return

    def _send(self, status: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-TNA-Subscription-Rewrite", "xhttp-tls-v1")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)

    def do_HEAD(self) -> None:  # noqa: N802
        self._handle()

    def do_GET(self) -> None:  # noqa: N802
        self._handle()

    def do_POST(self) -> None:  # noqa: N802
        self._send(HTTPStatus.METHOD_NOT_ALLOWED, b"method not allowed\n")

    def _handle(self) -> None:
        split = urlsplit(self.path)
        if not split.path.startswith("/sub/") or ".." in split.path:
            self._send(HTTPStatus.NOT_FOUND, b"not found\n")
            return
        try:
            subscription_host, xhttp_domain, xhttp_port, xhttp_path = runtime_config()
            upstream = f"http://127.0.0.1:{DEFAULT_UPSTREAM_PORT}{split.path}"
            if split.query:
                upstream += "?" + split.query
            request = Request(
                upstream,
                headers={
                    "Host": subscription_host,
                    "Accept": "text/plain, */*",
                    "User-Agent": "TextNodeAssistant-subscription-proxy/1",
                },
            )
            with urlopen(request, timeout=15) as response:
                raw = response.read(MAX_BODY + 1)
                if len(raw) > MAX_BODY:
                    raise ValueError("subscription response is too large")
            text, was_base64 = decode_subscription(raw)
            rewritten, changed = rewrite_subscription(text, xhttp_domain, xhttp_port, xhttp_path)
            if changed == 0:
                # A node without XHTTP is valid; preserving it is safer than
                # fabricating a profile.  The header still tells diagnostics
                # that the adapter was reached.
                rewritten = text
            self._send(HTTPStatus.OK, encode_subscription(rewritten, was_base64))
        except HTTPError as exc:
            self._send(exc.code, b"upstream subscription unavailable\n")
        except (URLError, OSError, RuntimeError, ValueError, UnicodeError, json.JSONDecodeError):
            self._send(HTTPStatus.BAD_GATEWAY, b"subscription rewrite unavailable\n")


def main() -> int:
    bind = os.environ.get("TNA_SUBSCRIPTION_BIND", "127.0.0.1")
    port_text = os.environ.get("TNA_SUBSCRIPTION_PORT", "2097")
    try:
        port = int(port_text)
    except ValueError:
        print("invalid subscription proxy port", file=sys.stderr)
        return 2
    if bind not in {"127.0.0.1", "::1"} or not 1 <= port <= 65535:
        print("subscription proxy must bind localhost", file=sys.stderr)
        return 2
    server = ThreadingHTTPServer((bind, port), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
