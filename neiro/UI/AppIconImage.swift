import AppKit

/// The app icon, at a size worth looking at.
///
/// `NSApp.applicationIconImage` hands back a single 128 px representation, so
/// anything drawn larger — the artwork placeholder at 147 pt, the help header —
/// is an upscale and looks soft. Resolving the icon by name gives the same
/// artwork with its full ladder (up to 2048 px), and AppKit then picks the
/// representation that fits the drawn size.
@MainActor
enum AppIconImage {
    static let full: NSImage = NSImage(named: NSImage.applicationIconName)
        ?? NSApp.applicationIconImage
}
