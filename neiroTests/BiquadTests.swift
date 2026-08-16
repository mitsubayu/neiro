import CoreAudio
import Testing
@testable import neiro
import Foundation

struct BiquadTests {
    let sampleRate = 48_000.0

    @Test func zeroGainPeakIsIdentity() {
        let c = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: 0, q: 1, sampleRate: sampleRate)
        for frequency in [50.0, 500, 1000, 5000, 15_000] {
            let magnitudeDB = 20 * log10(c.magnitude(at: frequency, sampleRate: sampleRate))
            #expect(abs(magnitudeDB) < 0.01, "expected flat response at \(frequency) Hz")
        }
    }

    @Test func peakGainMatchesAtCenterFrequency() {
        for gain in [-12.0, -6, 3, 6, 12] {
            let c = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: gain, q: 1.4, sampleRate: sampleRate)
            let magnitudeDB = 20 * log10(c.magnitude(at: 1000, sampleRate: sampleRate))
            #expect(abs(magnitudeDB - gain) < 0.1, "peak gain \(gain) dB measured \(magnitudeDB)")
        }
    }

    @Test func shelvesReachFullGainInStopband() {
        let low = BiquadCoefficients.make(type: .lowShelf, frequency: 100, gainDB: 6, q: 0.707, sampleRate: sampleRate)
        let lowMagnitude = 20 * log10(low.magnitude(at: 20, sampleRate: sampleRate))
        #expect(abs(lowMagnitude - 6) < 0.5)
        let lowHF = 20 * log10(low.magnitude(at: 10_000, sampleRate: sampleRate))
        #expect(abs(lowHF) < 0.2, "low shelf should not affect treble")

        let high = BiquadCoefficients.make(type: .highShelf, frequency: 8000, gainDB: -6, q: 0.707, sampleRate: sampleRate)
        let highMagnitude = 20 * log10(high.magnitude(at: 20_000, sampleRate: sampleRate))
        #expect(abs(highMagnitude + 6) < 0.5)
        let highLF = 20 * log10(high.magnitude(at: 100, sampleRate: sampleRate))
        #expect(abs(highLF) < 0.2, "high shelf should not affect bass")
    }

    @Test func impulseResponseDecays() {
        let c = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: 12, q: 8, sampleRate: sampleRate)
        var state = BiquadState()
        var tail = 0.0
        for n in 0..<48_000 {
            let y = state.process(n == 0 ? 1 : 0, c)
            if n >= 47_000 { tail = max(tail, Double(abs(y))) }
            #expect(y.isFinite)
        }
        #expect(tail < 1e-6, "high-Q peak should be stable and decay")
    }

    @Test func processorAppliesPreGain() {
        let processor = EQProcessor()
        var settings = EQSettings.makeDefault()
        settings.preGainDB = -6.02
        processor.setSampleRate(sampleRate)
        processor.update(settings: settings)

        var buffer: [Float32] = [1, 1, 0.5, 0.5, -1, -1]
        buffer.withUnsafeMutableBufferPointer { ptr in
            processor.process(ptr.baseAddress!, frames: 3, channels: 2)
        }
        #expect(abs(buffer[0] - 0.5) < 0.01)
        #expect(abs(buffer[4] + 0.5) < 0.01)
    }

    @Test func trackRateParsing() {
        let real = "<<<< FAQ >>>> subaq_buildCAAudioQueue: [0xaf0671f80:0xafc62f480] RP/DO.07 Creating AudioQueue with format:'qlac', framesPerPacket:4096, sampleRate:96000, releasePlayResourceForFormatChange:1 notificationToken: 84dac35f6"
        #expect(TrackRateDetector.parseSampleRate(fromEventMessage: real) == 96000)
        #expect(TrackRateDetector.parseSampleRate(fromEventMessage: "sampleRate:44100,") == 44100)
        #expect(TrackRateDetector.parseSampleRate(fromEventMessage: "no rate here") == nil)
        #expect(TrackRateDetector.parseSampleRate(fromEventMessage: "sampleRate:1") == nil)
    }

    @Test func outputFormatParsing() {
        let alac = "(0xb01282880) Output format:  2 ch,  96000 Hz, lpcm (0x0000000C) 24-bit little-endian signed integer"
        let parsed = TrackRateDetector.parseOutputFormat(fromEventMessage: alac)
        #expect(parsed?.sampleRate == 96000)
        #expect(parsed?.bitDepth == 24)

        let aac = "(0xb) Output format:  2 ch,  44100 Hz, lpcm (0x29) 32-bit little-endian float, deinterleaved"
        let parsedFloat = TrackRateDetector.parseOutputFormat(fromEventMessage: aac)
        #expect(parsedFloat?.sampleRate == 44100)
        #expect(parsedFloat?.bitDepth == nil)

        let cdQuality = "(0xaeda13200) Output format:  2 ch,  44100 Hz, Int16, interleaved"
        let parsedInt16 = TrackRateDetector.parseOutputFormat(fromEventMessage: cdQuality)
        #expect(parsedInt16?.sampleRate == 44100)
        #expect(parsedInt16?.bitDepth == 16)

        #expect(TrackRateDetector.parseOutputFormat(fromEventMessage: "Input format:  2 ch,  96000 Hz, qlac") == nil)
    }

    @MainActor
    @Test func marqueeSlotWidthRules() {
        let view = StatusMarqueeView()
        let suffix = "· ALAC 44.1kHz/16bit"

        view.update(title: "初恋", suffix: suffix)
        let short = view.desiredWidth
        view.update(title: "Howling over the World and the Moon", suffix: suffix)
        let long1 = view.desiredWidth
        view.update(title: "Howling over the World and the Moon and Beyond the Stars", suffix: suffix)
        let long2 = view.desiredWidth

        // Short titles take only their text width; anything long enough to
        // marquee is capped at the fixed 110pt slot regardless of length.
        #expect(short < long1)
        #expect(long1 == long2)

        view.update(title: "", suffix: suffix)
        let noTitle = view.desiredWidth
        #expect(noTitle < short)
        view.update(title: "", suffix: "")
        #expect(view.desiredWidth < noTitle)
    }

    @Test func bypassLeavesSamplesUntouched() {
        let processor = EQProcessor()
        var settings = EQSettings.makeDefault()
        settings.preGainDB = -12
        settings.bands[4].gainDB = 12
        processor.setSampleRate(sampleRate)

        let input: [Float32] = [0.5, -0.25, 0.75, -0.5]
        processor.update(settings: settings)
        var processed = input
        processed.withUnsafeMutableBufferPointer {
            processor.process($0.baseAddress!, frames: 2, channels: 2)
        }
        #expect(processed != input, "sanity: processing should change the signal")

        settings.isBypassed = true
        processor.update(settings: settings)
        var bypassed = input
        bypassed.withUnsafeMutableBufferPointer {
            processor.process($0.baseAddress!, frames: 2, channels: 2)
        }
        #expect(bypassed == input, "bypass must not touch a single sample")
    }

    @Test func spectrumFindsATone() {
        let analyzer = SpectrumAnalyzer()
        let rate = 48_000.0
        let toneHz = 1000.0
        var window = [Float](repeating: 0, count: SpectrumTap.fftSize)
        for i in window.indices {
            window[i] = 0.5 * Float(sin(2 * .pi * toneHz * Double(i) / rate))
        }
        // Smoothing means one pass under-reports; a steady tone converges.
        for _ in 0..<40 {
            window.withUnsafeBufferPointer { analyzer.analyze(window: $0.baseAddress!, sampleRate: rate) }
        }

        let peakIndex = analyzer.levels.enumerated().max { $0.element < $1.element }?.offset ?? -1
        let peakFrequency = SpectrumAnalyzer.frequency(forBin: peakIndex)
        #expect(abs(peakFrequency - toneHz) / toneHz < 0.08,
                "peak landed at \(peakFrequency) Hz for a \(toneHz) Hz tone")

        // Bins two octaves away must stay near the floor.
        let lowIndex = analyzer.levels.indices.first {
            SpectrumAnalyzer.frequency(forBin: $0) >= toneHz / 4
        } ?? 0
        #expect(analyzer.levels[max(lowIndex - 2, 0)] < analyzer.levels[peakIndex] * 0.5)

        for _ in 0..<60 { analyzer.decay() }
        #expect(analyzer.levels.allSatisfy { $0 < 0.01 }, "display should fall silent")
    }

    @Test func spectrumTapKeepsTheNewestSamples() {
        let tap = SpectrumTap()
        tap.setActive(true)
        // Write more than the ring holds so the read must wrap.
        var block = [Float](repeating: 0, count: 5000)
        for i in block.indices { block[i] = Float(i) }
        block.withUnsafeBufferPointer {
            tap.write($0.baseAddress!, frames: block.count, channels: 1)
        }

        var window = [Float](repeating: 0, count: SpectrumTap.fftSize)
        let ok = window.withUnsafeMutableBufferPointer { tap.latestWindow(into: $0.baseAddress!) }
        #expect(ok)
        #expect(window.last == Float(block.count - 1))
        #expect(window.first == Float(block.count - SpectrumTap.fftSize))

        // Inactive taps must not copy anything at all.
        let idle = SpectrumTap()
        block.withUnsafeBufferPointer { idle.write($0.baseAddress!, frames: 8, channels: 1) }
        var empty = [Float](repeating: 0, count: SpectrumTap.fftSize)
        #expect(!empty.withUnsafeMutableBufferPointer { idle.latestWindow(into: $0.baseAddress!) })
    }

    @MainActor
    @Test func aboutCreditsLinkTheAuthor() {
        let credits = AboutCredits.attributedString()
        let text = credits.string
        #expect(text.contains("© 2026 \(AboutCredits.authorName)"))

        var linkedRange = NSRange()
        let link = credits.attribute(.link, at: credits.length - 1, effectiveRange: &linkedRange) as? URL
        #expect(link == AboutCredits.authorURL)
        // Only the name is clickable, not the whole blurb.
        #expect((text as NSString).substring(with: linkedRange) == AboutCredits.authorName)
    }

    // MARK: - Undo history

    private func snapshot(_ gain: Double, pre: Double = 0) -> EQSnapshot {
        var settings = EQSettings.makeDefault()
        settings.bands[0].gainDB = gain
        settings.preGainDB = pre
        return EQSnapshot(settings)
    }

    @Test func historyWalksBackAndForward() {
        var history = EQHistory()
        #expect(!history.canUndo && !history.canRedo)

        let flat = snapshot(0), boosted = snapshot(6), cut = snapshot(-3)
        history.commit(previous: flat)     // flat → boosted
        history.commit(previous: boosted)  // boosted → cut

        #expect(history.canUndo)
        #expect(history.undo(current: cut) == boosted)
        #expect(history.undo(current: boosted) == flat)
        #expect(history.undo(current: flat) == nil, "nothing left to undo")

        #expect(history.canRedo)
        #expect(history.redo(current: flat) == boosted)
        #expect(history.redo(current: boosted) == cut)
        #expect(history.redo(current: cut) == nil)
    }

    @Test func newEditEndsTheRedoBranch() {
        var history = EQHistory()
        history.commit(previous: snapshot(0))
        _ = history.undo(current: snapshot(6))
        #expect(history.canRedo)

        history.commit(previous: snapshot(0))
        #expect(!history.canRedo, "editing after undo must drop the redo branch")
    }

    @Test func historyIsBounded() {
        var history = EQHistory()
        for i in 0..<(EQHistory.limit + 20) {
            history.commit(previous: snapshot(Double(i)))
        }
        #expect(history.undoStack.count == EQHistory.limit)
        // The oldest entries fall off, the newest survive. (Compare by value:
        // each snapshot carries freshly generated band ids.)
        #expect(history.undoStack.last?.bands.first?.gainDB == Double(EQHistory.limit + 19))
        #expect(history.undoStack.first?.bands.first?.gainDB == 20)
    }

    @Test func tapFormatValidation() {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        #expect(ProcessTapEngine.unsupportedFormatReason(format) == nil)

        format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        #expect(ProcessTapEngine.unsupportedFormatReason(format) == "non-interleaved")

        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        #expect(ProcessTapEngine.unsupportedFormatReason(format) == "not float")

        format.mFormatFlags = kAudioFormatFlagIsFloat
        format.mBitsPerChannel = 64
        #expect(ProcessTapEngine.unsupportedFormatReason(format) == "64-bit")

        // An unread (zeroed) description must not be treated as a failure.
        #expect(ProcessTapEngine.unsupportedFormatReason(AudioStreamBasicDescription()) == nil)
    }

    @Test func settingsCarryBypassAndBindings() throws {
        var settings = EQSettings.makeDefault()
        settings.isBypassed = true
        settings.presetBindings = ["uid-1": "Bass Boost"]
        let restored = try JSONDecoder().decode(EQSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.isBypassed)
        #expect(restored.presetBindings["uid-1"] == "Bass Boost")

        // Settings written before these keys existed must still load.
        let legacy = #"{"isEnabled":true,"preGainDB":0}"#
        let old = try JSONDecoder().decode(EQSettings.self, from: Data(legacy.utf8))
        #expect(!old.isBypassed)
        #expect(old.presetBindings.isEmpty)
    }

    // MARK: - Rate switch policy

    private func context(detected: Double? = 96_000,
                         engine: Double = 44_100,
                         enabled: Bool = true,
                         follow: Bool = true,
                         running: Bool = true,
                         inFlight: Bool = false,
                         atHead: Bool = false,
                         builtBlind: Bool = false) -> RateSwitchContext {
        RateSwitchContext(detectedRate: detected, engineRate: engine, isEnabled: enabled,
                          followTrackRate: follow, isEngineRunning: running,
                          isSwitchInFlight: inFlight, isAtKnownTrackHead: atHead,
                          engineBuiltWithoutTrackRate: builtBlind)
    }

    @Test func policyIdlesWhenNothingToDo() {
        #expect(RateSwitchPolicy.decide(context(detected: nil)) == .idle)
        #expect(RateSwitchPolicy.decide(context(detected: 44_100, engine: 44_100)) == .idle)
        #expect(RateSwitchPolicy.decide(context(enabled: false)) == .idle)
        #expect(RateSwitchPolicy.decide(context(follow: false)) == .idle)
        #expect(RateSwitchPolicy.decide(context(running: false)) == .idle)
    }

    @Test func policyWaitsWhileASwitchIsRunning() {
        #expect(RateSwitchPolicy.decide(context(inFlight: true)) == .waitForInFlightSwitch)
        // Even at a track head: never start a second switch on top of one.
        #expect(RateSwitchPolicy.decide(context(inFlight: true, atHead: true)) == .waitForInFlightSwitch)
    }

    @Test func policyCorrectsABlindlyBuiltEngineWithoutRestarting() {
        // Launched mid-track: fix the rate but keep playback where it is.
        #expect(RateSwitchPolicy.decide(context(builtBlind: true)) == .switchKeepingPosition)
        // A known head still wins nothing here — not restarting is safer.
        #expect(RateSwitchPolicy.decide(context(atHead: true, builtBlind: true)) == .switchKeepingPosition)
    }

    @Test func policyRestartsTrackAtKnownHead() {
        #expect(RateSwitchPolicy.decide(context(atHead: true)) == .switchRestartingTrack)
    }

    @Test func policyQueriesWhenHeadIsUnknown() {
        #expect(RateSwitchPolicy.decide(context()) == .queryPlayer)
    }

    @Test func policyAfterQueryFollowsPlayerPosition() {
        #expect(RateSwitchPolicy.decideAfterQuery(playerState: "playing", position: 1.2) == .switchRestartingTrack)
        #expect(RateSwitchPolicy.decideAfterQuery(playerState: "playing", position: 42) ==
                .deferToTrackBoundary(milliseconds: RateSwitchPolicy.deferRetryMilliseconds))
        // Paused/stopped/unreachable: no transport commands, just rebuild.
        #expect(RateSwitchPolicy.decideAfterQuery(playerState: "paused", position: nil) == .switchKeepingPosition)
        #expect(RateSwitchPolicy.decideAfterQuery(playerState: nil, position: nil) == .switchKeepingPosition)
    }

    @Test func codecParsing() {
        let line = "<<<< FAQ >>>> subaq_buildCAAudioQueue: [0x9:0x9] RP/ZZ.25 Creating AudioQueue with format:'qlac', framesPerPacket:4096, sampleRate:48000, releasePlayResourceForFormatChange:1"
        #expect(TrackRateDetector.parseCodec(fromEventMessage: line) == "qlac")
        #expect(TrackRateDetector.codecDisplayName("qlac") == "ALAC")
        #expect(TrackRateDetector.codecDisplayName("alac") == "ALAC")
        #expect(TrackRateDetector.codecDisplayName("paac") == "AAC")
        #expect(TrackRateDetector.parseCodec(fromEventMessage: "no format here") == nil)
    }

    @Test func builtInPresetsAreWellFormed() {
        #expect(!BuiltInPresets.all.isEmpty)
        for preset in BuiltInPresets.all {
            #expect(preset.bands.count == 10)
            #expect(preset.bands.allSatisfy { abs($0.gainDB) <= 24 })
        }
        let flat = BuiltInPresets.all.first { $0.name == "Flat" }
        #expect(flat?.bands.allSatisfy { $0.gainDB == 0 } == true)
    }

    @Test func settingsDecodeWithoutNewerKeys() throws {
        let legacy = #"{"isEnabled":true,"preGainDB":-3}"#
        let settings = try JSONDecoder().decode(EQSettings.self, from: Data(legacy.utf8))
        #expect(settings.isEnabled)
        #expect(settings.followTrackRate)
        #expect(!settings.bands.isEmpty)
    }

    @Test func nyquistClampKeepsHighBandsStable() {
        // A 16 kHz shelf at a 32 kHz device rate would sit above Nyquist
        // without the clamp in BiquadCoefficients.make.
        let c = BiquadCoefficients.make(type: .highShelf, frequency: 16_000, gainDB: 6, q: 0.707, sampleRate: 32_000)
        var state = BiquadState()
        for n in 0..<10_000 {
            let y = state.process(n == 0 ? 1 : 0, c)
            #expect(y.isFinite)
        }
    }
}
