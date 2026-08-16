import Testing
@testable import neiro

/// Parsing Music's log lines. These strings are copied from real unified-log
/// output — Apple can change them at any release, and a failure here is the
/// first sign that rate following has gone blind.
struct TrackRateDetectorTests {
    @Test func trackRateParsing() {
        let real = "<<<< FAQ >>>> subaq_buildCAAudioQueue: [0xaf0671f80:0xafc62f480] RP/DO.07 Creating AudioQueue with format:'qlac', framesPerPacket:4096, sampleRate:96000, releasePlayResourceForFormatChange:1 notificationToken: 84dac35f6"
        #expect(TrackRateDetector.parseSampleRate(fromEventMessage: real) == 96000)
        #expect(TrackRateDetector.parseSampleRate(fromEventMessage: "sampleRate:44100,") == 44100)
        #expect(TrackRateDetector.parseSampleRate(fromEventMessage: "no rate here") == nil)
        #expect(TrackRateDetector.parseSampleRate(fromEventMessage: "sampleRate:1") == nil)
    }

    @Test func outputFormatParsing() {
        let alac = "ACAppleLosslessDecoder.cpp:683   (0xb01282880) Output format:  2 ch,  96000 Hz, lpcm (0x0000000C) 24-bit little-endian signed integer"
        let parsed = TrackRateDetector.parseOutputFormat(fromEventMessage: alac)
        #expect(parsed?.sampleRate == 96000)
        #expect(parsed?.bitDepth == 24)

        let aac = "ACMP4AACBaseDecoder.cpp:313   (0xb) Output format:  2 ch,  44100 Hz, lpcm (0x29) 32-bit little-endian float, deinterleaved"
        let parsedFloat = TrackRateDetector.parseOutputFormat(fromEventMessage: aac)
        #expect(parsedFloat?.sampleRate == 44100)
        #expect(parsedFloat?.bitDepth == nil)

        let cdQuality = "ACAppleLosslessDecoder.cpp:683   (0xaeda13200) Output format:  2 ch,  44100 Hz, Int16, interleaved"
        let parsedInt16 = TrackRateDetector.parseOutputFormat(fromEventMessage: cdQuality)
        #expect(parsedInt16?.sampleRate == 44100)
        #expect(parsedInt16?.bitDepth == 16)

        #expect(TrackRateDetector.parseOutputFormat(fromEventMessage: "Input format:  2 ch,  96000 Hz, qlac") == nil)

        // The generic wrapper mixes in the *device* rate, so its lines must
        // not be treated as the track's format.
        let wrapper = "ACCPEDecoderWrapper.cpp:322   (0xa866b8ba0) Output format:  2 ch,  48000 Hz, Int16, interleaved"
        #expect(TrackRateDetector.parseOutputFormat(fromEventMessage: wrapper) == nil)
        #expect(!TrackRateDetector.isUnrecognizedDecoderLine(wrapper))
        #expect(!TrackRateDetector.isUnrecognizedDecoderLine(alac))
        #expect(TrackRateDetector.isUnrecognizedDecoderLine(
            "ACFutureCodecDecoder.cpp:12   (0x1) Output format:  2 ch,  352800 Hz, Int32"))
    }

    @Test func codecParsing() {
        let line = "<<<< FAQ >>>> subaq_buildCAAudioQueue: [0x9:0x9] RP/ZZ.25 Creating AudioQueue with format:'qlac', framesPerPacket:4096, sampleRate:48000, releasePlayResourceForFormatChange:1"
        #expect(TrackRateDetector.parseCodec(fromEventMessage: line) == "qlac")
        #expect(TrackRateDetector.codecDisplayName("qlac") == "ALAC")
        #expect(TrackRateDetector.codecDisplayName("alac") == "ALAC")
        #expect(TrackRateDetector.codecDisplayName("paac") == "AAC")
        #expect(TrackRateDetector.parseCodec(fromEventMessage: "no format here") == nil)
    }

    @Test func decoderCodecParsing() {
        let alac = "ACAppleLosslessDecoder.cpp:683   (0xaedce8f00) Output format:  2 ch,  96000 Hz, lpcm (0x0000000C) 24-bit little-endian signed integer"
        #expect(TrackRateDetector.parseDecoderCodec(fromEventMessage: alac) == "ALAC")

        let aac = "ACMP4AACBaseDecoder.cpp:313   (0xa8129ce00) Output format:  2 ch,  48000 Hz, Float32, deinterleaved"
        #expect(TrackRateDetector.parseDecoderCodec(fromEventMessage: aac) == "AAC")

        // The generic wrapper names no format — better nothing than a guess.
        let wrapper = "ACCPEDecoderWrapper.cpp:322   (0xa866b8ba0) Output format:  2 ch,  48000 Hz, Int16, interleaved"
        #expect(TrackRateDetector.parseDecoderCodec(fromEventMessage: wrapper) == nil)

        #expect(TrackRateDetector.parseDecoderCodec(fromEventMessage: "Creating AudioQueue with format:'qlac'") == nil)
    }
}
