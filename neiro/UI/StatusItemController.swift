import AppKit
import Observation
import SwiftUI
import os

/// AppKit status item hosting the marquee label and the SwiftUI popover.
/// Pure AppKit because MenuBarExtra's label snapshots custom views once
/// (freezing both the Core Animation marquee and the item's width).
@MainActor
final class StatusItemController: NSObject {
    private static let logger = Logger(subsystem: "com.mitsuba.neiro", category: "ui")
    static let panelWidth: CGFloat = 380

    private let appState: AppState
    private let statusItem: NSStatusItem
    private let marqueeView = StatusMarqueeView()
    private var marqueeWidthConstraint: NSLayoutConstraint?
    private var outsideClickMonitor: Any?

    // NSPopover.show silently no-ops in this configuration (macOS 26,
    // LSUIElement, SwiftUI lifecycle), so the panel is hand-rolled: a
    // borderless key-capable panel positioned under the status item.
    private var panelIfCreated: NSPanel?
    private var panelResizeObserver: NSObjectProtocol?
    private lazy var panel: NSPanel = {
        let host = NSHostingController(
            rootView: MenuBarRootView()
                .environment(appState)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12)))
        // Deliberately NOT .preferredContentSize: letting SwiftUI resize this
        // borderless panel recursed through Auto Layout until the stack blew
        // (folding the Bands section did it reliably). The panel is sized once
        // per open instead, and its content scrolls.
        host.sizingOptions = []
        let panel = KeyablePanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.appearance = nil  // inherit the system light/dark appearance
        panelIfCreated = panel
        return panel
    }()

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.addSubview(marqueeView)
            marqueeView.translatesAutoresizingMaskIntoConstraints = false
            // Self-contained size only: tying the marquee's height to the
            // button's let Auto Layout squash the button itself to a 2pt
            // strip, which made the status item practically unclickable.
            let widthConstraint = marqueeView.widthAnchor.constraint(equalToConstant: 18)
            marqueeWidthConstraint = widthConstraint
            NSLayoutConstraint.activate([
                marqueeView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
                marqueeView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                marqueeView.heightAnchor.constraint(equalToConstant: 22),
                widthConstraint,
            ])
        }
        observeState()
        refresh()
        Self.logger.error("status item init done, button=\(self.statusItem.button != nil)")
    }

    @objc private func togglePopover(_ sender: Any?) {
        panel.isVisible ? closePanel() : openPanel()
    }

    /// The dismiss-on-outside-click behaviour is what "pinned" turns off, so
    /// it is installed and removed from one place that both opening and the
    /// toggle can call.
    private func syncDismissMonitor() {
        let shouldDismiss = panelIfCreated?.isVisible == true && !appState.settings.panelPinned
        if shouldDismiss, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.closePanel() }
            }
        } else if !shouldDismiss, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main

        // Sized here, once, so nothing can resize the window while it is open.
        // A track on screen means the artwork is showing.
        let wantsArtwork = appState.nowPlayingTitle?.isEmpty == false
        var height: CGFloat = wantsArtwork ? 760 : 400
        if let visible = screen?.visibleFrame {
            height = min(height, visible.height - 24)
        }
        panel.setContentSize(NSSize(width: Self.panelWidth, height: height))
        panel.layoutIfNeeded()

        let size = panel.frame.size
        var x = buttonRect.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: buttonRect.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        syncDismissMonitor()
    }

    private func closePanel() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        panel.orderOut(nil)
    }

    /// Re-arms Observation tracking each time it fires — the AppKit
    /// equivalent of a SwiftUI view depending on these properties.
    private func observeState() {
        withObservationTracking {
            _ = appState.nowPlayingTitle
            _ = appState.menuBarSuffix
            _ = appState.status
            _ = appState.settings.panelPinned
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.observeState()
            }
        }
    }

    private func refresh() {
        let running = appState.status == .running
        let title = running ? (appState.nowPlayingTitle ?? "") : ""
        var suffix = running ? appState.menuBarSuffix : ""
        if !title.isEmpty, !suffix.isEmpty {
            suffix = "· " + suffix
        }
        marqueeView.update(title: title, suffix: suffix)
        marqueeWidthConstraint?.constant = marqueeView.desiredWidth
        statusItem.length = marqueeView.desiredWidth + 12
        syncDismissMonitor()
    }
}

/// Borderless windows refuse key status by default; the EQ panel needs it
/// for the preset-name text field.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Icon + scrolling title + static suffix. The scrolling text is a
/// CATextLayer whose bounds we set from the measured string width — plain
/// layer geometry, immune to the NSTextField/Auto Layout interactions that
/// kept truncating the doubled marquee string to the visible window.
final class StatusMarqueeView: NSView {
    private let iconView = NSImageView()
    private let titleClipView = NSView()
    private let titleLayer = CALayer()
    private let suffixView = NSView()
    private var titleWidth: CGFloat = 0
    private var loopWidth: CGFloat = 0
    private var suffixWidth: CGFloat = 0
    private var titleDisplayString = ""
    private var currentTitle = ""
    private var currentSuffix = ""

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let lineHeight: CGFloat = 17

    private static let loopGap = "        "
    private static let titleMaxWidth: CGFloat = 110
    private static let iconWidth: CGFloat = 18
    private static let gap: CGFloat = 5
    private static let speed: CGFloat = 30          // points per second
    private static let startHold: Double = 2
    private static let endHold: Double = 1

    init() {
        super.init(frame: .zero)
        iconView.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                 accessibilityDescription: "neiro")
        // Follow the menu bar's effective appearance (template symbols in a
        // plain NSImageView don't auto-tint like a status button image).
        iconView.contentTintColor = .labelColor
        titleClipView.wantsLayer = true
        titleClipView.layer?.masksToBounds = true
        titleLayer.anchorPoint = .zero
        titleLayer.contentsGravity = .topLeft
        titleLayer.contentsScale = 2  // corrected from the window's backing scale below
        titleClipView.layer?.addSublayer(titleLayer)
        titleClipView.autoresizingMask = []
        suffixView.wantsLayer = true
        suffixView.autoresizingMask = []
        addSubview(iconView)
        addSubview(titleClipView)
        addSubview(suffixView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    private func applyBackingScale() {
        guard let scale = window?.backingScaleFactor, scale > 0 else { return }
        titleLayer.contentsScale = scale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildTitleLayerString()
    }

    /// AppKit renders the string into an image (same crisp text rasterizer
    /// as real labels — CATextLayer's own drawing is visibly softer). Both
    /// the title and the suffix go through this renderer into equal-height
    /// boxes, so their baselines line up exactly.
    private func renderText(_ text: String, width: CGFloat) -> NSImage {
        let size = NSSize(width: max(width, 1), height: Self.lineHeight)
        let appearance = effectiveAppearance
        return NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                NSAttributedString(
                    string: text,
                    attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor]
                ).draw(in: rect)
            }
            return true
        }
    }

    /// Re-run on appearance changes so the baked-in labelColor matches
    /// light/dark mode.
    private func rebuildTitleLayerString() {
        if titleDisplayString.isEmpty {
            titleLayer.contents = nil
        } else {
            let width = loopWidth > 0 ? loopWidth + titleWidth : titleWidth
            titleLayer.contents = renderText(titleDisplayString, width: width)
        }
        suffixView.layer?.contents = currentSuffix.isEmpty
            ? nil
            : renderText(currentSuffix, width: suffixWidth)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Real mouse clicks must fall through to the status bar button
    // underneath (accessibility AXPress bypasses hit-testing, which is why
    // synthetic click tests passed while physical clicks did nothing).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Short titles get exactly their text width (no dead space before the
    /// suffix); only titles long enough to marquee use the full 110pt slot.
    private var titleSlotWidth: CGFloat {
        min(titleWidth, Self.titleMaxWidth)
    }

    var desiredWidth: CGFloat {
        var width = Self.iconWidth
        if !currentTitle.isEmpty {
            width += Self.gap + titleSlotWidth
        }
        if !currentSuffix.isEmpty {
            width += Self.gap + suffixWidth
        }
        return width
    }

    private func measure(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: Self.font]).size().width)
    }

    func update(title: String, suffix: String) {
        guard title != currentTitle || suffix != currentSuffix else { return }
        currentTitle = title
        currentSuffix = suffix

        titleWidth = measure(title)
        if titleWidth > Self.titleMaxWidth {
            // Two copies separated by a gap: when the animation wraps at
            // -loopWidth the second copy sits exactly where the first
            // started, so the loop continues forward instead of snapping.
            loopWidth = measure(title + Self.loopGap)
            titleDisplayString = title + Self.loopGap + title
        } else {
            loopWidth = 0
            titleDisplayString = title
        }
        suffixWidth = measure(suffix)
        rebuildTitleLayerString()
        titleLayer.frame = CGRect(x: 0, y: 0,
                                  width: loopWidth > 0 ? loopWidth + titleWidth : titleWidth,
                                  height: Self.lineHeight)

        titleClipView.isHidden = title.isEmpty
        suffixView.isHidden = suffix.isEmpty
        needsLayout = true
        restartAnimation()
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let iconSide: CGFloat = 16
        iconView.frame = NSRect(x: 0, y: (height - iconSide) / 2, width: Self.iconWidth, height: iconSide)
        var x = Self.iconWidth
        if !currentTitle.isEmpty {
            x += Self.gap
            // Integral-pixel origin: fractional offsets soften the glyphs.
            titleClipView.frame = NSRect(x: round(x), y: round((height - Self.lineHeight) / 2),
                                         width: titleSlotWidth, height: Self.lineHeight)
            x += titleSlotWidth
        }
        if !currentSuffix.isEmpty {
            x += Self.gap
            // Same height box and same y as the title window → identical
            // baseline.
            suffixView.frame = NSRect(x: round(x), y: round((height - Self.lineHeight) / 2),
                                      width: suffixWidth, height: Self.lineHeight)
        }
    }

    /// One cycle: hold at the title head → scroll until the tail is visible →
    /// hold a beat → keep scrolling forward through the gap until the next
    /// copy's head aligns → wrap on identical pixels → hold again. The title
    /// never scrolls backwards.
    private func restartAnimation() {
        titleLayer.removeAnimation(forKey: "marquee")
        guard loopWidth > 0 else { return }
        let tailOffset = titleWidth - Self.titleMaxWidth
        let tailScroll = Double(tailOffset / Self.speed)
        let wrapScroll = Double((loopWidth - tailOffset) / Self.speed)
        let total = Self.startHold + tailScroll + Self.endHold + wrapScroll
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -tailOffset, -tailOffset, -loopWidth]
        animation.keyTimes = [
            0,
            NSNumber(value: Self.startHold / total),
            NSNumber(value: (Self.startHold + tailScroll) / total),
            NSNumber(value: (Self.startHold + tailScroll + Self.endHold) / total),
            1,
        ]
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        titleLayer.add(animation, forKey: "marquee")
    }
}
