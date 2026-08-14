import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation) failed (OSStatus \(status))"
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

extension AudioObjectID {
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 into value: inout T,
                 qualifier: UnsafeMutableRawPointer? = nil,
                 qualifierSize: UInt32 = 0) throws {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var dataSize = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, qualifierSize, qualifier, &dataSize, ptr)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "Get property \(fourCC(selector))")
        }
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "Get size of \(fourCC(selector))")
        }
        let count = Int(dataSize) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        status = values.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, raw.baseAddress!)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "Get property \(fourCC(selector))")
        }
        return values
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var value: CFString = "" as CFString
        try read(selector, scope: scope, into: &value)
        return value as String
    }

    func readUInt32(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var value: UInt32 = 0
        try read(selector, scope: scope, into: &value)
        return value
    }

    func readDouble(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> Double {
        var value: Double = 0
        try read(selector, scope: scope, into: &value)
        return value
    }
}

/// Keeps an `AudioObjectAddPropertyListenerBlock` registered for its lifetime.
final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init?(objectID: AudioObjectID,
          selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          queue: DispatchQueue,
          handler: @escaping () -> Void) {
        self.objectID = objectID
        self.address = AudioObjectPropertyAddress(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard status == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}

func fourCC(_ value: UInt32) -> String {
    let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                 UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
    return String(value)
}
