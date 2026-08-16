import AppKit

/// Text for the standard About window. The copyright lives here rather than
/// in Info.plist's NSHumanReadableCopyright because that key is plain text —
/// the credits string is the only part of the panel that can carry a link.
enum AboutCredits {
    static let authorURL = URL(string: "https://x.com/mitsuba_yu")!
    static let authorName = "mitsubayu"

    private static var blurb: String {
        [
            "Full-rate playback and parametric EQ for Apple Music.",
            "Captures Music.app with a Core Audio process tap, follows each track's own sample rate, and plays it back through the output device you choose.",
            "Designed and built by \(authorName) with claude.",
            "",
        ].joined(separator: "\n\n")
    }

    static func attributedString() -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let credits = NSMutableAttributedString(string: blurb, attributes: body)
        credits.append(NSAttributedString(string: "© 2026 ", attributes: body))
        credits.append(NSAttributedString(string: authorName, attributes: body.merging([
            .link: authorURL,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]) { _, new in new }))

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered,
                             range: NSRange(location: 0, length: credits.length))
        return credits
    }
}
