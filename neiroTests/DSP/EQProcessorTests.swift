import Testing
@testable import neiro

/// What the realtime path actually does to samples.
struct EQProcessorTests {
    let sampleRate = 48_000.0

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
}
