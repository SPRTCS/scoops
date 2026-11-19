import Foundation
import Testing

/// Ein hängender Befehl darf die folgenden nicht aufhalten (CommandDeadline), `read_bytes` prüft vorher Größe und Art.
@Suite("Zeitgrenzen und Dateizugriff")
struct CommandDeadlineTests {
    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "scoops-deadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Schnelle Befehle liefern ihr eigenes Ergebnis")
    func fastWorkWins() async {
        let r = await CommandDeadline.run("get_cursor_position", limit: .seconds(5)) { CmdResult.ok(["x": .int(1)]) }
        #expect(r["success"]?.bool == true)
        #expect(r["x"]?.int == 1)
    }

    @Test("Zeitgrenzen liegen unter denen des Servers (60 s, Screenshot 30 s)")
    func limitsBelowServer() {
        #expect(CommandDeadline.limit(for: "screenshot") < .seconds(30))
        #expect(CommandDeadline.limit(for: "read_bytes") < .seconds(60))
        #expect(CommandDeadline.limit(for: "type_text") < .seconds(60))
    }

    @Test("Blockierender Aufruf: Fehler nach der Zeitgrenze, ohne auf ihn zu warten")
    func blockingWorkTimesOut() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        let r = await CommandDeadline.run("read_bytes", limit: .milliseconds(300)) {
            // Echter blockierender Aufruf auf einem GCD-Thread, der erst nach dem Test freigegeben wird.
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    gate.wait()
                    cont.resume(returning: CmdResult.ok())
                }
            }
        }
        let took = ContinuousClock.now - started
        #expect(r["success"]?.bool == false)
        #expect(r["error"]?.string?.contains("read_bytes hängt") == true)
        #expect(took < .seconds(2), "Hat \(took) auf den hängenden Aufruf gewartet")
        // Der nächste Befehl wird sofort beantwortet.
        let t2 = ContinuousClock.now
        let next = await CommandDeadline.run("get_cursor_position", limit: .seconds(5)) { CmdResult.ok() }
        #expect(next["success"]?.bool == true)
        #expect(ContinuousClock.now - t2 < .milliseconds(500))
        gate.signal()
    }

    @Test("Abbruch (Verbindung getrennt) beendet das Warten sofort, auch bei blockierendem Aufruf")
    func cancellationReturnsImmediately() async {
        let gate = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        // Wie runSession: Task-Gruppe mit dem Befehl als Kind, die beim Trennen abgeräumt wird.
        let r = await withTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                await CommandDeadline.run("read_bytes", limit: .seconds(30)) {
                    await withCheckedContinuation { cont in
                        DispatchQueue.global().async { gate.wait(); cont.resume(returning: CmdResult.ok()) }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
            group.cancelAll()
            return await group.next()!
        }
        #expect(r["error"]?.string?.contains("abgebrochen") == true)
        #expect(ContinuousClock.now - started < .seconds(2))
        gate.signal()
    }

    @Test("Schon abgebrochener Aufrufer bekommt sofort eine Antwort")
    func alreadyCancelled() async {
        let t = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CommandDeadline.run("screenshot", limit: .seconds(30)) {
                try? await Task.sleep(for: .seconds(10))
                return CmdResult.ok()
            }
        }
        let started = ContinuousClock.now
        let r = await t.value
        #expect(r["success"]?.bool == false)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("read_bytes auf eine FIFO hängt, die Warteschlange nicht")
    func fifoDoesNotBlockQueue() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appending(path: "haengt.fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let started = ContinuousClock.now
        let r = await CommandDeadline.run("read_bytes", limit: .milliseconds(500)) {
            await FileBytes.readAsync(path: fifo, offset: 0, length: nil)
        }
        #expect(r["success"]?.bool == false)
        #expect(r["error"]?.string?.contains("hängt") == true)
        #expect(ContinuousClock.now - started < .seconds(2))
        let next = await CommandDeadline.run("get_cursor_position", limit: .seconds(5)) { CmdResult.ok() }
        #expect(next["success"]?.bool == true)
        // Hängenden Leser freigeben (Schreiber öffnen und schließen → EOF).
        if let w = FileHandle(forWritingAtPath: fifo) { try? w.close() }
    }

    @Test("read_bytes liest normale Dateien, auch ab offset und mit length")
    func readsNormalFile() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "probe.txt")
        try Data("hallo vom server".utf8).write(to: file)
        let all = await FileBytes.readAsync(path: file.path, offset: 0, length: nil)
        #expect(all["content_b64"]?.string.flatMap { Data(base64Encoded: $0) } == Data("hallo vom server".utf8))
        let part = await FileBytes.readAsync(path: file.path, offset: 6, length: 3)
        #expect(part["content_b64"]?.string.flatMap { Data(base64Encoded: $0) } == Data("vom".utf8))
    }

    @Test("read_bytes lehnt zu große Dateien ab, statt still abzuschneiden")
    func rejectsTooLarge() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "gross.bin").path
        #expect(FileManager.default.createFile(atPath: file, contents: nil))
        #expect(truncate(file, off_t(FileBytes.maxRead + 1)) == 0)  // dünn besetzt, belegt keinen Platz
        let r = FileBytes.read(path: file, offset: 0, length: nil)
        #expect(r["success"]?.bool == false)
        #expect(r["error"]?.string?.contains("zu groß") == true)
        // Ein Teil davon (offset/length) geht.
        let part = FileBytes.read(path: file, offset: 0, length: 1024)
        #expect(part["content_b64"]?.string.flatMap { Data(base64Encoded: $0) }?.count == 1024)
        let tail = FileBytes.read(path: file, offset: 2, length: nil)
        #expect(tail["success"]?.bool == true)
        // So fragt der Server an (datei_vom_rechner): length = Grenze + 1.
        let server = FileBytes.read(path: file, offset: 0, length: FileBytes.maxRead + 1)
        #expect(server["error"]?.string?.contains("zu groß") == true)
    }

    @Test("read_bytes: Ordner und fehlende Dateien geben klare Fehler")
    func clearErrors() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileBytes.read(path: dir.path, offset: 0, length: nil)["error"]?.string?.contains("Ordner") == true)
        let missing = FileBytes.read(path: dir.appending(path: "fehlt.txt").path, offset: 0, length: nil)
        #expect(missing["error"]?.string?.contains("nicht gefunden") == true)
    }

    @Test("Größenangaben in Meldungen")
    func sizeText() {
        #expect(FileBytes.sizeText(36_550) == "36 KB")
        #expect(FileBytes.sizeText(2_500_000) == "2,5 MB")
        #expect(FileBytes.sizeText(30_000_000) == "30 MB")
    }

    @Test("Base64 der größten Datei passt in eine WebSocket-Nachricht (64 MiB)")
    func maxReadFitsWebSocket() {
        let base64 = (FileBytes.maxRead + 2) / 3 * 4
        #expect(base64 + 1024 < 64 * 1024 * 1024)
    }
}
