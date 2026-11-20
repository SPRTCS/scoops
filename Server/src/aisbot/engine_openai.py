"""Agenten-Schleife für OpenAI-Modelle (Responses API): GPT-6 Luna, 6.1 Terra, 6.2 Sol, 6.2 Astra (Modellkatalog).

Gleiche Werkzeuge wie bei Claude (eigene Server-Werkzeuge, Team App/Composio über den MCP-Hub,
Websuche). Den Bot-Rechner bedient ein OpenAI-Scoop selbst mit OpenAIs eingebautem Werkzeug
`computer` (Screenshot → Aktionen → Screenshot). Notfall-Schalter: config.json
`openai_native_computer: false` → alter Weg über `bildschirm_aufgabe` (Claude-Teilaufgabe).
"""

from __future__ import annotations

import base64
import json
import re
import os
import subprocess
import threading
import time
from types import SimpleNamespace
from typing import Callable

import httpx

from .config import UsageBook
from .i18n import N_, translate, tx
from .engine import (HANDOFF_HINT, MAX_NUDGES, NUDGE, Engine, ExtraTool, Outcome, announces_action, handoff_due, hands_off,
                     mcp_line, status_line)

from . import models_catalog as _catalog  # noqa: E402

OPENAI_MODELS = _catalog.LiveIds("openai")
# Eskalation nach Stärke (Rang im Modellkatalog): Luna → Terra → Sol → Astra; abgelöste Kennungen wie ihr Nachfolger
ESCALATE = _catalog.LiveMap(lambda c: {k: n for k in [*c.ids, *c.replaced] if c.provider_of(k) == "openai"
                                       for n in [c.next_stronger(k)] if n})
SCREEN_MODEL = "claude-sonnet-5-5"  # bedient den Bot-Rechner für OpenAI-Scoops
URL = "https://api.openai.com/v1/responses"
MAX_SCREEN_FAILS = 3  # so oft hintereinander kein Bildschirmfoto → Lauf freundlich beenden
RETRIES, RETRY_WAIT = 2, 1.5  # vorübergehende Netzfehler: bis zu 2 Wiederholungen (1,5 s, 3 s)
# Kein ReadTimeout: Nach 300 s wartet niemand gern noch einmal so lange.
_TRANSIENT = (httpx.ConnectError, httpx.ReadError, httpx.WriteError, httpx.RemoteProtocolError, httpx.PoolTimeout,
              httpx.ConnectTimeout)


# Statuszeilen der Computer-Aktionen (übersetzt erst bei der Ausgabe, i18n.translate)
COMPUTER_STATUS = {"click": N_("Klickt"), "double_click": N_("Klickt doppelt"), "drag": N_("Zieht"),
                   "move": N_("Bewegt die Maus"), "scroll": N_("Scrollt"), "keypress": N_("Drückt Tasten"),
                   "type": N_("Tippt"), "wait": N_("Wartet kurz"), "screenshot": N_("Schaut auf den Bildschirm")}
# Serverseitige Compaction der Responses-API (context_management, Typ "compaction"): Ab dieser Eingabegröße fasst
# OpenAI den Verlauf zu einem verschlüsselten Compaction-Element zusammen, das wir wie jede Ausgabe weiterreichen.
COMPACT_THRESHOLD = 120_000
MAX_STEPS = 120  # Schrittgrenze eines Chat-Laufs (vorher 40); die Kostengrenze `budget` bremst zusätzlich
KEEP_SCREENSHOTS = 4  # ältere Bildschirmfotos im Verlauf durch einen Platzhalter ersetzen (spart Kosten)
_BLANK_PNG = ("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")


def _xy(a: dict) -> list[int]:
    return [int(a.get("x", 0)), int(a.get("y", 0))]


def _keyname(k) -> str:
    # OpenAI schickt Großbuchstaben („CMD“, „T“); ein großes „T“ würde Umschalt+T auslösen
    k = str(k)
    return k.lower() if len(k) == 1 else k


def _mods(keys) -> str | None:
    return "+".join(_keyname(k) for k in keys) if keys else None


def run_computer_action(c, a: dict) -> None:
    """Führt eine Aktion aus OpenAIs computer_call auf dem Bot-Rechner aus."""
    t = a.get("type")
    if t == "click":
        btn = a.get("button", "left")
        if btn in ("back", "forward"):
            c.key("cmd+[" if btn == "back" else "cmd+]")
        else:
            kind = {"left": "left_click", "right": "right_click", "wheel": "middle_click"}.get(btn, "left_click")
            c.click(kind, _xy(a), _mods(a.get("keys")))
    elif t == "double_click":
        c.click("double_click", _xy(a), _mods(a.get("keys")))
    elif t == "move":
        c.move(*_xy(a))
    elif t == "drag":
        pts = [[int(p["x"]), int(p["y"])] if isinstance(p, dict) else [int(p[0]), int(p[1])] for p in a.get("path", [])]
        if len(pts) >= 2:
            c._with_modifiers(_mods(a.get("keys")), lambda: c.cmd("drag", path=pts))
    elif t == "scroll":
        c.move(*_xy(a))
        # OpenAI: positive Werte = nach unten/rechts in Pixeln; Cua: Rasten, positiv = nach oben
        dy = -round(int(a.get("scroll_y", 0)) / 100) or (0 if not a.get("scroll_y") else (-1 if a["scroll_y"] > 0 else 1))
        dx = round(int(a.get("scroll_x", 0)) / 100) or (0 if not a.get("scroll_x") else (1 if a["scroll_x"] > 0 else -1))
        c._with_modifiers(_mods(a.get("keys")), lambda: c.cmd("scroll", x=dx, y=dy))
    elif t == "keypress":
        keys = a.get("keys") or []
        if keys:
            c.key("+".join(_keyname(k) for k in keys))
    elif t == "type":
        c.type_text(a.get("text", ""))
    elif t == "wait":
        time.sleep(2)
    # "screenshot": nichts zu tun, das Bild kommt ohnehin zurück


def is_openai(model: str) -> bool:
    return model in OPENAI_MODELS or model.startswith("gpt-")


def _native_computer_enabled() -> bool:
    import os
    try:
        from .profile import CONFIG_PATH
        cfg = json.load(open(CONFIG_PATH))
    except (OSError, ValueError):
        return True
    return cfg.get("openai_native_computer", True)


def _key() -> str:
    from .profile import kc, keychain_get
    key = os.environ.get("OPENAI_API_KEY") or keychain_get(kc("openai"), "api-key")
    if not key:
        raise RuntimeError(tx("Kein OpenAI-Schlüssel im Schlüsselbund ({service})", service=kc("openai")))
    return key


def _to_input(messages: list[dict]) -> list[dict]:
    """Claude-Nachrichtenformat → Responses-API-Eingabe."""
    items = []
    for m in messages:
        content = m["content"] if isinstance(m["content"], list) else [{"type": "text", "text": m["content"]}]
        parts = []
        for b in content:
            t = b.get("type")
            if t == "text" and b.get("text"):
                parts.append({"type": "output_text" if m["role"] == "assistant" else "input_text", "text": b["text"]})
            elif t == "image" and m["role"] == "user":
                src = b["source"]
                parts.append({"type": "input_image", "image_url": f"data:{src['media_type']};base64,{src['data']}"})
            elif t == "document" and m["role"] == "user":
                src = b["source"]
                parts.append({"type": "input_file", "filename": "anhang.pdf",
                              "file_data": f"data:{src['media_type']};base64,{src['data']}"})
        if parts:
            items.append({"role": m["role"], "content": parts})
    return items


def _instructions(system) -> str:
    if isinstance(system, str):
        return system
    return "\n\n".join(b.get("text", "") for b in system if b.get("type") == "text")


def _fn(schema: dict) -> dict:
    params = schema.get("input_schema") or {"type": "object", "properties": {}}
    d = {"type": "function", "name": schema["name"][:64], "description": (schema.get("description") or "")[:1024],
         "parameters": params}
    # Die Responses-API behandelt Funktionen ohne Angabe als strict: Dann werden ALLE Felder Pflicht, und das Modell
    # füllt optionale Felder mit Platzhaltern (z. B. apple_home: verriegeln=false, modus="aus" beim Licht ausschalten).
    # Darum immer ausdrücklich setzen; strict nur, wo das Schema dafür gebaut ist.
    d["strict"] = bool(schema.get("strict"))
    return d


class OpenAIEngine:
    def __init__(self, claude_engine: Engine):
        self.claude = claude_engine
        self.http = httpx.Client(timeout=httpx.Timeout(300, connect=15))

    def _post(self, key: str, body: dict, cancel: threading.Event | None = None) -> httpx.Response:
        """POST an die Responses-API mit Wiederholung bei kurzen Netzstörungen.

        Abgerissene oder gestörte TLS-Verbindungen (z. B. „SSLV3_ALERT_BAD_RECORD_MAC“, Verbindung zurückgesetzt)
        und 502/503/504 sind fast immer vorübergehend; eine Wiederholung ist sicher, weil Werkzeuge erst nach der
        Antwort laufen. Das Anthropic-SDK macht das schon selbst, hier fehlte es."""
        for attempt in range(RETRIES + 1):
            last = attempt == RETRIES or bool(cancel and cancel.is_set())
            try:
                r = self.http.post(URL, headers={"Authorization": f"Bearer {key}"}, json=body)
            except _TRANSIENT as e:
                if last:
                    raise
                print(f"OpenAI: Verbindung gestört ({type(e).__name__}: {e}), Versuch {attempt + 2}", flush=True)
            else:
                if r.status_code not in (502, 503, 504) or last:
                    return r
                print(f"OpenAI: {r.status_code}, Versuch {attempt + 2}", flush=True)
            time.sleep(RETRY_WAIT * (attempt + 1))
        raise AssertionError("unerreichbar")

    def run(
        self,
        *,
        system,
        messages: list[dict],
        model: str,
        escalation_model: str | None = None,
        effort: str = "low",
        work_effort: str | None = "medium",
        extra_tools: list[ExtraTool] | None = None,
        mcp_hub=None,
        budget: float = 1.0,
        max_steps: int = MAX_STEPS,
        holder: str = "cli",
        on_line: Callable[[str], None] | None = None,
        cancel: threading.Event | None = None,
        hub=None,
        allow_computer: bool = True,
        allow_web: bool = True,
        checkpoint: Callable[[list], None] | None = None,
        resume_input: list | None = None,
        on_usage: Callable | None = None,
        compact_threshold: int | None = COMPACT_THRESHOLD,
        **_ignored,
    ) -> Outcome:
        """`resume_input`: gespeicherte Eingabe eines abgebrochenen Laufs (Responses-Format); `messages` enthält dann nur
        die neuen Nachrichten seither. `checkpoint(inp)` bekommt nach jedem Schritt die aktuelle Eingabe."""
        hub = hub or self.claude.hub  # Rechner des Scoops (Standard: Bot-Rechner)
        key = _key()
        extra = {t.schema["name"]: t for t in (extra_tools or [])}
        usage = UsageBook()
        lines: list[str] = []
        escalation = ESCALATE.get(model) if escalation_model else None
        native_computer = bool(_native_computer_enabled()) and allow_computer
        state = {"computer": None, "used": False}

        def get_computer():
            if state["computer"] is None:
                if hub.holder and hub.holder != holder:
                    line(tx("Wartet, bis der Bot-Rechner frei ist"))
                state["computer"] = hub.acquire(holder, cancel)
                state["used"] = True
            return state["computer"]

        def line(s: str) -> None:
            if not s:  # Kleinigkeiten (z. B. „reagieren“) erscheinen nicht als Arbeitsschritt
                return
            lines.append(s)
            if on_line:
                on_line(s)

        # MCP: häufige Werkzeuge direkt, der Rest über eine eigene Suche (OpenAI hat keine verzögerte Werkzeugliste).
        hub_schemas = mcp_hub.tool_schemas() if mcp_hub else []
        direct_mcp = [s for s in hub_schemas if not s.get("defer_loading")]
        deferred = {s["name"]: s for s in hub_schemas if s.get("defer_loading")}

        def app_suchen(i: dict) -> str:
            q = [w for w in i["suche"].lower().split() if len(w) > 2]
            scored = []
            for n, s in deferred.items():
                text = (n + " " + s.get("description", "")).lower()
                score = sum(text.count(w) for w in q)
                if score:
                    scored.append((score, n, s))
            scored.sort(key=lambda x: -x[0])
            if not scored:
                return "Kein passendes Werkzeug gefunden. Andere Suchbegriffe versuchen."
            return "\n\n".join(f"{n}: {s.get('description', '')[:300]}\nParameter: {json.dumps(s['input_schema'], ensure_ascii=False)[:1200]}"
                               for _, n, s in scored[:6])

        def app_nutzen(i: dict):
            name = i["name"]
            if name not in deferred and not any(s["name"] == name for s in direct_mcp):
                return "Unbekanntes Werkzeug. Erst mit app_werkzeug_suchen suchen."
            try:
                args = json.loads(i.get("argumente_json") or "{}")
            except json.JSONDecodeError:
                return "argumente_json ist kein gültiges JSON."
            srv, _, tname = name.partition("__")
            line(mcp_line(srv, tname, args))
            return mcp_hub.call(name, args)

        def bildschirm(i: dict) -> str:
            state["used"] = True
            line(tx("Arbeitet am Bildschirm"))
            w, h = hub.screen_size()
            from .prompts import base_rules
            sub = self.claude.run(
                system="Du bist ein Helfer, der für einen anderen Assistenten eine Teilaufgabe auf dem Mac erledigt.\n\n"
                       + base_rules(w, h) + "\n\nAntworte am Ende knapp mit dem Ergebnis (was du gesehen/getan hast).",
                messages=[{"role": "user", "content": i["auftrag"]}], model=SCREEN_MODEL, escalation_model=None,
                effort="medium", budget=min(budget, 1.0), holder=holder, on_line=line, cancel=cancel, hub=hub)
            for m, u in sub.usage.by_model.items():
                for _ in range(1):
                    usage.by_model.setdefault(m, u.__class__(m))
                    tgt = usage.by_model[m]
                    for f in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "requests", "web_searches"):
                        setattr(tgt, f, getattr(tgt, f) + getattr(u, f))
            return sub.final_text or f"(keine Antwort, Status {sub.stop_reason})"

        local = {
            "app_werkzeug_suchen": ({"name": "app_werkzeug_suchen", "description":
                                     "Sucht weitere Werkzeuge der verbundenen Apps (Team App, Gmail, Notion …) nach Stichworten.",
                                     "input_schema": {"type": "object", "properties": {"suche": {"type": "string"}},
                                                      "required": ["suche"], "additionalProperties": False}, "strict": True},
                                    app_suchen, N_("Sucht das passende Werkzeug")),
            "app_werkzeug_nutzen": ({"name": "app_werkzeug_nutzen", "description":
                                     "Führt ein mit app_werkzeug_suchen gefundenes Werkzeug aus. argumente_json = Argumente als JSON-Text.",
                                     "input_schema": {"type": "object", "properties": {"name": {"type": "string"},
                                                                                       "argumente_json": {"type": "string"}},
                                                      "required": ["name", "argumente_json"], "additionalProperties": False},
                                     "strict": True}, app_nutzen, None),
            "bildschirm_aufgabe": ({"name": "bildschirm_aufgabe", "description":
                                    "Erledigt eine Aufgabe auf deinem eigenen Mac (Bildschirm, Browser, Programme, Terminal), "
                                    "z. B. eine Webseite bedienen oder etwas auf X vorbereiten. auftrag = vollständige Beschreibung.",
                                    "input_schema": {"type": "object", "properties": {"auftrag": {"type": "string"}},
                                                     "required": ["auftrag"], "additionalProperties": False}, "strict": True},
                                   bildschirm, None),
        }
        tools = [{"type": "web_search"}] if allow_web else []
        tools += [_fn(t.schema) for t in extra.values()]
        tools += [_fn(s) for s in direct_mcp]
        if deferred:
            tools += [_fn(local["app_werkzeug_suchen"][0]), _fn(local["app_werkzeug_nutzen"][0])]
        if native_computer:
            tools.append({"type": "computer"})
        elif allow_computer:
            tools.append(_fn(local["bildschirm_aufgabe"][0]))

        def esc_tool() -> list[dict]:
            if not escalation:
                return []
            return [{"type": "function", "name": "eskalieren", "strict": True,
                     "description": "Übergibt an ein stärkeres Modell, wenn die Aufgabe komplex ist oder du feststeckst.",
                     "parameters": {"type": "object", "properties": {"grund": {"type": "string"}}, "required": ["grund"],
                                    "additionalProperties": False}}]

        inp = list(resume_input) + _to_input(messages) if resume_input is not None else _to_input(messages)
        instructions = _instructions(system)
        if native_computer:
            instructions += ("\n\nDeinen Mac bedienst du direkt mit dem Werkzeug computer (Bildschirmfoto ansehen, klicken, tippen, "
                             "Tasten). Fang mit einem Bildschirmfoto an, wenn du den Bildschirm brauchst.")
        final_text, stop_reason, step = "", "", 0
        nudges, handed_off = 0, False
        tool_steps, hinted = 0, False
        try:
            while step < max_steps:
                if cancel and cancel.is_set():
                    stop_reason = "stopped"
                    break
                step += 1
                body = {"model": model, "instructions": instructions, "input": _api_input(inp), "tools": tools + esc_tool(),
                        "reasoning": {"effort": effort}, "store": False, "include": ["reasoning.encrypted_content"]}
                if compact_threshold:
                    body["context_management"] = [{"type": "compaction", "compact_threshold": compact_threshold}]
                r = self._post(key, body, cancel)
                d = r.json()
                if r.status_code != 200:
                    raise RuntimeError(f"OpenAI {r.status_code}: {d.get('error', {}).get('message', d)}")
                u = d.get("usage") or {}
                det = u.get("input_tokens_details") or {}
                cached = det.get("cached_tokens", 0) or 0
                written = det.get("cache_write_tokens", 0) or 0
                usage.add(model, SimpleNamespace(input_tokens=max(0, (u.get("input_tokens") or 0) - cached - written),
                                                 output_tokens=u.get("output_tokens") or 0, cache_read_input_tokens=cached,
                                                 cache_creation_input_tokens=written, server_tool_use=None))
                if on_usage:
                    on_usage(usage)
                out = d.get("output", [])
                inp += out
                if any("compaction" in str(o.get("type", "")) for o in out):
                    line(tx("Fasst den bisherigen Verlauf zusammen"))
                    _prune_before_compaction(inp)
                calls = [o for o in out if o.get("type") == "function_call"]
                handed_off = handed_off or any(hands_off(c.get("name", "")) for c in calls)
                ccalls = [o for o in out if o.get("type") == "computer_call"]
                for o in out:
                    if o.get("type") == "web_search_call":
                        line(tx("Sucht im Web"))
                        usage.by_model[model].web_searches += 1
                if ccalls and not allow_computer:
                    final_text, stop_reason = tx("Der Rechner ist in diesem Lauf nicht freigegeben."), "end_turn"
                    break
                if ccalls:
                    blocked = self._computer_calls(ccalls, inp, get_computer, line)
                    if blocked:
                        final_text, stop_reason = blocked, "end_turn"
                        break
                    if work_effort and effort != work_effort:
                        effort = work_effort
                if not calls and not ccalls:
                    final_text = "\n\n".join(_with_citations(c) for o in out if o.get("type") == "message"
                                             for c in o.get("content", []) if c.get("type") == "output_text").strip()
                    stop_reason = "end_turn"
                    if nudges < MAX_NUDGES and not handed_off and announces_action(final_text):
                        nudges += 1
                        inp.append({"role": "user", "content": [{"type": "input_text", "text": NUDGE}]})
                        continue
                    break
                if work_effort and effort != work_effort:
                    effort = work_effort  # schnell antworten, beim Arbeiten gründlicher denken
                for c in calls:
                    name = c["name"]
                    try:
                        args = json.loads(c.get("arguments") or "{}")
                    except json.JSONDecodeError:
                        args = {}
                    try:
                        if name == "eskalieren" and escalation:
                            line(tx("Holt sich Verstärkung"))
                            model, escalation = escalation, ESCALATE.get(escalation)
                            res = f"Übergeben. Du bist jetzt {model}."
                        elif name in extra:
                            ex = extra[name]
                            if ex.status:
                                line(ex.status(args))
                            res = ex.handler(args)
                        elif name == "bildschirm_aufgabe" and not allow_computer:
                            res = "Fehler: Der Rechner ist in diesem Lauf nicht freigegeben."
                        elif name in local:
                            _, fn, st = local[name]
                            if st:
                                line(translate(st))
                            res = fn(args)
                        elif mcp_hub and mcp_hub.owns(name):
                            srv, _, tname = name.partition("__")
                            line(mcp_line(srv, tname, args))
                            res = mcp_hub.call(name, args)
                        else:
                            line(status_line(name, args))
                            res = f"Unbekanntes Werkzeug {name}"
                    except Exception as e:  # noqa: BLE001
                        print(f"Werkzeugfehler {name}: {str(e)[:300]}", flush=True)
                        res = f"Fehler: {e}"
                    if isinstance(res, list):
                        res = "\n".join(b.get("text", "(Bild)") if b.get("type") == "text" else "(Bild)" for b in res)
                    inp.append({"type": "function_call_output", "call_id": c["call_id"], "output": str(res)[:60000]})
                tool_steps += len(calls) + len(ccalls)
                if handoff_due(tool_steps, extra, handed_off, hinted):
                    hinted = True
                    inp.append({"role": "user", "content": [{"type": "input_text", "text": HANDOFF_HINT.format(n=tool_steps)}]})
                if checkpoint:
                    checkpoint(inp)
                if usage.dollars >= budget:
                    final_text = tx("Ich habe abgebrochen, weil die Kostengrenze von {budget:.2f} $ für diese Aufgabe "
                                    "erreicht ist.", budget=budget)
                    stop_reason = "budget"
                    break
            else:
                final_text = tx("Ich habe nach {steps} Schritten abgebrochen.", steps=max_steps)
                stop_reason = "max_steps"
        finally:
            if state["computer"] is not None:
                hub.release()
        if checkpoint:
            checkpoint(inp)
        return Outcome(final_text, stop_reason, usage, lines, state["used"], model, step, inp)

    @staticmethod
    def _computer_failed(cc: dict, inp: list, checks: list, why: str) -> str:
        """Computer-Aktion ohne Bildschirmfoto beantworten (leeres Bild); der Hinweis folgt nach allen Ausgaben."""
        out = {"type": "computer_call_output", "call_id": cc["call_id"], "_failed": True,
               "output": {"type": "computer_screenshot", "detail": "original", "image_url": _BLANK_PNG}}
        if checks:
            out["acknowledged_safety_checks"] = checks
        inp.append(out)
        return why

    def _computer_calls(self, ccalls: list[dict], inp: list, get_computer, line) -> str | None:
        """Führt OpenAIs computer_call-Aktionen aus und hängt die Bildschirmfotos an. Gibt bei einer
        ernsten Sicherheitswarnung von OpenAI einen Text zurück (dann stoppt der Lauf)."""
        problems: list[str] = []
        for cc in ccalls:
            checks = cc.get("pending_safety_checks") or []
            serious = [ch for ch in checks if ch.get("code") not in ("irrelevant_domain",)]
            if serious:
                msgs = "; ".join(ch.get("message") or ch.get("code", "") for ch in serious)
                return tx("Ich habe am Bildschirm angehalten, weil OpenAI eine Sicherheitswarnung meldet: "
                          "{warnings}. Soll ich trotzdem weitermachen?", warnings=msgs)
            actions = cc.get("actions") or ([cc["action"]] if cc.get("action") else [])
            try:
                c = get_computer()
            except Exception as e:  # noqa: BLE001 – kein Rechner erreichbar: dem Modell melden statt abbrechen
                problems.append(self._computer_failed(cc, inp, checks, f"Der Rechner ist nicht erreichbar: {e}"))
                continue
            for a in actions:
                kind = a.get("type")
                st = translate(COMPUTER_STATUS[kind]) if kind in COMPUTER_STATUS else tx("Arbeitet am Bildschirm")
                if a.get("type") == "type":
                    st = tx("Tippt „{text}“", text=str(a.get("text", ""))[:30])
                line(st)
                try:
                    run_computer_action(c, a)
                except Exception as e:  # noqa: BLE001
                    print(f"Werkzeugfehler computer {a.get('type')}: {str(e)[:300]}", flush=True)
                if a.get("type") in ("click", "double_click", "keypress", "type", "drag"):
                    time.sleep(0.4)  # der Oberfläche kurz Zeit geben
            try:
                png = c.screenshot_png()
            except Exception as e:  # noqa: BLE001 – z. B. „keine Antwort nach 30 s“: weiterarbeiten lassen
                print(f"Werkzeugfehler computer screenshot: {str(e)[:300]}", flush=True)
                problems.append(self._computer_failed(cc, inp, checks, f"Das Bildschirmfoto ist fehlgeschlagen: {e}"))
                continue
            out = {"type": "computer_call_output", "call_id": cc["call_id"],
                   "output": {"type": "computer_screenshot", "detail": "original",
                              "image_url": "data:image/png;base64," + base64.b64encode(png).decode()}}
            if checks:
                out["acknowledged_safety_checks"] = checks
            inp.append(out)
        if problems:  # nach allen computer_call_outputs: dem Modell sagen, was los ist, damit es weitermacht
            inp.append({"role": "user", "content": [{"type": "input_text", "text": (
                f"[System, nicht vom Nutzer] {problems[-1]} Das Bild eben ist leer. Versuch es noch einmal mit einem "
                "Bildschirmfoto; klappt es weiter nicht, mach ohne Bildschirm weiter (z. B. mit anderen Werkzeugen) "
                "oder sag dem Nutzer kurz, dass der Rechner gerade nicht reagiert.")}]})
        # Mehrmals hintereinander kein Bild: nicht endlos weiterprobieren
        fails = 0
        for i in reversed(inp):
            if isinstance(i, dict) and i.get("type") == "computer_call_output":
                if not i.get("_failed"):
                    break
                fails += 1
        if fails >= MAX_SCREEN_FAILS:
            return tx("Der Rechner antwortet gerade nicht (mehrmals kein Bildschirmfoto). "
                      "Ich habe deshalb angehalten. Sag Bescheid, sobald er wieder erreichbar ist, dann mache ich weiter.")
        # Nur die letzten Bildschirmfotos behalten
        shots = [i for i in inp if isinstance(i, dict) and i.get("type") == "computer_call_output"]
        for old in shots[:-KEEP_SCREENSHOTS]:
            old["output"]["image_url"] = _BLANK_PNG
        return None


def _prune_before_compaction(inp: list) -> None:
    """Alles vor dem jüngsten Compaction-Element weglassen (laut OpenAI optional, hält Anfragen und Speicher klein)."""
    for i in range(len(inp) - 1, -1, -1):
        if isinstance(inp[i], dict) and "compaction" in str(inp[i].get("type", "")):
            if i:
                del inp[:i]
            return


def _api_input(inp: list) -> list:
    """Eingabe ohne interne Markierungen (die API lehnt unbekannte Felder wie „_failed“ ab)."""
    return [{k: v for k, v in i.items() if k != "_failed"} if isinstance(i, dict) and "_failed" in i else i
            for i in inp]


# Quellenmarken der Websuche: OpenAI schreibt sie als Private-Use-Zeichen in den Text
# (z. B. „\ue200cite\ue202turn1search4\ue201“). Die echten Links stehen in `annotations` (url_citation).
_CITE_MARK = re.compile(r"\s*\ue200.*?\ue201")


def _domain(url: str) -> str:
    from urllib.parse import urlparse
    host = urlparse(url).netloc.lower()
    return host[4:] if host.startswith("www.") else host or tx("Quelle")


def _with_citations(content: dict) -> str:
    """Text mit klickbaren Markdown-Links statt roher Quellenmarken."""
    text = content.get("text", "") or ""
    cites = [a for a in content.get("annotations") or [] if a.get("type") == "url_citation" and a.get("url")]
    urls: list[str] = []
    for a in cites:
        if a["url"] not in urls:
            urls.append(a["url"])
    marks = list(_CITE_MARK.finditer(text))
    if marks and cites and len(marks) == len(cites):
        # Marke k gehört zu Annotation k → an Ort und Stelle als Link
        parts, last = [], 0
        for m, a in zip(marks, cites):
            parts.append(text[last:m.start()])
            parts.append(f" ([{_domain(a['url'])}]({a['url']}))")
            last = m.end()
        parts.append(text[last:])
        return "".join(parts)
    text = _CITE_MARK.sub("", text)
    if urls and not any(u in text for u in urls):
        text += "\n\n" + tx("Quellen: {links}", links=" · ".join(f"[{_domain(u)}]({u})" for u in urls[:8]))
    return text
