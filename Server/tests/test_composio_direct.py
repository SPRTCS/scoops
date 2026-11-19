"""Test für vollständige, kompakte Composio-Ergebnisse (Server 1.24, composio_direct.py).

Composio ist komplett gemockt (httpx.MockTransport für die REST-API, ein Fake für den Tool Router), es gibt keine
echten Aufrufe. Eigener Temp-Ordner und Schlüsselbund-Präfix, nie die Produktion.

    cd Server && AISBOT_SKIP_CONVEX=1 ~/.local/share/ais-bot/svc/bin/python tests/test_composio_direct.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="aisbot-direct-test-"))
for k in ("AISBOT_CONFIG", "AISBOT_DATA"):
    os.environ.pop(k, None)
os.environ.update(AISBOT_HOME=str(TMP), AISBOT_EDITION="standard", AISBOT_OFFLINE="1",
                  AISBOT_KEYCHAIN_PREFIX="ais-scoops-directtest-" + os.urandom(3).hex())
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import httpx  # noqa: E402

from aisbot import composio_direct as cd, connections as conn_mod  # noqa: E402
from aisbot.composio_direct import ComposioDirect, compact, is_readonly  # noqa: E402
from aisbot.connections import Connections  # noqa: E402
from aisbot.mcp_client import MCPHub  # noqa: E402

passed = 0


def ok(cond, msg: str) -> None:
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1
    print(f"  ✓ {msg}")


# -- Notion-Testdaten ---------------------------------------------------------------
PROJECT = "11111111-1111-1111-1111-111111111111"
DB = "cace0000-0000-0000-0000-000000000000"


def rt(text):
    return [{"type": "text", "plain_text": text, "text": {"content": text, "link": None}, "href": None,
             "annotations": {"bold": False}}]


def page(pid, title, due, status, parent_task=None, done=False):
    return {
        "object": "page", "id": pid, "created_time": "2026-11-15T19:01:00.000Z", "last_edited_time": "2026-11-15T19:02:00.000Z",
        "created_by": {"object": "user", "id": "u1"}, "last_edited_by": {"object": "user", "id": "u1"},
        "cover": None, "icon": {"type": "emoji", "emoji": "✅"}, "archived": False, "in_trash": False,
        "parent": {"type": "database_id", "database_id": DB}, "public_url": None,
        "url": f"https://www.notion.so/{pid.replace('-', '')}",
        "properties": {
            "Task": {"id": "title", "type": "title", "title": rt(title)},
            "Fälligkeit": {"id": "d", "type": "date", "date": {"start": due, "end": None, "time_zone": None} if due else None},
            "Status": {"id": "s", "type": "status", "status": {"id": "x", "name": status, "color": "default"}},
            "Tags": {"id": "t", "type": "multi_select", "multi_select": [{"id": "1", "name": "MLP", "color": "red"}]},
            "Aufwand": {"id": "a", "type": "select", "select": None},
            "Assignee": {"id": "p", "type": "people", "people": [{"object": "user", "id": "u1", "name": "Arman"}]},
            "Bereich": {"id": "b", "type": "relation", "relation": [{"id": PROJECT}], "has_more": False},
            "Parent-task": {"id": "pt", "type": "relation", "relation": [{"id": parent_task}] if parent_task else [], "has_more": False},
            "KW": {"id": "k", "type": "formula", "formula": {"type": "string", "string": "47"}},
            "Erledigt": {"id": "e", "type": "checkbox", "checkbox": done},
            "Zeit": {"id": "z", "type": "number", "number": 0},
            "Fortschritt": {"id": "r", "type": "rollup", "rollup": {"type": "number", "number": 0.5, "function": "percent"}},
            "Notiz": {"id": "n", "type": "rich_text", "rich_text": []},
        },
    }


PAGES = [page("aaaa0000-0000-0000-0000-000000000001", "Steuern November", "2026-12-12", "geplant"),
         page("aaaa0000-0000-0000-0000-000000000002", "CL VA Aaron", "2026-11-13", "offen",
              parent_task="aaaa0000-0000-0000-0000-000000000001", done=True),
         page("aaaa0000-0000-0000-0000-000000000003", "Ohne Datum", None, "offen")]


# -- Fake Composio (REST) -----------------------------------------------------------
class Fake:
    def __init__(self) -> None:
        self.executes: list[tuple[str, dict]] = []
        self.fail: dict[str, list[int]] = {}  # slug → Statuscodes, die nacheinander zurückkommen
        self.big_rows = 0

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.endswith("/v3/connected_accounts") and request.method == "GET":
            def acc(i, slug, alias):
                return {"id": i, "status": "ACTIVE", "alias": alias, "toolkit": {"slug": slug},
                        "created_at": "2026-11-01T00:00:00Z", "state": {"val": {"displayName": f"{alias or slug}@x.de"}},
                        "auth_config": {"id": "ac_m", "is_composio_managed": True}}
            return httpx.Response(200, json={"items": [acc("ca_n1", "notion", ""), acc("ca_g1", "gmail", "privat"),
                                                       acc("ca_g2", "gmail", "arbeit")]})
        if "/v3.1/tool_router/session/" in path and request.method == "GET":
            return httpx.Response(200, json={"config": {"auth_configs": {}}})
        if path.endswith("/v3/auth_configs"):
            return httpx.Response(200, json={"items": []})
        if "/v3/tools/execute/" in path:
            slug = path.rsplit("/", 1)[1]
            body = json.loads(request.content)
            self.executes.append((slug, body))
            codes = self.fail.get(slug) or []
            if codes:
                code = codes.pop(0)
                return httpx.Response(code, json={"error": {"message": f"Fehler {code}", "slug": "X", "code": 1}})
            if slug == "NOTION_QUERY_DATABASE":
                return httpx.Response(200, json={"successful": True, "error": None, "data": {"response_data": {
                    "object": "list", "results": PAGES, "has_more": True, "next_cursor": "cur-2",
                    "request_id": "r1", "page_or_database": {}, "type": "page_or_database"}}})
            if slug == "NOTION_FETCH_ROW":
                pid = body["arguments"]["page_id"]
                return httpx.Response(200, json={"successful": True, "data": {"page_data": {
                    "object": "page", "id": pid, "properties": {"Name": {"type": "title", "title": rt("AIS Consulting")}}}}})
            if slug == "NOTION_FETCH_DATA":
                rows = [{"object": "page", "id": f"p{i}", "properties": {
                    "Name": {"type": "title", "title": rt(f"Zeile {i} " + "x" * 250)}}} for i in range(self.big_rows)]
                return httpx.Response(200, json={"successful": True, "data": {"response_data": {
                    "results": rows, "has_more": False, "next_cursor": None}}})
            if slug == "GMAIL_FETCH_EMAILS":
                return httpx.Response(200, json={"successful": True, "data": {"messages": [
                    {"messageId": "m1", "threadId": "t1", "subject": "Hallo", "messageText": "Text",
                     "payload": {"body": {"data": "QUJD" * 100}}, "labelIds": [], "attachmentList": []}],
                    "nextPageToken": None}})
            if slug == "NOTION_GET_ABOUT_ME":
                return httpx.Response(200, json={"successful": False, "error": "Notion: unauthorized", "data": {}})
            return httpx.Response(404, json={"error": {"message": f"Tool {slug} not found", "slug": "Tool_ToolNotFound",
                                                       "code": 2401}})
        return httpx.Response(404, json={"error": {"message": "unbekannt"}})


class FakeRouter:
    """Tool Router: merkt sich Aufrufe und liefert je Werkzeug eine volle Antwort oder nur eine Vorschau."""

    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.preview: set[str] = set()

    def __call__(self, args: dict):
        self.calls.append(json.loads(json.dumps(args)))
        results = []
        for i, t in enumerate(args["tools"]):
            slug = t["tool_slug"]
            if slug in self.preview:
                resp = {"successful": True, "data_preview": {"results": [{"properties": {"Fälligkeit": {"date": "{object}"}}}],
                                                             "...": "98 more items"}}
            else:
                resp = {"successful": True, "data": {"ok": True, "slug": slug, "url": "https://x", "icon": None}}
            results.append({"response": resp, "tool_slug": slug, "index": i, "structure_info": {"x": 1}})
        data = {"results": results, "total_count": len(results)}
        if self.preview & {t["tool_slug"] for t in args["tools"]}:
            data["remote_file_info"] = {"file_path": "/mnt/files/mex/a.json", "message": "Complete response was large"}
            data["next_steps"] = "process the remote file"
        return [{"type": "text", "text": json.dumps({"successful": True, "data": data})}]


def setup() -> tuple[ComposioDirect, Fake, FakeRouter]:
    fake = Fake()
    conn_mod._key = lambda: "test-key"  # noqa: SLF001 – Schlüsselbund im Test ersetzen
    c = Connections(lambda: {"composio_session_id": "trs_test", "composio_user_id": "scoops-test"})
    c.http = httpx.Client(transport=httpx.MockTransport(fake.handler))
    return ComposioDirect(c), fake, FakeRouter()


def run(direct: ComposioDirect, router: FakeRouter, tools: list[dict], **extra) -> dict:
    out = direct.multi_execute({"tools": tools, "sync_response_to_workbench": True, **extra}, router)
    return json.loads(out[0]["text"])


def test_readonly() -> None:
    print("Lesend oder nicht")
    for s in ("NOTION_QUERY_DATABASE", "NOTION_FETCH_DATA", "NOTION_FETCH_BLOCK_CONTENTS", "GMAIL_FETCH_EMAILS",
              "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", "GOOGLECALENDAR_EVENTS_LIST", "GOOGLECALENDAR_FIND_EVENT",
              "GITHUB_GET_A_REPOSITORY", "NOTION_SEARCH_NOTION_PAGE", "GMAIL_LIST_THREADS"):
        ok(is_readonly(s), f"{s} gilt als lesend")
    for s in ("NOTION_UPDATE_PAGE", "NOTION_CREATE_NOTION_PAGE", "GMAIL_SEND_EMAIL", "NOTION_ARCHIVE_NOTION_PAGE",
              "GITHUB_GET_OR_CREATE_LABEL", "SNOWFLAKE_RUN_QUERY", "GMAIL_REPLY_TO_THREAD", "NOTION_INSERT_ROW_DATABASE",
              "GOOGLEDRIVE_DOWNLOAD_FILE", "SLACK_LIST_AND_DELETE", "GOOGLECALENDAR_QUICK_ADD", ""):
        ok(not is_readonly(s), f"{s or '(leer)'} gilt nicht als lesend")
    ok(is_readonly("ONE_DRIVE_LIST_FILES", ["one_drive"]), "App-Slug mit Unterstrich wird erkannt")


def test_direct_notion() -> None:
    print("Lesend: direkt per REST, vollständig und kompakt")
    direct, fake, router = setup()
    d = run(direct, router, [{"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {"database_id": DB, "page_size": 100}}])
    ok(router.calls == [], "Tool Router wird für lesende Werkzeuge nicht gebraucht")
    q = [b for s, b in fake.executes if s == "NOTION_QUERY_DATABASE"]
    ok(len(q) == 1, "genau eine Ausführung (nichts doppelt)")
    ok(q[0] == {"user_id": "scoops-test", "connected_account_id": "ca_n1", "version": "latest",
                "arguments": {"database_id": DB, "page_size": 100}}, "gleicher User, gleiches Konto, gleiche Argumente")
    r = d["results"][0]
    rows = r["data"]["results"]
    ok(d["successful"] and r["successful"] and len(rows) == 3, "alle Zeilen kommen an")
    a, b, c = rows
    ok(a["id"] == PAGES[0]["id"], "Seiten-ID bleibt")
    ok(a["Task"] == "Steuern November" and a["Fälligkeit"] == "2026-12-12" and a["Status"] == "geplant",
       "Titel, Datum, Status als einfache Werte")
    ok(a["Tags"] == ["MLP"] and a["Assignee"] == ["Arman"] and a["KW"] == "47", "multi_select, people, formula")
    ok(a["Fortschritt"] == 0.5 and a["Zeit"] == 0 and a["Erledigt"] is False and b["Erledigt"] is True,
       "rollup, number 0 und checkbox bleiben")
    ok(a["Bereich"] == ["AIS Consulting"], "Verknüpfung auf fremde Seite: Titel nachgeschlagen")
    ok(b["Parent-task"] == ["Steuern November"], "Verknüpfung innerhalb des Ergebnisses: Titel ohne Abruf")
    ok(len([s for s, _ in fake.executes if s == "NOTION_FETCH_ROW"]) == 1, "nur die unbekannte Seite nachgeschlagen")
    ok("Fälligkeit" not in c and "Aufwand" not in a and "Notiz" not in a, "leere Eigenschaften fehlen (nichts erfunden)")
    text = json.dumps(d, ensure_ascii=False)
    ok(all(x not in text for x in ("notion.so", "emoji", "created_by", "request_id", "database_id", "annotations")),
       "keine URLs, Icons, created_by, Metadaten")
    ok("next_cursor" in r["data"] and "cur-2" in r["hinweis"] and "3 Zeilen" in r["hinweis"],
       "ehrlicher Hinweis auf weitere Seiten mit next_cursor")
    d2 = run(direct, router, [{"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {"database_id": DB}}])
    ok(len([s for s, _ in fake.executes if s == "NOTION_FETCH_ROW"]) == 1 and
       d2["results"][0]["data"]["results"][0]["Bereich"] == ["AIS Consulting"], "Titel zwischengespeichert")


def test_mixed_and_writes() -> None:
    print("Schreibend: nur über den Tool Router, Reihenfolge bleibt")
    direct, fake, router = setup()
    d = run(direct, router, [{"tool_slug": "NOTION_UPDATE_PAGE", "arguments": {"page_id": "x"}},
                             {"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {"database_id": DB}},
                             {"tool_slug": "GMAIL_FETCH_EMAILS", "arguments": {}, "account": "arbeit"}],
            thought="t", current_step="S")
    ok([t["tool_slug"] for t in router.calls[0]["tools"]] == ["NOTION_UPDATE_PAGE"], "nur das schreibende Werkzeug an den Router")
    ok(router.calls[0]["thought"] == "t" and router.calls[0]["current_step"] == "S", "übrige Felder bleiben erhalten")
    ok(not any(s == "NOTION_UPDATE_PAGE" for s, _ in fake.executes), "schreibendes Werkzeug nie per REST")
    ok([r["tool_slug"] for r in d["results"]] == ["NOTION_UPDATE_PAGE", "NOTION_QUERY_DATABASE", "GMAIL_FETCH_EMAILS"],
       "Ergebnisse in der ursprünglichen Reihenfolge")
    ok(d["results"][0]["data"] == {"ok": True, "slug": "NOTION_UPDATE_PAGE"}, "Router-Ergebnis kompaktiert (url/icon weg)")
    g = [b for s, b in fake.executes if s == "GMAIL_FETCH_EMAILS"]
    ok(g and g[0]["connected_account_id"] == "ca_g2", "Konto über Alias „arbeit“ gewählt")
    m = d["results"][2]["data"]["messages"][0]
    ok(m["threadId"] == "t1" and m["messageId"] == "m1", "Mail-IDs bleiben (für Antworten nötig)")
    ok("Binärdaten" in json.dumps(m, ensure_ascii=False), "Base64-Daten ersetzt")


def test_preview_paths() -> None:
    print("Vorschau: nachholen oder klarer Hinweis")
    direct, fake, router = setup()
    router.preview = {"GMAIL_FETCH_EMAILS"}
    d = run(direct, router, [{"tool_slug": "GMAIL_FETCH_EMAILS", "arguments": {}}])
    ok(len(router.calls) == 1, "mehrere Gmail-Konten ohne Angabe: der Tool Router entscheidet")
    ok(not fake.executes or all(s != "GMAIL_FETCH_EMAILS" for s, _ in fake.executes), "kein Raten des Kontos")
    ok("hinweis" in d and "nur eine Vorschau" in d["hinweis"] and "nichts aus früheren Nachrichten" in d["hinweis"],
       "klarer Hinweis: nichts zusammenbauen")
    ok("/mnt/files/mex/a.json" in d["hinweis"] and "vorschau" in d["results"][0], "Vorschau als solche markiert")

    direct, fake, router = setup()
    router.preview = {"NOTION_QUERY_DATABASE"}
    fake.fail["NOTION_QUERY_DATABASE"] = [503]  # erst Ausfall → Router (Vorschau) → nachholen klappt
    d = run(direct, router, [{"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {"database_id": DB}}])
    ok(len(router.calls) == 1, "REST-Ausfall: weiter über den Tool Router")
    ok(len([s for s, _ in fake.executes if s == "NOTION_QUERY_DATABASE"]) == 2, "Vorschau → vollständig nachgeholt")
    ok("hinweis" not in d and len(d["results"][0]["data"]["results"]) == 3 and "vorschau" not in d["results"][0],
       "nachgeholt: vollständige Daten, kein Vorschau-Hinweis")

    direct, fake, router = setup()
    router.preview = {"NOTION_UPDATE_PAGE"}
    d = run(direct, router, [{"tool_slug": "NOTION_UPDATE_PAGE", "arguments": {"page_id": "x"}}])
    ok(not fake.executes or all(s != "NOTION_UPDATE_PAGE" for s, _ in fake.executes),
       "Vorschau bei schreibendem Werkzeug: nie erneut ausführen")
    ok("hinweis" in d, "… aber Hinweis")


def test_fallbacks() -> None:
    print("Fehler und Rückfall")
    direct, fake, router = setup()
    d = run(direct, router, [{"tool_slug": "NOTION_GET_UNKNOWN_THING", "arguments": {}}])
    ok(len(router.calls) == 1 and d["results"][0]["successful"], "Werkzeug per REST unbekannt → Tool Router")
    direct, fake, router = setup()
    d = run(direct, router, [{"tool_slug": "NOTION_GET_ABOUT_ME", "arguments": {}}])
    ok(router.calls == [] and not d["successful"] and "unauthorized" in d["results"][0]["error"],
       "Werkzeugfehler kommt ehrlich zurück (kein doppelter Versuch)")
    direct, fake, router = setup()
    d = run(direct, router, [{"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {}, "account": "gibtsnicht"}])
    ok(len(router.calls) == 1, "unbekanntes Konto → Tool Router (der meldet es)")


def test_limit() -> None:
    print("Obergrenze")
    direct, fake, router = setup()
    fake.big_rows = 400
    d = run(direct, router, [{"tool_slug": "NOTION_FETCH_DATA", "arguments": {}}])
    size = len(json.dumps(d, ensure_ascii=False, separators=(",", ":")))
    r = d["results"][0]
    n = len(r["data"]["results"])
    ok(size <= cd.LIMIT, f"Antwort {size} ≤ {cd.LIMIT} Zeichen")
    ok(50 < n < 400 and f"{n} von 400 Zeilen" in r["hinweis"], f"ehrlicher Hinweis „{n} von 400 Zeilen“")


def test_compact_generic() -> None:
    print("Generisches Kompaktieren")
    v = compact({"a": None, "b": "", "c": [], "d": {}, "e": {"f": 1}, "url": "https://x", "iconLink": "https://y",
                 "htmlLink": "https://z", "keep": False, "archived": False, "n": 0, "items": [{"x": None}, {"id": "1"}]})
    ok(v == {"e.f": 1, "keep": False, "n": 0, "items": [{"id": "1"}]}, f"leer/URL weg, flach, Werte bleiben: {v}")
    ok(compact("Wort " * 1400).endswith("insgesamt 7000 Zeichen]"), "sehr lange Texte gekürzt mit Hinweis")


def test_hub() -> None:
    print("MCPHub")

    class Srv:
        def __init__(self) -> None:
            self.calls = []

        def call(self, tool, args):
            self.calls.append((tool, args))
            return FakeRouter()(args) if "tools" in args else "OK"

    hub = MCPHub()
    srv = Srv()
    hub.servers["composio"] = srv
    direct, fake, _ = setup()
    hub.composio_direct = direct
    out = hub.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                   {"tools": [{"tool_slug": "NOTION_QUERY_DATABASE", "arguments": {"database_id": DB}}],
                    "sync_response_to_workbench": False})
    ok(srv.calls == [] and json.loads(out[0]["text"])["results"][0]["successful"], "Hub nutzt die Direktausführung")
    try:
        hub.call("composio__COMPOSIO_MULTI_EXECUTE_TOOL", {"tools": [{"tool_slug": "GMAIL_SEND_EMAIL", "arguments": {}}]})
        ok(False, "Mail senden muss blockiert sein")
    except RuntimeError as e:
        ok("mail_vorbereiten" in str(e), "Mails senden bleibt gesperrt")
    hub.call("composio__COMPOSIO_SEARCH_TOOLS", {"queries": []})
    ok(srv.calls[-1][0] == "COMPOSIO_SEARCH_TOOLS", "andere Composio-Werkzeuge unverändert")


def main() -> None:
    test_readonly()
    test_direct_notion()
    test_mixed_and_writes()
    test_preview_paths()
    test_fallbacks()
    test_limit()
    test_compact_generic()
    test_hub()
    print(f"\nAlle {passed} Prüfungen bestanden.")


if __name__ == "__main__":
    main()
