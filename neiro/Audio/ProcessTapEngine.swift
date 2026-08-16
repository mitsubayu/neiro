import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import os

/// Owns the process tap → aggregate device → IOProc chain.
///
/// All mutating calls must happen on `controlQueue` (HAL setup calls can
/// block). The IO block runs on the HAL realtime thread and touches only
/// `EQProcessor` and raw buffers.
final class ProcessTapEngine {
    let controlQueue = DispatchQueue(label: "neiro.engine.control")

    /// Incremented from the realtime thread, read from a control-queue timer.
    final class Diagnostics {
        let callbacks = Atomic<UInt64>(0)
        let zeroInputCallbacks = Atomic<UInt64>(0)
        let frameMismatchCallbacks = Atomic<UInt64>(0)
        let lastInputFrames = Atomic<Int>(0)
        let lastOutputFrames = Atomic<Int>(0)
    }

    private static let logger = Logger(subsystem: "com.mitsuba.neiro", category: "engine")

    private let processor: EQProcessor
    private let diagnostics = Diagnostics()
    private var diagnosticsTimer: DispatchSourceTimer?
    private var overloadListener: PropertyListener?
    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRateListener: PropertyListener?

    private(set) var sampleRate: Double = 44_100
    var onSampleRateChange: ((Double) -> Void)?

    init(processor: EQProcessor) {
        self.processor = processor
    }

    var isRunning: Bool { aggregateID.isValid }

    /// Builds and starts the full chain. Throws CoreAudioError; a failure from
    /// AudioHardwareCreateProcessTap usually means the TCC audio-capture
    /// permission was denied.
    ///
    /// `preferredRate` overrides the tap's current rate as the device-rate
    /// target — used when the track's source rate is known but Music is still
    /// (or was last) rendering at the old device rate.
    func start(musicProcess: AudioObjectID, outputDeviceUID: String, preferredRate: Double? = nil) throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        stopLocked()

        let description = CATapDescription(stereoMixdownOfProcesses: [musicProcess])
        description.name = "neiro-tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var newTapID = AudioObjectID.unknown
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID.isValid else {
            throw CoreAudioError(status: status, operation: "Create process tap (check System Audio Recording permission)")
        }
        tapID = newTapID

        var tapFormat = AudioStreamBasicDescription()
        let haveFormat = (try? tapID.read(kAudioTapPropertyFormat, into: &tapFormat)) != nil
        Self.logger.info("tap format: rate=\(tapFormat.mSampleRate) channels=\(tapFormat.mChannelsPerFrame) flags=\(tapFormat.mFormatFlags)")
        // The IO block reads the tap's buffers as interleaved 32-bit float.
        // Rather than emit noise if a future macOS hands us something else,
        // refuse to run: the tap is torn down, so Music simply plays
        // unprocessed through its own device.
        if haveFormat, let problem = Self.unsupportedFormatReason(tapFormat) {
            stopLocked()
            throw CoreAudioError(status: OSStatus(kAudioFormatUnsupportedDataFormatError),
                                 operation: "Unsupported tap format (\(problem))")
        }

        matchOutputDeviceRate(outputDeviceUID: outputDeviceUID, to: preferredRate ?? tapFormat.mSampleRate)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "neiro-aggregate",
            kAudioAggregateDeviceUIDKey: neiroAggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString,
                 // The tap and the output device run on different clocks; let
                 // the HAL resample the tap into the device's clock domain.
                 kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        var newAggregateID = AudioObjectID.unknown
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID.isValid else {
            stopLocked()
            throw CoreAudioError(status: status, operation: "Create aggregate device")
        }
        aggregateID = newAggregateID

        sampleRate = (try? aggregateID.readDouble(kAudioDevicePropertyNominalSampleRate)) ?? 44_100
        processor.setSampleRate(sampleRate)

        sampleRateListener = PropertyListener(objectID: aggregateID,
                                              selector: kAudioDevicePropertyNominalSampleRate,
                                              queue: controlQueue) { [weak self] in
            guard let self, self.aggregateID.isValid else { return }
            let rate = (try? self.aggregateID.readDouble(kAudioDevicePropertyNominalSampleRate)) ?? self.sampleRate
            guard rate != self.sampleRate, rate > 0 else { return }
            self.sampleRate = rate
            self.processor.setSampleRate(rate)
            self.onSampleRateChange?(rate)
        }

        // Passing nil for the dispatch queue runs the block directly on the
        // HAL's realtime I/O thread — required for deterministic playthrough.
        let processor = self.processor
        var newIOProcID: AudioDeviceIOProcID?
        let diagnostics = self.diagnostics
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, nil) {
            _, inInputData, _, outOutputData, _ in
            ProcessTapEngine.render(input: inInputData, output: outOutputData,
                                    processor: processor, diagnostics: diagnostics)
        }
        guard status == noErr, let procID = newIOProcID else {
            stopLocked()
            throw CoreAudioError(status: status, operation: "Create IOProc")
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stopLocked()
            throw CoreAudioError(status: status, operation: "Start aggregate device")
        }

        Self.logger.info("engine started: aggregate rate=\(self.sampleRate) output=\(outputDeviceUID)")
        startDiagnostics()
    }

    /// nil when the format is one the IO block can handle.
    static func unsupportedFormatReason(_ format: AudioStreamBasicDescription) -> String? {
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { return nil }
        if format.mFormatID != kAudioFormatLinearPCM { return "not linear PCM" }
        let flags = format.mFormatFlags
        if flags & kAudioFormatFlagIsFloat == 0 { return "not float" }
        if flags & kAudioFormatFlagIsNonInterleaved != 0 { return "non-interleaved" }
        if format.mBitsPerChannel != 32 { return "\(format.mBitsPerChannel)-bit" }
        return nil
    }

    /// Sets the output device's nominal rate to the tap's rate when supported,
    /// so the HAL's tap resampler runs 1:1 instead of e.g. 48k→44.1k.
    private func matchOutputDeviceRate(outputDeviceUID: String, to tapRate: Double) {
        guard tapRate > 0 else { return }
        let deviceIDs: [AudioObjectID] = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)) ?? []
        guard let deviceID = deviceIDs.first(where: { (try? $0.readString(kAudioDevicePropertyDeviceUID)) == outputDeviceUID })
        else { return }

        let currentRate = (try? deviceID.readDouble(kAudioDevicePropertyNominalSampleRate)) ?? 0
        guard currentRate != tapRate else { return }

        let supported: [AudioValueRange] = (try? deviceID.readArray(kAudioDevicePropertyAvailableNominalSampleRates)) ?? []
        guard supported.contains(where: { $0.mMinimum <= tapRate && tapRate <= $0.mMaximum }) else {
            Self.logger.warning("output device does not support tap rate \(tapRate); keeping \(currentRate)")
            return
        }

        var newRate = tapRate
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                                UInt32(MemoryLayout<Double>.size), &newRate)
        guard status == noErr else {
            Self.logger.warning("failed to set output rate to \(tapRate): \(status)")
            return
        }
        // The switch is asynchronous on USB devices; wait until it lands so
        // the aggregate is created against the new rate.
        for _ in 0..<20 {
            if (try? deviceID.readDouble(kAudioDevicePropertyNominalSampleRate)) == tapRate { break }
            usleep(100_000)
        }
        Self.logger.info("output device rate matched to \(tapRate)")
    }

    private func startDiagnostics() {
        overloadListener = PropertyListener(objectID: aggregateID,
                                            selector: kAudioDeviceProcessorOverload,
                                            queue: controlQueue) {
            Self.logger.error("processor overload on aggregate device")
        }

        var previousCallbacks: UInt64 = 0
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [diagnostics] in
            let callbacks = diagnostics.callbacks.load(ordering: .relaxed)
            Self.logger.info("""
                diag: callbacks=\(callbacks) (+\(callbacks - previousCallbacks)/5s) \
                zeroInput=\(diagnostics.zeroInputCallbacks.load(ordering: .relaxed)) \
                frameMismatch=\(diagnostics.frameMismatchCallbacks.load(ordering: .relaxed)) \
                lastFrames in=\(diagnostics.lastInputFrames.load(ordering: .relaxed)) \
                out=\(diagnostics.lastOutputFrames.load(ordering: .relaxed))
                """)
            previousCallbacks = callbacks
        }
        timer.resume()
        diagnosticsTimer = timer
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        stopLocked()
    }

    /// Idempotent teardown in strict reverse order of construction.
    private func stopLocked() {
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        overloadListener = nil
        sampleRateListener = nil
        if let procID = ioProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    /// Realtime callback body: EQ the tapped input in place, then fan it out
    /// to the output buffers. No allocation, locks, or ObjC dispatch here.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               processor: EQProcessor,
                               diagnostics: Diagnostics) {
        diagnostics.callbacks.wrappingAdd(1, ordering: .relaxed)
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let inputBuffer = inputList.first(where: { $0.mData != nil && $0.mDataByteSize > 0 }),
              let inputData = inputBuffer.mData?.assumingMemoryBound(to: Float32.self) else {
            diagnostics.zeroInputCallbacks.wrappingAdd(1, ordering: .relaxed)
            for buffer in outputList {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }

        let inputChannels = max(Int(inputBuffer.mNumberChannels), 1)
        let frames = Int(inputBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * inputChannels)
        diagnostics.lastInputFrames.store(frames, ordering: .relaxed)
        processor.process(inputData, frames: frames, channels: inputChannels)

        for buffer in outputList {
            guard let outData = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let outChannels = max(Int(buffer.mNumberChannels), 1)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
            diagnostics.lastOutputFrames.store(outFrames, ordering: .relaxed)
            if outFrames != frames {
                diagnostics.frameMismatchCallbacks.wrappingAdd(1, ordering: .relaxed)
            }
            memset(outData, 0, Int(buffer.mDataByteSize))
            let copyFrames = min(frames, outFrames)
            let copyChannels = min(inputChannels, outChannels)
            for frame in 0..<copyFrames {
                for channel in 0..<copyChannels {
                    outData[frame * outChannels + channel] = inputData[frame * inputChannels + channel]
                }
            }
        }
    }
}
