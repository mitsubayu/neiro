import Testing
@testable import museq
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
