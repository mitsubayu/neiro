import Testing
@testable import neiro
import Foundation

struct SpectrumTests {
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
}
