import Foundation

/// The part of the settings that undo covers: the sound shaping. Output
/// device, login item and the like are deliberately excluded — undoing your
/// way back to a different DAC would be a surprise, not a convenience.
struct EQSnapshot: Equatable {
    var bands: [EQBand]
    var preGainDB: Double

    init(_ settings: EQSettings) {
        bands = settings.bands
        preGainDB = settings.preGainDB
    }
}

/// Plain undo/redo stacks. Coalescing a drag into one entry is the caller's
/// job (it knows when a value has settled); this type only holds history.
struct EQHistory: Equatable {
    static let limit = 50

    private(set) var undoStack: [EQSnapshot] = []
    private(set) var redoStack: [EQSnapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records the state as it was *before* the change that just settled.
    mutating func commit(previous: EQSnapshot) {
        undoStack.append(previous)
        if undoStack.count > Self.limit {
            undoStack.removeFirst(undoStack.count - Self.limit)
        }
        // A fresh edit ends the redo branch, as everywhere else on the system.
        redoStack.removeAll()
    }

    mutating func undo(current: EQSnapshot) -> EQSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(current: EQSnapshot) -> EQSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
