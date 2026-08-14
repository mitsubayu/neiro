import Foundation

/// Watches Music.app's unified-log output for AudioQueue creation, which
/// carries the *source* sample rate of the item that just started playing —
/// e.g. `Creating AudioQueue with format:'qlac', framesPerPacket:4096,
/// sampleRate:96000, …`. Music does not expose this via any public API;
/// reading its log is the established technique (same as LosslessSwitcher).
final class TrackRateDetector {
    /// Called on the main queue with the detected source rate in Hz.
    var onRateDetected: ((Double) -> Void)?

    /// Called on the main queue when Music's decoder logs its output format —
    /// `Output format:  2 ch,  96000 Hz, lpcm … 24-bit little-endian signed
    /// integer`. `bitDepth` is nil for float/unknown formats (e.g. AAC).
    var onBitDepthDetected: ((_ sampleRate: Double, _ bitDepth: Int?) -> Void)?

    private var process: Process?
    private var lineBuffer = Data()
    private let queue = DispatchQueue(label: "neiro.ratedetector")

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.process?.terminationHandler = nil
            self?.process?.terminate()
            self?.process = nil
            self?.lineBuffer.removeAll()
        }
    }

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }

    private func startLocked() {
        guard process == nil else { return }
        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        logProcess.arguments = [
            "stream",
            "--predicate", "process == \"Music\" AND (eventMessage CONTAINS \"Creating AudioQueue with format\" OR eventMessage CONTAINS \"Output format:\")",
            "--style", "ndjson",
        ]
        let pipe = Pipe()
        logProcess.standardOutput = pipe
        logProcess.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        // Respawn if the child dies (e.g. logd restart) while we're active.
        logProcess.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 2) {
                guard self.process != nil else { return }
                self.process = nil
                self.startLocked()
            }
        }

        do {
            try logProcess.run()
            process = logProcess
        } catch {
            process = nil
        }
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = json["eventMessage"] as? String else { continue }
            if let rate = Self.parseSampleRate(fromEventMessage: message) {
                DispatchQueue.main.async { [weak self] in self?.onRateDetected?(rate) }
            } else if let format = Self.parseOutputFormat(fromEventMessage: message) {
                DispatchQueue.main.async { [weak self] in
                    self?.onBitDepthDetected?(format.sampleRate, format.bitDepth)
                }
            }
        }
    }

    /// Parses decoder lines like `Output format:  2 ch,  96000 Hz, lpcm
    /// (0x0000000C) 24-bit little-endian signed integer`. Returns nil for
    /// non-output lines; bitDepth is nil for float formats.
    static func parseOutputFormat(fromEventMessage message: String) -> (sampleRate: Double, bitDepth: Int?)? {
        guard message.contains("Output format:") else { return nil }
        guard let rateRange = message.range(of: #"(\d+) Hz"#, options: .regularExpression),
              let rate = Double(message[rateRange].dropLast(" Hz".count)),
              rate >= 8000, rate <= 768_000 else { return nil }
        var depth: Int?
        if !message.localizedCaseInsensitiveContains("float") {
            // Two observed shapes: "lpcm … 24-bit little-endian signed
            // integer" and the terse "Int16, interleaved".
            if let depthRange = message.range(of: #"(\d+)-bit"#, options: .regularExpression) {
                depth = Int(message[depthRange].dropLast("-bit".count))
            } else if let intRange = message.range(of: #"Int(\d+)"#, options: .regularExpression) {
                depth = Int(message[intRange].dropFirst("Int".count))
            }
        }
        return (rate, depth)
    }

    static func parseSampleRate(fromEventMessage message: String) -> Double? {
        guard let range = message.range(of: #"sampleRate:(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = message[range].dropFirst("sampleRate:".count)
        guard let rate = Double(digits), rate >= 8000, rate <= 768_000 else { return nil }
        return rate
    }
}
