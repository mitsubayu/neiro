import Testing
@testable import neiro
import Foundation

/// The filter maths: does a coefficient set produce the response it promises,
/// and does it stay stable when asked for something extreme?
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
