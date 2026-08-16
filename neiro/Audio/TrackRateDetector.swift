import Foundation

/// Watches Music.app's unified-log output for AudioQueue creation, which
/// carries the *source* sample rate of the item that just started playing —
/// e.g. `Creating AudioQueue with format:'qlac', framesPerPacket:4096,
/// sampleRate:96000, …`. Music does not expose this via any public API;
/// reading its log is the established technique (same as LosslessSwitcher).
final class TrackRateDetector {
    /// Called on the main queue with the detected source rate in Hz.
    var onRateDetected: ((Double) -> Void)?

    /// Called on the main queue with the source codec fourcc (e.g. "qlac")
    /// from the AudioQueue-creation line.
    var onCodecDetected: ((String) -> Void)?

    /// Called on the main queue when Music's decoder logs its output format —
    /// `Output format:  2 ch,  96000 Hz, lpcm … 24-bit little-endian signed
    /// integer`. `bitDepth` is nil for float/unknown formats (e.g. AAC).
    var onBitDepthDetected: ((_ sampleRate: Double, _ bitDepth: Int?) -> Void)?

    private var process: Process?
    private var lineBuffer = Data()
    private let queue = DispatchQueue(label: "neiro.ratedetector")

    /// Predicate shared by the live stream and the one-shot lookback.
    private static let predicate = "process == \"Music\" AND (eventMessage CONTAINS \"Creating AudioQueue with format\" OR eventMessage CONTAINS \"Output format:\")"

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
            self?.recoverRecentFormatLocked()
        }
    }

    /// The live stream only ever sees *new* lines, so a track that was already
    /// playing when we started gives us nothing — the engine would then run at
    /// whatever rate the device happened to be on until the next track. Replay
    /// the recent log once so the current track's format is known immediately.
    private func recoverRecentFormatLocked(lookbackSeconds: Int = 120) {
        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        logProcess.arguments = [
            "show",
            "--last", "\(lookbackSeconds)s",
            "--predicate", Self.predicate,
            "--style", "ndjson",
        ]
        let pipe = Pipe()
        logProcess.standardOutput = pipe
        logProcess.standardError = FileHandle.nullDevice
        do {
            try logProcess.run()
        } catch {
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        logProcess.waitUntilExit()

        var latestRate: Double?
        var latestCodec: String?
        var latestFormat: (sampleRate: Double, bitDepth: Int?)?
        var latestDecoderCodec: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = json["eventMessage"] as? String else { continue }
            if let rate = Self.parseSampleRate(fromEventMessage: message) {
                latestRate = rate
                latestCodec = Self.parseCodec(fromEventMessage: message) ?? latestCodec
            } else if let format = Self.parseOutputFormat(fromEventMessage: message) {
                latestFormat = format
                latestDecoderCodec = Self.parseDecoderCodec(fromEventMessage: message) ?? latestDecoderCodec
            }
        }
        guard latestRate != nil || latestFormat != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let codec = latestCodec ?? latestDecoderCodec { self.onCodecDetected?(codec) }
            if let format = latestFormat { self.onBitDepthDetected?(format.sampleRate, format.bitDepth) }
            if let rate = latestRate { self.onRateDetected?(rate) }
        }
    }

    /// Tear down and start over — used when a track demonstrably started but
    /// no line ever arrived, which means the stream is alive but useless.
    func restart() {
        stop()
        start()
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
            "--predicate", Self.predicate,
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
                let codec = Self.parseCodec(fromEventMessage: message)
                DispatchQueue.main.async { [weak self] in
                    if let codec { self?.onCodecDetected?(codec) }
                    self?.onRateDetected?(rate)
                }
            } else if let format = Self.parseOutputFormat(fromEventMessage: message) {
                let codec = Self.parseDecoderCodec(fromEventMessage: message)
                DispatchQueue.main.async { [weak self] in
                    if let codec { self?.onCodecDetected?(codec) }
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

    /// Extracts the codec fourcc from `…with format:'qlac', …`.
    static func parseCodec(fromEventMessage message: String) -> String? {
        guard let range = message.range(of: #"format:'([^']+)'"#, options: .regularExpression) else {
            return nil
        }
        let match = message[range]
        guard let open = match.firstIndex(of: "'"), let close = match.lastIndex(of: "'"),
              open < close else { return nil }
        let codec = match[match.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return codec.isEmpty ? nil : codec
    }

    /// Music only logs "Creating AudioQueue with format:'…'" when it builds a
    /// new queue, which it skips for many track changes — so the codec was
    /// usually missing from the display. The decoder that logs the output
    /// format names itself, and that line comes with every track.
    static func parseDecoderCodec(fromEventMessage message: String) -> String? {
        guard message.contains("Output format:") else { return nil }
        if message.contains("AppleLossless") { return "ALAC" }
        if message.contains("AAC") { return "AAC" }
        if message.contains("FLAC") { return "FLAC" }
        if message.contains("MP3") || message.contains("Mpeg") { return "MP3" }
        // ACCPEDecoderWrapper and friends don't name a format; ignore them
        // rather than guess.
        return nil
    }

    /// Human-readable codec name for the display ("qlac" → "ALAC").
    static func codecDisplayName(_ fourcc: String) -> String {
        let lower = fourcc.lowercased()
        if lower.contains("lac") { return "ALAC" }
        if lower.contains("aac") { return "AAC" }
        if lower.contains("mp3") { return "MP3" }
        if lower.contains("flac") { return "FLAC" }
        return fourcc.uppercased()
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
