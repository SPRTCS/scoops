import Foundation

/// Führt einen Server-Befehl aus und liefert das Ergebnis im Cua-Format (`success`, …).
protocol CommandExecutor: AnyObject {
    func execute(_ command: String, params: JSONValue) async -> JSONValue
    /// Bildschirmgröße in Punkten für `hello`, falls bekannt.
    func screenSize() async -> CGSize?
    /// Wird beim Pausieren/Trennen aufgerufen (gedrückte Tasten loslassen usw.).
    func reset()
}

enum Commands {
    /// Befehle, die etwas auf dem Rechner verändern; nur sie schalten den Hinweis „Scoop steuert“ ein.
    static let active: Set<String> = [
        "move_cursor", "left_click", "right_click", "double_click", "mouse_down", "mouse_up", "drag", "scroll",
        "type_text", "press_key", "hotkey", "key_down", "key_up", "run_command", "write_bytes",
    ]
}

/// Dateizugriff für `read_bytes`/`write_bytes`.
///
/// Die Zugriffe blockieren (FileHandle) und laufen deshalb auf einer GCD-Warteschlange, nicht im Thread-Pool von
/// Swift Concurrency: Ein hängender Zugriff (FIFO, Netzlaufwerk, Datei aus der Cloud) belegt so keinen der wenigen
/// Pool-Threads. Die Zeitgrenze setzt `CommandDeadline` (AppModel.commandLoop).
nonisolated enum FileBytes {
    /// Höchstens so viele Bytes pro `read_bytes`. Passt zu `datei_vom_rechner` auf dem Server (25 MB) und als
    /// Base64 (~33 MB) plus JSON sicher in eine WebSocket-Nachricht (App und Server: 64 MiB).
    static let maxRead = 25_000_000
    /// `SF_DATALESS` aus <sys/stat.h>: Inhalt liegt nur beim Cloud-Anbieter (iCloud, File Provider).
    static let datalessFlag: UInt32 = 0x4000_0000

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func readAsync(path: String, offset: Int, length: Int?) async -> JSONValue {
        await onQueue { read(path: path, offset: offset, length: length) }
    }

    static func writeAsync(path: String, base64: String, append: Bool) async -> JSONValue {
        await onQueue { write(path: path, base64: base64, append: append) }
    }

    private static func onQueue(_ work: @escaping @Sendable () -> JSONValue) async -> JSONValue {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }

    static func sizeText(_ bytes: Int) -> String {
        if bytes < 1_000_000 { return "\(max(1, bytes / 1000)) KB" }
        let mb = Double(bytes) / 1_000_000
        return mb >= 10 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f MB", locale: Locale(identifier: "de_DE"), mb)
    }

    static func read(path: String, offset: Int, length: Int?) -> JSONValue {
        let p = expand(path)
        var st = stat()
        guard stat(p, &st) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return CmdResult.fail("Datei nicht gefunden: \(path)") }
            return CmdResult.fail("Datei nicht lesbar: \(path) (\(String(cString: strerror(code))))")
        }
        let type = st.st_mode & S_IFMT
        if type == S_IFDIR { return CmdResult.fail("\(path) ist ein Ordner, keine Datei.") }
        let start = max(0, offset)
        if type == S_IFREG {
            let size = Int(st.st_size)
            let remaining = max(0, size - start)
            // Mehr als `maxRead` geht nicht in einem Abruf: lieber klar ablehnen als still abschneiden. Der Server
            // fragt `length = 25 MB + 1` an, damit auch ältere Apps und die VM nicht mehr schicken.
            if min(length ?? Int.max, remaining) > maxRead {
                return CmdResult.fail("Datei ist zu groß: \(sizeText(size)), höchstens \(sizeText(maxRead)) pro Abruf. "
                    + "Verkleinern oder packen (z. B. zip) oder in Teilen lesen (offset/length).")
            }
            if let hint = startCloudDownloadIfNeeded(p, flags: st.st_flags, size: size) {
                return CmdResult.fail(hint)
            }
        }
        guard let h = FileHandle(forReadingAtPath: p) else { return CmdResult.fail("Datei nicht lesbar: \(path)") }
        defer { try? h.close() }
        do {
            if start > 0 { try h.seek(toOffset: UInt64(start)) }
            let want = min(max(0, length ?? maxRead), maxRead)
            let data = try h.read(upToCount: want) ?? Data()
            return CmdResult.ok(["content_b64": .string(data.base64EncodedString())])
        } catch {
            return CmdResult.fail("Lesen fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Liegt der Inhalt nur in der Cloud, würde Lesen blockieren, bis er geladen ist. Dann den Download anstoßen
    /// und sofort mit einem Hinweis antworten (nicht warten). `nil` = Inhalt ist lokal, lesen.
    static func startCloudDownloadIfNeeded(_ path: String, flags: UInt32, size: Int) -> String? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        let notDownloaded = values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded
        guard notDownloaded || flags & datalessFlag != 0 else { return nil }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // Kein iCloud-Objekt (anderer File Provider, z. B. OneDrive): Ein Lesezugriff lädt die Datei. Er
            // blockiert, deshalb im Hintergrund und ohne auf ihn zu warten.
            DispatchQueue.global(qos: .utility).async {
                guard let h = FileHandle(forReadingAtPath: path) else { return }
                _ = try? h.read(upToCount: 1)
                try? h.close()
            }
        }
        return "Die Datei liegt nur in der Cloud (iCloud) und wird jetzt auf den Mac geladen (\(sizeText(size))). "
            + "Gleich noch einmal versuchen, bei großen Dateien in einer Minute."
    }

    static func write(path: String, base64: String, append: Bool) -> JSONValue {
        guard let data = Data(base64Encoded: base64) else { return CmdResult.fail("content_b64 ist kein gültiges Base64") }
        let url = URL(fileURLWithPath: expand(path))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            return CmdResult.ok()
        } catch {
            return CmdResult.fail("Schreiben fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}
