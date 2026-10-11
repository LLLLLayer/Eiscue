#!/usr/bin/env python3
"""Loopback-only deterministic SSE provider for App integration tests; no real model."""
import argparse
import json
import time
from threading import Event
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def message_text(message):
    content = message.get("content", "")
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if p.get("type") == "text")
    return content


stream_release = Event()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/fixture/release-stream":
            stream_release.set()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"fixture ready")

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        size = int(self.headers.get("Content-Length", 0))
        if size > 2_000_000:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(size))
        users = [m for m in body.get("messages", []) if m.get("role") == "user"]
        content = message_text(users[-1]) if users else ""
        failures = {
            "unauthorized fixture": (401, "Fixture authentication failed", "invalid_api_key"),
            "unavailable fixture": (503, "Fixture service unavailable", "server_error"),
        }
        if content in failures:
            status, message, error_type = failures[content]
            # A deliberately fake key exercises redaction. Never echo request
            # credentials, which may come from a caller outside the UI tests.
            payload = json.dumps({"error": {
                "message": message + "; rejected credential: local-fixture-key",
                "type": error_type,
                "code": str(status),
            }}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        answer = "Fixture response: " + content
        markdown = ("# Markdown title\n\nParagraph **bold** with [link](https://example.com).\n\n"
                    "- First item\n- Second item\n\n> Quoted text\n\n"
                    "```swift\nlet answer = 42\n```\n\n"
                    "| Name | Value |\n| --- | ---: |\n| One | 1 |")
        if content == "markdown rendering fixture":
            answer = markdown
        if content == "streaming ui fixture":
            answer = "Streaming response arrived incrementally and is now complete."
        timeline = content in ("timeline fixture", "timeline no prose fixture")
        tool_results = [m for m in body.get("messages", []) if m.get("role") == "tool"]
        if timeline and tool_results:
            if not any(message_text(m) == "Fixture document content" for m in tool_results):
                self.send_error(400, "Expected the real fixture tool result")
                return
            answer = "File inspection finished.\n\n" + markdown
        elif timeline:
            if not any(t.get("function", {}).get("name") == "fixture_read_file" for t in body.get("tools", [])):
                self.send_error(400, "Expected the opt-in timeline test tool")
                return
        if content in ("plain chat fixture", "plain chat follow-up fixture"):
            messages = body.get("messages", [])
            instructions = [message_text(m) for m in messages
                            if m.get("role") in ("system", "developer")]
            # Pi renders AgentChange.instructions as one tagged prompt section.
            expected = ("<instructions>\n"
                        "You are Eiscue. Reply concisely in the user's language.\n"
                        "</instructions>")
            if instructions != [expected]:
                self.send_error(400, "Plain chat must use only the minimal instructions")
                return
            if body.get("tools") or body.get("functions"):
                self.send_error(400, "Plain chat must not expose tools")
                return
            if content == "plain chat follow-up fixture":
                history = [(m.get("role"), message_text(m)) for m in messages
                           if m.get("role") in ("user", "assistant")]
                if history != [("user", "plain chat fixture"),
                               ("assistant", "Fixture response: plain chat fixture"),
                               ("user", "plain chat follow-up fixture")]:
                    self.send_error(400, "Plain chat history must survive relaunch")
                    return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def event(delta, finish=None):
            packet = {"id": "fixture-completion", "object": "chat.completion.chunk",
                      "created": int(time.time()), "model": "fixture-model",
                      "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(packet) + "\n\n").encode())
            self.wfile.flush()

        try:
            event({"role": "assistant", "content": ""})
            if timeline and not tool_results:
                if content == "timeline fixture":
                    event({"content": "I will inspect the file first."})
                event({"tool_calls": [{"index": 0, "id": "fixture-call", "type": "function",
                      "function": {"name": "fixture_read_file", "arguments": ""}}]})
                event({"tool_calls": [{"index": 0, "function": {"arguments": '{"path":"fixture.txt"}'}}]})
                event({}, "tool_calls")
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return
            if content == "streaming ui fixture":
                stream_release.clear()
                event({"content": "Streaming response"})
                stream_release.wait(timeout=30)
                answer = answer[len("Streaming response"):]
            if "slow fixture" in content:
                event({"content": "Waiting for cancellation"})
                time.sleep(15)
            for offset in range(0, len(answer), 8):
                event({"content": answer[offset:offset + 8]})
                time.sleep(0.05)
            event({}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    print(f"Fixture listening on 127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
