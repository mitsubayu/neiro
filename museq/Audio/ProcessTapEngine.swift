import CoreAudio
import Foundation

/// Owns the process tap → aggregate device → IOProc chain.
///
/// All mutating calls must happen on `controlQueue` (HAL setup calls can
/// block). The IO block runs on the HAL realtime thread and touches only
/// `EQProcessor` and raw buffers.
final class ProcessTapEngine {
    let controlQueue = DispatchQueue(label: "museq.engine.control")

    private let processor: EQProcessor
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
    func start(musicProcess: AudioObjectID, outputDeviceUID: String) throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        stopLocked()

        let description = CATapDescription(stereoMixdownOfProcesses: [NSNumber(value: musicProcess)])
        description.name = "museq-tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var newTapID = AudioObjectID.unknown
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID.isValid else {
            throw CoreAudioError(status: status, operation: "Create process tap (check System Audio Recording permission)")
        }
        tapID = newTapID

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "museq-aggregate",
            kAudioAggregateDeviceUIDKey: "com.mitsuba.museq.aggregate",
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
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, nil) {
            _, inInputData, _, outOutputData, _ in
            ProcessTapEngine.render(input: inInputData, output: outOutputData, processor: processor)
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
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        stopLocked()
    }

    /// Idempotent teardown in strict reverse order of construction.
    private func stopLocked() {
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
                               processor: EQProcessor) {
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let inputBuffer = inputList.first(where: { $0.mData != nil && $0.mDataByteSize > 0 }),
              let inputData = inputBuffer.mData?.assumingMemoryBound(to: Float32.self) else {
            for buffer in outputList {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }

        let inputChannels = max(Int(inputBuffer.mNumberChannels), 1)
        let frames = Int(inputBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * inputChannels)
        processor.process(inputData, frames: frames, channels: inputChannels)

        for buffer in outputList {
            guard let outData = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let outChannels = max(Int(buffer.mNumberChannels), 1)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
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
