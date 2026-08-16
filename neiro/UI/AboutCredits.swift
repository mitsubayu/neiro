import AppKit

/// Text for the standard About window. The copyright lives here rather than
/// in Info.plist's NSHumanReadableCopyright because that key is plain text —
/// the credits string is the only part of the panel that can carry a link.
enum AboutCredits {
    static let authorURL = URL(string: "https://x.com/mitsuba_yu")!
    static let authorName = "mitsubayu"

    /// Kept short and quiet: the About window is an identity card, not
    /// documentation. The details live in Help.
    static func attributedString() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 10

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "Full-rate playback and parametric EQ for Apple Music.\n",
            attributes: body))
        credits.append(NSAttributedString(
            string: "Designed and built by \(authorName) with claude.\n",
            attributes: quiet))
        credits.append(NSAttributedString(string: "© 2026 ", attributes: quiet))
        // No underline: the link colour is enough, and underlines make a
        // one-line footer look busy.
        credits.append(NSAttributedString(string: authorName, attributes: quiet.merging([
            .link: authorURL,
            .foregroundColor: NSColor.linkColor,
        ]) { _, new in new }))
        return credits
    }
}
