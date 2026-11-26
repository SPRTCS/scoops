"""Ankündigen statt Handeln: Endet ein Zug mit „ich schaue jetzt nach …“ ohne Werkzeug, schickt der Server den
Scoop einmal (höchstens zweimal) weiter. Nach einer Freigabe/Aufgabe gilt „ich melde mich, sobald …“ als korrekt.

    cd Server && AISBOT_SKIP_CONVEX=1 uv run python tests/test_nudge.py
"""
import os
import sys
from types import SimpleNamespace as NS

os.environ.setdefault("AISBOT_SKIP_CONVEX", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from aisbot.engine import (HANDOFF_AFTER, NUDGE, ComputerHub, Engine, ExtraTool, after_nudges,  # noqa: E402
                           announces_action, handoff_due)

passed = 0


def ok(cond, msg):
    global passed
    assert cond, msg
    passed += 1
    print(f"  ✓ {msg}")


USAGE = NS(input_tokens=1, output_tokens=1, cache_read_input_tokens=0, cache_creation_input_tokens=0, server_tool_use=None)


def text(t):
    return NS(type="text", text=t)


def tool(name, inp=None):
    return NS(type="tool_use", id=f"tu_{name}", name=name, input=inp or {})


class FakeClient:
    def __init__(self, replies):
        self.replies, self.sent = list(replies), []
        self.beta = NS(messages=NS(create=self.create))

    def create(self, **kw):
        self.sent.append([m for m in kw["messages"]])
        content, stop = self.replies.pop(0)
        return NS(content=content, stop_reason=stop, usage=USAGE)


def run(replies, tools=()):
    c = FakeClient(replies)
    e = Engine(ComputerHub(), client=c)
    out = e.run(system="s", messages=[{"role": "user", "content": "Poste das bitte"}], allow_computer=False,
                allow_web=False, escalation_model=None, extra_tools=list(tools), compact_trigger=None)
    nudged = sum(1 for m in c.sent[-1] if m["role"] == "user" and isinstance(m["content"], list)
                 and any(b.get("text") == NUDGE for b in m["content"] if isinstance(b, dict)))
    return out, c, nudged


print("Erkennung")
ok(announces_action("Ich schaue jetzt in Dia nach, welcher Account aktiv ist."), "„ich schaue jetzt nach“")
ok(announces_action("Ich melde mich, sobald ich den Account bestätigt habe."), "„ich melde mich, sobald“")
ok(not announces_action("Soll ich jetzt posten?"), "Frage an Arman zählt nicht")
ok(not announces_action("Erledigt, ich habe es gepostet."), "Ergebnis zählt nicht")
ok(not announces_action("Ja, ab jetzt prüfe ich jede Meldung an der Originalquelle."), "„ab jetzt prüfe ich“ ist eine Regel, keine Ankündigung")
ok(not announces_action("Ich prüfe ab sofort jede Quelle selbst. Von jetzt an prüfe ich auch die Daten."), "„ab sofort“, „von jetzt an“")
DIGEST = ("Ich schaue jetzt nach, ob es Neues gibt. " + "Meldung mit Quelle und Prüfung. " * 20
          + "Nichts gepostet, für eine Veröffentlichung brauche ich deine Freigabe.")
ok(not announces_action(DIGEST), "Ankündigung nur am Anfang eines langen Inhalts zählt nicht")
ok(announces_action("Hier der Stand. " * 40 + "Ich poste das jetzt auf X."), "Ankündigung am Ende eines langen Texts zählt")

print("Inhalt vor dem Nachhaken bleibt erhalten (Digest 22.11.)")
LONG = "KI-Digest. " + "Geprüfte Meldung mit Quelle. " * 15 + "Ich melde mich, sobald es Neues gibt."
ok(after_nudges([LONG], "OK") == LONG.strip(), "„OK“ → der Digest bleibt die Antwort")
ok(after_nudges([LONG], "Ich habe nichts angekündigt.") == LONG.strip() + "\n\nIch habe nichts angekündigt.",
   "Antwort aufs Nachhaken kommt dazu, ersetzt aber nicht")
ok(after_nudges(["Ich schaue jetzt nach."], "@x ist aktiv.") == "@x ist aktiv.", "bloße Ankündigung fällt weg")
ok(after_nudges(["Ich prüfe das gleich."], "ok.") == "Ich prüfe das gleich.", "nur „OK“ → nicht leer")
ok(after_nudges([], "Fertig.") == "Fertig.", "ohne Nachhaken unverändert")

print("Claude-Engine")
looked = []
peek = ExtraTool(schema={"name": "nachsehen", "description": "x", "input_schema": {"type": "object", "properties": {}}},
                 handler=lambda i: looked.append(1) or "Account @beispielkonto aktiv")
out, c, n = run([([text("Ich schaue jetzt nach, welcher Account aktiv ist.")], "end_turn"),
                 ([tool("nachsehen")], "tool_use"),
                 ([text("@beispielkonto ist aktiv. Soll ich posten?")], "end_turn")], [peek])
ok(n == 1 and looked and out.final_text.startswith("@beispielkonto ist aktiv"), "Ankündigung → weitergeschickt, handelt, echtes Ergebnis")
out, c, n = run([([text(LONG)], "end_turn"), ([text("OK")], "end_turn")])
ok(n == 1 and out.final_text == LONG.strip(), "Engine: Digest mit Ankündigung am Ende, Antwort „OK“ → Digest bleibt stehen")
out, c, n = run([([text("Ich prüfe das gleich.")], "end_turn")] * 3)
ok(n == 2 and len(c.sent) == 3, "höchstens zweimal weitergeschickt, dann Schluss")
out, c, n = run([([text("Erledigt.")], "end_turn")])
ok(n == 0 and len(c.sent) == 1, "normale Antwort: kein zusätzlicher Zug")
ask = ExtraTool(schema={"name": "freigabe_anfordern", "description": "x", "input_schema": {"type": "object", "properties": {}}},
                handler=lambda i: "Freigabe angefragt")
out, c, n = run([([tool("freigabe_anfordern")], "tool_use"),
                 ([text("Ich melde mich, sobald du freigegeben hast.")], "end_turn")], [ask])
ok(n == 0 and len(c.sent) == 2, "nach Freigabe-Anfrage ist „ich melde mich, sobald …“ in Ordnung")


print("Viele Schritte → Hinweis „Gib den Rest als Aufgabe ab“ (1.22)")


def hints(c):
    return sum(1 for m in c.sent[-1] if m["role"] == "user" and isinstance(m["content"], list)
               and any(isinstance(b, dict) and b.get("type") == "text" and "aufgabe_starten" in b.get("text", "")
                       for b in m["content"]))


starter = ExtraTool(schema={"name": "aufgabe_starten", "description": "x", "input_schema": {"type": "object", "properties": {}}},
                    handler=lambda i: "Aufgabe gestartet")
many = [([tool("nachsehen")], "tool_use")] * (HANDOFF_AFTER + 3) + [([text("Fertig.")], "end_turn")]
out, c, _ = run(many, [peek, starter])
ok(hints(c) == 1, "nach vielen Schritten genau ein Hinweis")
ok(len(c.sent) == HANDOFF_AFTER + 4 and out.final_text == "Fertig.", "weich: der Lauf geht normal weiter")
out, c, _ = run(many, [peek])
ok(hints(c) == 0, "ohne aufgabe_starten (Gast, Aufgabe selbst) kein Hinweis")
out, c, _ = run([([tool("nachsehen")], "tool_use")] * (HANDOFF_AFTER - 2) + [([text("Fertig.")], "end_turn")], [peek, starter])
ok(hints(c) == 0, "wenige Schritte: kein Hinweis")
ok(not handoff_due(HANDOFF_AFTER, {"aufgabe_starten": 1}, True, False), "nach einer Abgabe kein Hinweis mehr")
ok(handoff_due(HANDOFF_AFTER, {"aufgabe_starten": 1}, False, False), "ab der Schwelle fällig")

print(f"\n{passed} Prüfungen bestanden")
