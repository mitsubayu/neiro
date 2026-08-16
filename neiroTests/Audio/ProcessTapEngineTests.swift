import CoreAudio
import Testing
@testable import neiro

struct ProcessTapEngineTests {
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
}
