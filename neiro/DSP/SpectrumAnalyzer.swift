import Accelerate
import Foundation
import Synchronization

/// Carries audio from the realtime IO thread to the UI for display.
///
/// The IO thread only ever writes into a pre-allocated ring buffer and bumps
/// an atomic counter — no allocation, no locks, no unbounded work. The UI
/// thread reads the most recent window whenever it wants to draw, so a slow or
/// idle UI simply misses frames instead of stalling audio.
final class SpectrumTap {
    static let fftSize = 1024
    private static let capacity = 4096      // power of two: masking replaces modulo

    private let samples: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    /// Set by the UI while the panel is visible; when false the IO thread
    /// skips the copy entirely, so a closed panel costs nothing.
    private let isActive = Atomic<Bool>(false)

    init() {
        samples = .allocate(capacity: Self.capacity)
        samples.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { samples.deallocate() }

    func setActive(_ active: Bool) {
        isActive.store(active, ordering: .relaxed)
    }

    var isCapturing: Bool { isActive.load(ordering: .relaxed) }

    /// Realtime-safe. `buffer` is interleaved; channels are summed to mono
    /// because the display is a single spectrum.
    func write(_ buffer: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard isActive.load(ordering: .relaxed), channels > 0 else { return }
        var index = writeIndex.load(ordering: .relaxed)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += buffer[frame * channels + channel]
            }
            samples[index & (Self.capacity - 1)] = sum * scale
            index &+= 1
        }
        writeIndex.store(index, ordering: .releasing)
    }

    /// Copies the most recent `fftSize` samples in chronological order.
    /// Returns false when nothing has been captured yet.
    func latestWindow(into destination: UnsafeMutablePointer<Float>) -> Bool {
        let end = writeIndex.load(ordering: .acquiring)
        guard end >= Self.fftSize else { return false }
        let start = end - Self.fftSize
        for i in 0..<Self.fftSize {
            destination[i] = samples[(start + i) & (Self.capacity - 1)]
        }
        return true
    }
}

/// Turns the captured window into log-spaced magnitudes in dB, ready to draw
/// on the same frequency axis as the EQ response curve.
final class SpectrumAnalyzer {
    /// Number of points along the log-frequency axis.
    static let binCount = 96
    static let minFrequency = 20.0
    static let maxFrequency = 20_000.0
    /// Displayed dynamic range; anything quieter reads as silence.
    static let floorDB: Float = -78
    static let ceilingDB: Float = -6

    private let size = SpectrumTap.fftSize
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    /// Smoothed output — a raw FFT flickers too much to read.
    private(set) var levels: [Float]

    init() {
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)
        levels = [Float](repeating: 0, count: Self.binCount)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Frequency of display bin `index`, log-spaced across the audible range.
    static func frequency(forBin index: Int) -> Double {
        let fraction = Double(index) / Double(binCount - 1)
        return minFrequency * pow(maxFrequency / minFrequency, fraction)
    }

    /// Runs one analysis pass. `attack`/`release` shape how quickly the
    /// display rises and falls (rise fast, fall slow — that is what makes a
    /// meter readable).
    func analyze(window input: UnsafePointer<Float>, sampleRate: Double) {
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(size))

        windowed.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                real.withUnsafeMutableBufferPointer { realPtr in
                    imaginary.withUnsafeMutableBufferPointer { imagPtr in
                        var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                                    imagp: imagPtr.baseAddress!)
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
                    }
                }
            }
        }

        // vDSP's real FFT returns twice the amplitude; fold that in with the
        // window's coherent gain so the dB scale means something.
        var scale = 2 / Float(size)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(size / 2))

        let binWidth = sampleRate / Double(size)
        let topBin = magnitudes.count - 1
        for index in 0..<Self.binCount {
            // Split at the geometric midpoints between neighbouring display
            // bins. Spanning a full bin either side made every display bin
            // see its neighbours' energy, which dragged a pure tone's peak
            // audibly (and visibly) below its real frequency.
            let center = Self.frequency(forBin: index)
            let lower = index > 0
                ? (Self.frequency(forBin: index - 1) * center).squareRoot()
                : center
            let upper = index < Self.binCount - 1
                ? (center * Self.frequency(forBin: index + 1)).squareRoot()
                : center
            // Where a display bin is narrower than the FFT resolution this
            // collapses to the single nearest bin, which is the best the
            // transform can offer.
            let lowBin = min(max(Int((lower / binWidth).rounded()), 1), topBin)
            let highBin = min(max(Int((upper / binWidth).rounded()), lowBin), topBin)

            var peak: Float = 0
            for bin in lowBin...highBin { peak = max(peak, magnitudes[bin]) }
            let db = 20 * log10(max(peak, 1e-9))
            let normalized = min(max((db - Self.floorDB) / (Self.ceilingDB - Self.floorDB), 0), 1)
            let previous = levels[index]
            let coefficient: Float = normalized > previous ? 0.55 : 0.12
            levels[index] = previous + (normalized - previous) * coefficient
        }
    }

    /// Fades the display toward silence when no audio is arriving.
    func decay() {
        for index in levels.indices {
            levels[index] *= 0.82
        }
    }
}
