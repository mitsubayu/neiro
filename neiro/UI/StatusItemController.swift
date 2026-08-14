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

    private let appState: AppState
    private let statusItem: NSStatusItem
    private let marqueeView = StatusMarqueeView()
    private var marqueeWidthConstraint: NSLayoutConstraint?
    private var outsideClickMonitor: Any?

    // NSPopover.show silently no-ops in this configuration (macOS 26,
    // LSUIElement, SwiftUI lifecycle), so the panel is hand-rolled: a
    // borderless key-capable panel positioned under the status item.
    private lazy var panel: NSPanel = {
        let host = NSHostingController(
            rootView: MenuBarRootView()
                .environment(appState)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12)))
        let panel = KeyablePanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.appearance = nil  // inherit the system light/dark appearance
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

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        panel.layoutIfNeeded()
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = buttonRect.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: buttonRect.minY - size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        // Transient behavior by hand: any click outside our app closes it.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePanel() }
        }
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
    }
}

/// Borderless windows refuse key status by default; the EQ panel needs it
/// for the preset-name text field.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Icon + scrolling title + static suffix.
final class StatusMarqueeView: NSView {
    private let iconView = NSImageView()
    private let titleClipView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let suffixLabel = NSTextField(labelWithString: "")
    private var titleWidth: CGFloat = 0
    private var loopWidth: CGFloat = 0
    private var labelFullSize: NSSize = .zero
    private var currentTitle = ""
    private var currentSuffix = ""

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
        titleLabel.textColor = .labelColor
        suffixLabel.textColor = .labelColor
        titleClipView.wantsLayer = true
        titleClipView.layer?.masksToBounds = true
        titleLabel.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byClipping
        suffixLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Frames are managed manually in layout(); autoresizing would drag
        // the label's width along with the clip view, truncating the doubled
        // marquee string to the window width.
        titleClipView.autoresizingMask = []
        titleLabel.autoresizingMask = []
        suffixLabel.autoresizingMask = []
        addSubview(iconView)
        titleClipView.addSubview(titleLabel)
        addSubview(titleClipView)
        addSubview(suffixLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Real mouse clicks must fall through to the status bar button
    // underneath (accessibility AXPress bypasses hit-testing, which is why
    // synthetic click tests passed while physical clicks did nothing).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var desiredWidth: CGFloat {
        Self.measureWidth(title: currentTitle, suffix: currentSuffix)
    }

    /// Pure width computation so SwiftUI can size the label without asking
    /// the view instance.
    static func measureWidth(title: String, suffix: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func textWidth(_ text: String) -> CGFloat {
            ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
        }
        var width = iconWidth
        if !title.isEmpty {
            width += gap + min(textWidth(title), titleMaxWidth)
        }
        if !suffix.isEmpty {
            width += gap + textWidth(suffix)
        }
        return width
    }

    func update(title: String, suffix: String) {
        guard title != currentTitle || suffix != currentSuffix else { return }
        currentTitle = title
        currentSuffix = suffix

        titleLabel.stringValue = title
        titleLabel.sizeToFit()
        titleWidth = ceil(titleLabel.frame.width)
        if titleWidth > Self.titleMaxWidth {
            // Two copies separated by a gap: when the animation wraps at
            // -loopWidth the second copy sits exactly where the first
            // started, so the loop continues forward instead of snapping.
            let head = title + Self.loopGap
            loopWidth = ceil(NSAttributedString(
                string: head,
                attributes: [.font: titleLabel.font ?? .systemFont(ofSize: NSFont.systemFontSize)]
            ).size().width)
            titleLabel.stringValue = head + title
            titleLabel.sizeToFit()
        } else {
            loopWidth = 0
        }
        labelFullSize = titleLabel.frame.size

        suffixLabel.stringValue = suffix
        suffixLabel.sizeToFit()
        titleClipView.isHidden = title.isEmpty
        suffixLabel.isHidden = suffix.isEmpty
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
            let clipWidth = min(titleWidth, Self.titleMaxWidth)
            titleClipView.frame = NSRect(x: x, y: (height - labelFullSize.height) / 2,
                                         width: clipWidth, height: labelFullSize.height)
            // Always the full measured size — never re-read the live frame,
            // which the clip view's resize may have squeezed.
            titleLabel.frame = NSRect(origin: .zero, size: labelFullSize)
            x += clipWidth
        }
        if !currentSuffix.isEmpty {
            x += Self.gap
            let labelSize = suffixLabel.frame.size
            suffixLabel.frame = NSRect(x: x, y: (height - labelSize.height) / 2,
                                       width: labelSize.width, height: labelSize.height)
        }
    }

    /// One cycle: hold at the title head → scroll until the tail is visible →
    /// hold a beat → keep scrolling forward through the gap until the next
    /// copy's head aligns → wrap on identical pixels → hold again. The title
    /// never scrolls backwards.
    private func restartAnimation() {
        titleLabel.layer?.removeAnimation(forKey: "marquee")
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
        titleLabel.layer?.add(animation, forKey: "marquee")
    }
}
