import Foundation
import Synchronization

/// Applies pre-gain plus a cascade of biquads to interleaved Float32 audio.
///
/// Coefficients are published from the UI/control threads to the realtime
/// thread via two pre-allocated banks and an atomic active-bank index
/// (write inactive bank → release-store index; reader acquire-loads once per
/// callback). If the UI flips banks twice within a single callback the reader
/// can see a mid-update coefficient set; individual aligned Float loads are
/// atomic on arm64, so the worst case is a one-buffer audible transient, which
/// we accept in exchange for a lock-free realtime path.
final class EQProcessor {
    private struct BankHeader {
        var bandCount: Int = 0
        var preGain: Float = 1
    }

    private let maxBands = EQSettings.maxBands
    private let maxChannels = 2

    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let headers: UnsafeMutablePointer<BankHeader>
    private let states: UnsafeMutablePointer<BiquadState>
    private let activeBank = Atomic<Int>(0)
    private let mutedFlag = Atomic<Bool>(false)
    private let bypassFlag = Atomic<Bool>(false)

    // Serializes writers (main thread UI updates vs. control-queue sample-rate
    // changes). Never touched by the realtime thread.
    private let writerLock = NSLock()
    private var settings = EQSettings.makeDefault()
    private var sampleRate: Double = 44_100

    init() {
        coefficients = .allocate(capacity: 2 * maxBands)
        coefficients.initialize(repeating: .identity, count: 2 * maxBands)
        headers = .allocate(capacity: 2)
        headers.initialize(repeating: BankHeader(), count: 2)
        states = .allocate(capacity: maxBands * maxChannels)
        states.initialize(repeating: BiquadState(), count: maxBands * maxChannels)
    }

    deinit {
        coefficients.deallocate()
        headers.deallocate()
        states.deallocate()
    }

    func update(settings: EQSettings) {
        writerLock.lock()
        defer { writerLock.unlock() }
        self.settings = settings
        bypassFlag.store(settings.isBypassed, ordering: .relaxed)
        publishLocked()
    }

    func setSampleRate(_ rate: Double) {
        writerLock.lock()
        defer { writerLock.unlock() }
        sampleRate = rate
        publishLocked()
    }

    private func publishLocked() {
        let bank = 1 - activeBank.load(ordering: .relaxed)
        let bankCoefficients = coefficients + bank * maxBands
        let activeBands = settings.bands.filter { $0.isEnabled && $0.gainDB != 0 }.prefix(maxBands)
        for (index, band) in activeBands.enumerated() {
            bankCoefficients[index] = .make(type: band.type, frequency: band.frequency,
                                            gainDB: band.gainDB, q: band.q, sampleRate: sampleRate)
        }
        headers[bank] = BankHeader(bandCount: activeBands.count,
                                   preGain: Float(pow(10, settings.preGainDB / 20)))
        activeBank.store(bank, ordering: .releasing)
    }

    /// Silences output while a pending sample-rate switch would otherwise play
    /// the track head at the wrong rate. Safe to call from any thread.
    func setMuted(_ muted: Bool) {
        mutedFlag.store(muted, ordering: .relaxed)
    }

    /// Realtime-safe. `buffer` is interleaved with `channels` samples per frame.
    func process(_ buffer: UnsafeMutablePointer<Float32>, frames: Int, channels: Int) {
        if mutedFlag.load(ordering: .relaxed) {
            for i in 0..<(frames * channels) {
                buffer[i] = 0
            }
            return
        }
        // Bypass leaves the samples exactly as the tap delivered them, so an
        // A/B comparison changes nothing but the processing.
        if bypassFlag.load(ordering: .relaxed) { return }
        let bank = activeBank.load(ordering: .acquiring)
        let header = headers[bank]
        let bankCoefficients = coefficients + bank * maxBands
        let usedChannels = min(channels, maxChannels)

        if header.preGain != 1 {
            for i in 0..<(frames * channels) {
                buffer[i] *= header.preGain
            }
        }
        guard header.bandCount > 0 else { return }

        for channel in 0..<usedChannels {
            for band in 0..<header.bandCount {
                let c = bankCoefficients[band]
                var state = states[band * maxChannels + channel]
                var index = channel
                for _ in 0..<frames {
                    buffer[index] = state.process(buffer[index], c)
                    index += channels
                }
                states[band * maxChannels + channel] = state
            }
        }
    }
}
