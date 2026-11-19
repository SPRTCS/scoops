import Foundation

/// Startet Prozesse mit Zeitlimit und begrenzter Ausgabe, ohne den Haupt-Thread zu blockieren.
nonisolated enum ProcessRunner {
    struct Output: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
        var timedOut: Bool
        var truncated: Bool
    }

    /// Sammelt Ausgabe thread-sicher bis zu einer Obergrenze.
    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var truncated = false
        let limit: Int
        let onLine: (@Sendable (String) -> Void)?
        private var pendingLine = Data()

        init(limit: Int, onLine: (@Sendable (String) -> Void)? = nil) {
            self.limit = limit
            self.onLine = onLine
        }

        func append(_ chunk: Data) {
            lock.lock()
            let room = max(0, limit - data.count)
            if chunk.count > room { truncated = true }
            data.append(chunk.prefix(room))
            var lines: [String] = []
            if onLine != nil {
                pendingLine.append(chunk)
                while let idx = pendingLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = pendingLine[pendingLine.startIndex..<idx]
                    pendingLine.removeSubrange(pendingLine.startIndex...idx)
                    if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                }
            }
            lock.unlock()
            lines.forEach { onLine?($0) }
        }

        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Führt `executable` mit `arguments` aus. Nach `timeout` Sekunden wird beendet (SIGTERM, dann SIGKILL).
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        limit: Int = 1_000_000,
        environment: [String: String]? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = Buffer(limit: limit, onLine: onLine)
        let err = Buffer(limit: limit, onLine: onLine)
        let flag = TimeoutFlag()

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { out.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { err.append(d) }
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            process.terminationHandler = { p in
                // Kurz warten, damit die letzten Bytes aus den Pipes ankommen. Enkelprozesse, die die Pipe
                // offen halten, blockieren uns so nicht.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: Output(
                        stdout: out.string, stderr: err.string, status: p.terminationStatus,
                        timedOut: flag.value, truncated: out.truncated || err.truncated))
                }
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: Output(stdout: "", stderr: error.localizedDescription, status: 127,
                                              timedOut: false, truncated: false))
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                flag.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }

    final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
        func set() { lock.lock(); _value = true; lock.unlock() }
    }

    /// `run_command` wie beim Cua-Computer-Server: zsh als Login-Shell, 120 s, Ausgabe begrenzt.
    static func shell(_ command: String, timeout: TimeInterval = 120, limit: Int = 1_000_000) async -> JSONValue {
        let r = await run("/bin/zsh", ["-lc", command], timeout: timeout, limit: limit)
        var stderr = r.stderr
        if r.truncated { stderr += "\n[Scoops Connect: Ausgabe nach \(limit / 1000) kB abgeschnitten]" }
        if r.timedOut { stderr += "\n[Scoops Connect: nach \(Int(timeout)) s abgebrochen]" }
        return CmdResult.ok([
            "stdout": .string(r.stdout),
            "stderr": .string(stderr),
            "return_code": .int(r.timedOut ? 124 : Int(r.status)),
        ])
    }
}
