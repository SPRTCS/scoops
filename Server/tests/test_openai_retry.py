"""OpenAI-Engine: vorübergehende Netzfehler (z. B. SSL „bad record mac“) werden wiederholt."""
import os
import sys

os.environ.setdefault("AISBOT_SKIP_CONVEX", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import httpx  # noqa: E402

from aisbot import engine_openai  # noqa: E402
from aisbot.bots import _failure_text  # noqa: E402

engine_openai.RETRY_WAIT = 0


def engine_with(responses):
    calls = []

    def handler(request):
        calls.append(1)
        r = responses[min(len(calls), len(responses)) - 1]
        if isinstance(r, Exception):
            raise r
        return r

    e = engine_openai.OpenAIEngine.__new__(engine_openai.OpenAIEngine)
    e.http = httpx.Client(transport=httpx.MockTransport(handler))
    return e, calls


ssl = httpx.ReadError("[SSL: SSLV3_ALERT_BAD_RECORD_MAC] ssl/tls alert bad record mac (_ssl.c:2580)")
ok = httpx.Response(200, json={"output": []})

# 1. Einmal SSL-Fehler, dann Erfolg
e, calls = engine_with([ssl, ok])
assert e._post("k", {}).status_code == 200 and len(calls) == 2

# 2. 502, dann Erfolg
e, calls = engine_with([httpx.Response(502, json={}), ok])
assert e._post("k", {}).status_code == 200 and len(calls) == 2

# 3. Dauerhaft gestört: nach 3 Versuchen Fehler
e, calls = engine_with([ssl])
try:
    e._post("k", {})
    raise SystemExit("hätte scheitern müssen")
except httpx.ReadError:
    assert len(calls) == 3

# 4. 400 wird nicht wiederholt
e, calls = engine_with([httpx.Response(400, json={"error": {"message": "x"}})])
assert e._post("k", {}).status_code == 400 and len(calls) == 1

# 5. Timeout nach 300 s wird nicht wiederholt
e, calls = engine_with([httpx.ReadTimeout("t")])
try:
    e._post("k", {})
except httpx.ReadTimeout:
    assert len(calls) == 1

# 6. Verständlicher Chat-Text
assert "abgerissen" in _failure_text(ssl)
assert _failure_text(ValueError("x")).startswith("Da ist bei mir etwas schiefgelaufen")

print("ok")
