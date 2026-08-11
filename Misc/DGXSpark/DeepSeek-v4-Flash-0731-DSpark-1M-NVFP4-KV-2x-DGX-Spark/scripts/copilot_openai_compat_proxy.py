#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import time

UPSTREAM = os.environ.get("UPSTREAM_BASE", "http://aitopatom-ad9e:8888").rstrip("/")
LISTEN_HOST = os.environ.get("PROXY_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("PROXY_PORT", "8899"))
TIMEOUT_SEC = float(os.environ.get("PROXY_TIMEOUT_SEC", "180"))


def _flatten_content(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        out = []
        for item in value:
            if isinstance(item, dict):
                if item.get("type") == "text" and isinstance(item.get("text"), str):
                    out.append(item["text"])
                elif isinstance(item.get("content"), str):
                    out.append(item["content"])
            elif isinstance(item, str):
                out.append(item)
        return "".join(out)
    return str(value)


def _normalize_chat_response(obj):
    if not isinstance(obj, dict):
        return obj
    choices = obj.get("choices")
    if not isinstance(choices, list):
        return obj

    for ch in choices:
        if not isinstance(ch, dict):
            continue
        msg = ch.get("message")
        if not isinstance(msg, dict):
            msg = {}
            ch["message"] = msg

        content = _flatten_content(msg.get("content"))
        if not content.strip():
            reasoning = msg.get("reasoning_content")
            reasoning_text = _flatten_content(reasoning)
            if reasoning_text.strip():
                content = reasoning_text

        if not content.strip() and isinstance(ch.get("delta"), dict):
            delta_text = _flatten_content(ch["delta"].get("content"))
            if delta_text.strip():
                content = delta_text

        if not content.strip() and isinstance(msg.get("tool_calls"), list) and msg.get("tool_calls"):
            content = "Tool calls were returned without assistant text."

        msg["role"] = msg.get("role") or "assistant"
        msg["content"] = content

    return obj


def _ensure_choices_contract(payload, model_name="deepseek-v4-flash-dspark"):
    """Return a response object that always contains OpenAI-style choices."""
    if not isinstance(payload, dict):
        payload = {
            "id": f"chatcmpl-proxy-{int(time.time())}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model_name,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": str(payload)},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
        return payload

    model_name = payload.get("model") or model_name
    choices = payload.get("choices")
    if isinstance(choices, list) and len(choices) > 0:
        return payload

    fallback_text = ""
    err = payload.get("error")
    if isinstance(err, dict):
        fallback_text = str(err.get("message") or "")
    if not fallback_text:
        fallback_text = str(payload.get("message") or "")
    if not fallback_text:
        fallback_text = "No assistant content was returned by upstream."

    payload["id"] = payload.get("id") or f"chatcmpl-proxy-{int(time.time())}"
    payload["object"] = payload.get("object") or "chat.completion"
    payload["created"] = payload.get("created") or int(time.time())
    payload["model"] = model_name
    payload["choices"] = [
        {
            "index": 0,
            "message": {"role": "assistant", "content": fallback_text},
            "finish_reason": "stop",
        }
    ]
    if "usage" not in payload:
        payload["usage"] = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    return payload


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "copilot-openai-compat/1.0"

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _proxy(self):
        print(f"[proxy] {self.command} {self.path}", flush=True)
        length = int(self.headers.get("Content-Length", "0"))
        req_body = self.rfile.read(length) if length > 0 else b""
        target = f"{UPSTREAM}{self.path}"

        # Copilot built-in wrapper can request streamed/tool-call responses that
        # are valid at protocol level but not rendered in the UI for this model.
        # Normalize request shape to plain non-stream assistant text.
        if self.path.startswith("/v1/chat/completions") and req_body:
            try:
                payload = json.loads(req_body.decode("utf-8"))
                if isinstance(payload, dict):
                    payload["stream"] = False
                    payload["tool_choice"] = "none"
                    # vLLM rejects stream_options unless stream=True.
                    if payload.get("stream") is False:
                        payload.pop("stream_options", None)
                    payload.pop("tools", None)
                    payload.pop("parallel_tool_calls", None)
                    req_body = json.dumps(payload).encode("utf-8")
                    print(
                        f"[proxy] normalized request stream={payload.get('stream')} tool_choice={payload.get('tool_choice')} has_stream_options={'stream_options' in payload}",
                        flush=True,
                    )
            except Exception as e:
                print(f"[proxy] request normalize skipped: {e}", flush=True)

        forward_headers = {
            "Content-Type": self.headers.get("Content-Type", "application/json"),
            "Accept": "application/json",
        }
        auth = self.headers.get("Authorization")
        if auth:
            forward_headers["Authorization"] = auth

        req = Request(target, data=req_body, headers=forward_headers, method="POST")
        try:
            with urlopen(req, timeout=TIMEOUT_SEC) as resp:
                raw = resp.read()
                ctype = resp.headers.get("Content-Type", "application/json")
                status = resp.getcode()
                print(f"[proxy] upstream status={status} content_type={ctype}", flush=True)
        except HTTPError as e:
            raw = e.read() if hasattr(e, "read") else b""
            try:
                payload = json.loads(raw.decode("utf-8")) if raw else {"error": {"message": str(e)}}
            except Exception:
                payload = {"error": {"message": str(e), "raw": raw.decode("utf-8", errors="replace")}}
            self._send_json(e.code, payload)
            return
        except URLError as e:
            self._send_json(502, {"error": {"message": f"upstream unreachable: {e}"}})
            return
        except Exception as e:
            self._send_json(500, {"error": {"message": f"proxy error: {e}"}})
            return

        if self.path.startswith("/v1/chat/completions") and "application/json" in ctype:
            try:
                payload = json.loads(raw.decode("utf-8"))
                payload = _normalize_chat_response(payload)
                payload = _ensure_choices_contract(payload)
                content_len = 0
                if isinstance(payload, dict) and isinstance(payload.get("choices"), list) and payload["choices"]:
                    msg = payload["choices"][0].get("message", {}) if isinstance(payload["choices"][0], dict) else {}
                    content = msg.get("content", "") if isinstance(msg, dict) else ""
                    if isinstance(content, str):
                        content_len = len(content)
                print(f"[proxy] normalized chat response status={status} choices={len(payload.get('choices', []))} content_len={content_len}", flush=True)
                self._send_json(status, payload)
                return
            except Exception as e:
                fallback_payload = _ensure_choices_contract({"error": {"message": f"proxy normalization failed: {e}"}})
                print(f"[proxy] fallback chat response due to normalization error: {e}", flush=True)
                self._send_json(200, fallback_payload)
                return

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        self._proxy()

    def do_GET(self):
        print(f"[proxy] {self.command} {self.path}", flush=True)
        # Minimal pass-through for /v1/models and health checks.
        target = f"{UPSTREAM}{self.path}"
        req = Request(target, headers={"Accept": "application/json"}, method="GET")
        try:
            with urlopen(req, timeout=TIMEOUT_SEC) as resp:
                raw = resp.read()
                ctype = resp.headers.get("Content-Type", "application/json")
                status = resp.getcode()
        except HTTPError as e:
            raw = e.read() if hasattr(e, "read") else b""
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        except Exception as e:
            self._send_json(502, {"error": {"message": f"upstream unreachable: {e}"}})
            return

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    print(f"compat proxy listening on http://{LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}")
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    httpd.serve_forever()
