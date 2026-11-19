"""OpenAI-Engine: Fällt der Rechner aus (kein Bildschirmfoto), läuft der Scoop weiter statt abzubrechen."""
import os
import sys

os.environ.setdefault("AISBOT_SKIP_CONVEX", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from aisbot import engine_openai as eo  # noqa: E402
from aisbot.computer import ComputerError  # noqa: E402


class Dead:
    def screenshot_png(self):
        raise ComputerError("screenshot: keine Antwort nach 30 s")


class Alive:
    def screenshot_png(self):
        return b"\x89PNG"


e = eo.OpenAIEngine.__new__(eo.OpenAIEngine)
cc = lambda i: {"type": "computer_call", "call_id": f"c{i}", "actions": []}  # noqa: E731

# 1. Fehlschlag → leeres Bild + Hinweis, kein Abbruch
inp = []
assert e._computer_calls([cc(1)], inp, lambda: Dead(), lambda s: None) is None
assert inp[0]["type"] == "computer_call_output" and inp[0]["output"]["image_url"] == eo._BLANK_PNG
assert inp[-1]["role"] == "user" and "nicht vom Nutzer" in inp[-1]["content"][0]["text"]
# interne Markierung geht nicht an die API
assert all("_failed" not in i for i in eo._api_input(inp)) and inp[0].get("_failed")

# 2. Zwei Aufrufe in einer Antwort: Hinweis erst nach beiden Ausgaben
inp = []
e._computer_calls([cc(1), cc(2)], inp, lambda: Dead(), lambda s: None)
assert [i.get("type") for i in inp] == ["computer_call_output", "computer_call_output", None]

# 3. Kein Rechner verfügbar → ebenfalls weiter
def no_computer():
    raise ComputerError("kein Rechner verbunden")
inp = []
assert e._computer_calls([cc(1)], inp, no_computer, lambda s: None) is None

# 4. Dreimal hintereinander kein Bild → freundlicher Stopp
inp = []
r = None
for i in range(3):
    r = e._computer_calls([cc(i)], inp, lambda: Dead(), lambda s: None)
assert r and "antwortet gerade nicht" in r

# 5. Ein gutes Bild dazwischen setzt den Zähler zurück
inp = []
e._computer_calls([cc(1)], inp, lambda: Dead(), lambda s: None)
e._computer_calls([cc(2)], inp, lambda: Dead(), lambda s: None)
assert e._computer_calls([cc(3)], inp, lambda: Alive(), lambda s: None) is None
assert e._computer_calls([cc(4)], inp, lambda: Dead(), lambda s: None) is None

print("ok")
