import Testing
@testable import neiro
import AppKit

struct MenuBarTests {
    @MainActor
    @Test func marqueeSlotWidthRules() {
        let view = StatusMarqueeView()
        let suffix = "· ALAC 44.1kHz/16bit"

        view.update(title: "初恋", suffix: suffix)
        let short = view.desiredWidth
        view.update(title: "Howling over the World and the Moon", suffix: suffix)
        let long1 = view.desiredWidth
        view.update(title: "Howling over the World and the Moon and Beyond the Stars", suffix: suffix)
        let long2 = view.desiredWidth

        // Short titles take only their text width; anything long enough to
        // marquee is capped at the fixed 110pt slot regardless of length.
        #expect(short < long1)
        #expect(long1 == long2)

        view.update(title: "", suffix: suffix)
        let noTitle = view.desiredWidth
        #expect(noTitle < short)
        view.update(title: "", suffix: "")
        #expect(view.desiredWidth < noTitle)
    }

    @MainActor
    @Test func aboutCreditsLinkTheAuthor() {
        let credits = AboutCredits.attributedString()
        let text = credits.string
        #expect(text.contains("© 2026 \(AboutCredits.authorName)"))

        var linkedRange = NSRange()
        let link = credits.attribute(.link, at: credits.length - 1, effectiveRange: &linkedRange) as? URL
        #expect(link == AboutCredits.authorURL)
        // Only the name is clickable, not the whole blurb.
        #expect((text as NSString).substring(with: linkedRange) == AboutCredits.authorName)
    }
}
