#!/usr/bin/env python3
"""Fake-Server für Scoops Connect (nur Standardbibliothek, Python 3.9+).

Simuliert Kopplung (POST /api/nodes/claim) und WebSocket (/api/nodes/link) nach docs/scoops-connect.md
und schickt der App nur HARMLOSE Befehle: get_screen_size, get_cursor_position, screenshot,
run_command `echo ok`, write_bytes/read_bytes in einem Temp-Ordner, ein unbekannter Befehl.
Keine Klicks, Tasten oder Mausbewegungen.

Ablauf:
    python3 fake_server.py --port 8799 --code TEST-2345 [--activity Mila] [--hold 30] [--bye]
    open "AIS Scoops Server.app" --args -fakeserver 8799 -code TEST-2345

Mit --bye schickt der Server am Ende `bye`, die App löscht dann ihr Test-Token wieder.
Exit-Code 0 = alle Prüfungen bestanden.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import secrets
import struct
import sys
import tempfile
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WS:
    """Minimaler WebSocket-Server-Endpunkt (RFC 6455, nur Textframes + Steuerframes)."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.r, self.w = reader, writer
        self.closed = False

    async def send(self, obj) -> None:
        data = json.dumps(obj).encode()
        await self._frame(0x1, data)

    async def _frame(self, opcode: int, data: bytes) -> None:
        head = bytes([0x80 | opcode])
        n = len(data)
        if n < 126:
            head += bytes([n])
        elif n < 65536:
            head += bytes([126]) + struct.pack("!H", n)
        else:
            head += bytes([127]) + struct.pack("!Q", n)
        self.w.write(head + data)
        await self.w.drain()

    async def recv(self):
        """Liefert das nächste Text-JSON oder None bei Verbindungsende."""
        buf = b""
        while True:
            try:
                b1, b2 = await self.r.readexactly(2)
            except (asyncio.IncompleteReadError, ConnectionError):
                self.closed = True
                return None
            fin, opcode = b1 & 0x80, b1 & 0x0F
            masked, n = b2 & 0x80, b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", await self.r.readexactly(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", await self.r.readexactly(8))[0]
            mask = await self.r.readexactly(4) if masked else b"\0\0\0\0"
            payload = bytearray(await self.r.readexactly(n))
            for i in range(n):
                payload[i] ^= mask[i % 4]
            if opcode == 0x8:
                self.closed = True
                return None
            if opcode == 0x9:
                await self._frame(0xA, bytes(payload))
                continue
            if opcode == 0xA:
                continue
            buf += payload
            if fin:
                return json.loads(buf.decode())


class Fake:
    def __init__(self, args):
        self.args = args
        # Mit --token bleibt das Token über Server-Neustarts gleich (Test für das Wiederverbinden).
        self.token = args.token
        self.node_id = args.node_id or ("n_" + secrets.token_hex(4))
        self.results = []  # (name, ok, detail)
        self.done = asyncio.Event()

    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), detail))
        print(("  OK   " if ok else "  FEHL ") + name + (f" – {detail}" if detail else ""), flush=True)

    async def handle(self, reader, writer):
        try:
            request = await reader.readuntil(b"\r\n\r\n")
        except Exception:
            writer.close()
            return
        lines = request.decode(errors="replace").split("\r\n")
        method, path, _ = lines[0].split(" ", 2)
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        body = b""
        if "content-length" in headers:
            body = await reader.readexactly(int(headers["content-length"]))

        if method == "POST" and path == "/api/nodes/claim":
            await self.claim(writer, body)
        elif method == "GET" and path == "/api/nodes/link":
            await self.link(reader, writer, headers)
        else:
            self.respond(writer, 404, {"detail": "not found"})
            await writer.drain()
            writer.close()

    def respond(self, writer, status, obj):
        data = json.dumps(obj).encode()
        reason = {200: "OK", 401: "Unauthorized", 404: "Not Found"}.get(status, "X")
        writer.write(
            f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\n"
            f"Connection: close\r\n\r\n".encode() + data
        )

    async def claim(self, writer, body):
        req = json.loads(body or b"{}")
        print(f"claim: name={req.get('name')!r} mode={req.get('mode')!r} os={req.get('os')!r} "
              f"app_version={req.get('app_version')!r}", flush=True)
        if req.get("code") != self.args.code:
            self.respond(writer, 404, {"detail": "Code ungültig"})
        else:
            self.token = self.args.token or secrets.token_urlsafe(32)
            self.respond(writer, 200, {"node_id": self.node_id, "node_token": self.token,
                                       "server_url": f"http://127.0.0.1:{self.args.port}"})
            self.check("Kopplung (claim)", True, f"node_id={self.node_id}")
        await writer.drain()
        writer.close()

    async def link(self, reader, writer, headers):
        auth = headers.get("authorization", "")
        if not self.token or auth != f"Bearer {self.token}":
            self.respond(writer, 401, {"detail": "Token ungültig"})
            await writer.drain()
            writer.close()
            print("link: abgelehnt (Token falsch)", flush=True)
            return
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
        writer.write(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n".encode()
        )
        await writer.drain()
        ws = WS(reader, writer)
        hello = await ws.recv()
        print("hello:", json.dumps(hello, ensure_ascii=False), flush=True)
        self.check("hello empfangen", hello and hello.get("type") == "hello"
                   and hello.get("node_id") == self.node_id and "mode" in hello, "")
        try:
            await self.scenario(ws)
        finally:
            self.done.set()
            writer.close()

    async def call(self, ws, command, params=None, timeout=60):
        cid = "c_" + secrets.token_hex(4)
        await ws.send({"type": "cmd", "id": cid, "command": command, "params": params or {}})
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = await asyncio.wait_for(ws.recv(), timeout=deadline - time.time())
            if msg is None:
                raise ConnectionError("Verbindung zu")
            if msg.get("type") == "result" and msg.get("id") == cid:
                return msg.get("result") or {}
            if msg.get("type") == "ping":
                await ws.send({"type": "pong"})
            elif msg.get("type") == "state":
                print("state:", msg, flush=True)
        raise TimeoutError(command)

    async def scenario(self, ws):
        if self.args.activity:
            await ws.send({"type": "activity", "bot_name": self.args.activity, "active": True})

        r = await self.call(ws, "get_screen_size")
        size = r.get("size") or {}
        self.check("get_screen_size", r.get("success") and size.get("width", 0) > 0, json.dumps(size))

        r = await self.call(ws, "get_cursor_position")
        self.check("get_cursor_position", r.get("success") and "x" in (r.get("position") or {}),
                   json.dumps(r.get("position")))

        r = await self.call(ws, "screenshot", timeout=30)
        if r.get("success"):
            png = base64.b64decode(r["image_data"])
            w, h = struct.unpack("!II", png[16:24])
            self.check("screenshot (PNG in logischen Punkten = get_screen_size)",
                       png[:8] == b"\x89PNG\r\n\x1a\n" and (w, h) == (size.get("width"), size.get("height")),
                       f"{w}x{h} PNG, {len(png)//1024} kB")
        else:
            err = r.get("error", "")
            # Ohne Bildschirmaufnahme-Recht ist ein klarer Fehler das erwartete Verhalten.
            self.check("screenshot (ohne Recht: sauberer Fehler)", "Bildschirmaufnahme" in err, err)

        r = await self.call(ws, "run_command", {"command": "echo ok"})
        self.check("run_command echo ok", r.get("success") and r.get("stdout", "").strip() == "ok"
                   and r.get("return_code") == 0, json.dumps({k: r.get(k) for k in ("stdout", "return_code")}))

        r = await self.call(ws, "run_command", {"command": "echo fehler >&2; exit 3"})
        self.check("run_command Rückgabecode/stderr", r.get("return_code") == 3 and "fehler" in r.get("stderr", ""))

        tmp = tempfile.mkdtemp(prefix="scoops-connect-test-")
        path = os.path.join(tmp, "unter", "datei.bin")
        payload = os.urandom(3000)
        r = await self.call(ws, "write_bytes", {"path": path, "content_b64": base64.b64encode(payload).decode()})
        self.check("write_bytes", r.get("success"), path)
        r = await self.call(ws, "write_bytes", {"path": path, "content_b64": base64.b64encode(b"ENDE").decode(),
                                                "append": True})
        self.check("write_bytes append", r.get("success"))
        r = await self.call(ws, "read_bytes", {"path": path})
        data = base64.b64decode(r.get("content_b64", ""))
        self.check("read_bytes (Inhalt identisch)", data == payload + b"ENDE", f"{len(data)} Bytes")
        r = await self.call(ws, "read_bytes", {"path": path, "offset": 3000, "length": 4})
        self.check("read_bytes offset/length", base64.b64decode(r.get("content_b64", "")) == b"ENDE")
        r = await self.call(ws, "read_bytes", {"path": os.path.join(tmp, "fehlt")})
        self.check("read_bytes fehlende Datei → Fehler", r.get("success") is False, r.get("error", ""))

        r = await self.call(ws, "gibt_es_nicht")
        self.check("unbekannter Befehl → Fehler", r.get("success") is False, r.get("error", ""))

        # ping → pong
        await ws.send({"type": "ping"})
        got_pong = False
        deadline = time.time() + 5
        while time.time() < deadline and not got_pong:
            msg = await asyncio.wait_for(ws.recv(), timeout=deadline - time.time())
            got_pong = bool(msg) and msg.get("type") == "pong"
        self.check("ping → pong", got_pong)

        if self.args.hold:
            print(f"halte die Verbindung {self.args.hold} s offen …", flush=True)
            end = time.time() + self.args.hold
            while time.time() < end:
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=max(0.1, end - time.time()))
                except asyncio.TimeoutError:
                    break
                if msg is None:
                    break
                if msg.get("type") == "ping":
                    await ws.send({"type": "pong"})
                elif msg.get("type") == "state":
                    print("state:", json.dumps(msg), flush=True)
                    if msg.get("paused"):
                        r = await self.call(ws, "get_screen_size")
                        self.check("pausiert → Befehle abgelehnt", r.get("error") == "Rechner ist pausiert",
                                   r.get("error", ""))

        if self.args.bye:
            await ws.send({"type": "bye", "reason": "Test beendet"})
            await asyncio.sleep(1)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--code", default="TEST-2345")
    ap.add_argument("--activity", help="Name des Scoops, den der Server als aktiv meldet")
    ap.add_argument("--hold", type=float, default=0, help="Sekunden, die die Verbindung danach offen bleibt")
    ap.add_argument("--bye", action="store_true", help="am Ende bye senden (App löscht das Token)")
    ap.add_argument("--timeout", type=float, default=180)
    ap.add_argument("--token", help="festes Token (Wiederverbinden testen: zweiten Server mit gleichem Token starten)")
    ap.add_argument("--node-id", help="feste Knoten-ID (zusammen mit --token)")
    args = ap.parse_args()
    fake = Fake(args)
    server = await asyncio.start_server(fake.handle, "127.0.0.1", args.port)
    print(f"Fake-Server auf http://127.0.0.1:{args.port}, Code {args.code}", flush=True)
    try:
        await asyncio.wait_for(fake.done.wait(), timeout=args.timeout)
    except asyncio.TimeoutError:
        fake.check("App hat sich verbunden", False, "Zeitüberschreitung")
    server.close()
    failed = [n for n, ok, _ in fake.results if not ok]
    print(f"\n{len(fake.results) - len(failed)}/{len(fake.results)} Prüfungen bestanden", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    asyncio.run(main())
