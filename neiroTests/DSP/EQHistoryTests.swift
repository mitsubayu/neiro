import Testing
@testable import neiro

struct EQHistoryTests {
    private func snapshot(_ gain: Double, pre: Double = 0) -> EQSnapshot {
        var settings = EQSettings.makeDefault()
        settings.bands[0].gainDB = gain
        settings.preGainDB = pre
        return EQSnapshot(settings)
    }

    @Test func historyWalksBackAndForward() {
        var history = EQHistory()
        #expect(!history.canUndo && !history.canRedo)

        let flat = snapshot(0), boosted = snapshot(6), cut = snapshot(-3)
        history.commit(previous: flat)     // flat → boosted
        history.commit(previous: boosted)  // boosted → cut

        #expect(history.canUndo)
        #expect(history.undo(current: cut) == boosted)
        #expect(history.undo(current: boosted) == flat)
        #expect(history.undo(current: flat) == nil, "nothing left to undo")

        #expect(history.canRedo)
        #expect(history.redo(current: flat) == boosted)
        #expect(history.redo(current: boosted) == cut)
        #expect(history.redo(current: cut) == nil)
    }

    @Test func newEditEndsTheRedoBranch() {
        var history = EQHistory()
        history.commit(previous: snapshot(0))
        _ = history.undo(current: snapshot(6))
        #expect(history.canRedo)

        history.commit(previous: snapshot(0))
        #expect(!history.canRedo, "editing after undo must drop the redo branch")
    }

    @Test func historyIsBounded() {
        var history = EQHistory()
        for i in 0..<(EQHistory.limit + 20) {
            history.commit(previous: snapshot(Double(i)))
        }
        #expect(history.undoStack.count == EQHistory.limit)
        // The oldest entries fall off, the newest survive. (Compare by value:
        // each snapshot carries freshly generated band ids.)
        #expect(history.undoStack.last?.bands.first?.gainDB == Double(EQHistory.limit + 19))
        #expect(history.undoStack.first?.bands.first?.gainDB == 20)
    }
}
