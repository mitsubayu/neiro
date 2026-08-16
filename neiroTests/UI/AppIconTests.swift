import Testing
@testable import neiro
import AppKit

struct AppIconTests {
    @MainActor
    @Test func iconIsSharpEnoughToDrawLarge() {
        func widest(_ image: NSImage) -> Int {
            image.representations.map(\.pixelsWide).max() ?? 0
        }
        // The artwork placeholder draws at 147 pt — 294 px on a Retina display.
        #expect(widest(AppIconImage.full) >= 512)
        // Why the indirection exists at all: the obvious accessor is 128 px.
        #expect(widest(NSApp.applicationIconImage) <= 128)
    }
}
