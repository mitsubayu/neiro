import AppKit
import SwiftUI

/// SwiftUI wrapper hosting StatusMarqueeView inside the MenuBarExtra label.
/// The view is static as far as SwiftUI is concerned; the scrolling happens
/// in a repeating Core Animation keyframe animation on the render server.
struct MarqueeLabel: NSViewRepresentable {
    let title: String
    let suffix: String

    func makeNSView(context: Context) -> StatusMarqueeView {
        let view = StatusMarqueeView()
        view.update(title: title, suffix: decoratedSuffix)
        return view
    }

    func updateNSView(_ nsView: StatusMarqueeView, context: Context) {
        nsView.update(title: title, suffix: decoratedSuffix)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StatusMarqueeView, context: Context) -> CGSize? {
        CGSize(width: nsView.desiredWidth, height: 22)
    }

    private var decoratedSuffix: String {
        if !title.isEmpty, !suffix.isEmpty { return "· " + suffix }
        return suffix
    }
}

/// Icon + scrolling title + static suffix.
final class StatusMarqueeView: NSView {
    private let iconView = NSImageView()
    private let titleClipView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let suffixLabel = NSTextField(labelWithString: "")
    private var titleWidth: CGFloat = 0
    private var loopWidth: CGFloat = 0
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
        titleClipView.wantsLayer = true
        titleClipView.layer?.masksToBounds = true
        titleLabel.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byClipping
        suffixLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(iconView)
        titleClipView.addSubview(titleLabel)
        addSubview(titleClipView)
        addSubview(suffixLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var desiredWidth: CGFloat {
        var width = Self.iconWidth
        if !currentTitle.isEmpty {
            width += Self.gap + min(titleWidth, Self.titleMaxWidth)
        }
        if !currentSuffix.isEmpty {
            width += Self.gap + ceil(suffixLabel.frame.width)
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
            let labelSize = titleLabel.frame.size
            titleClipView.frame = NSRect(x: x, y: (height - labelSize.height) / 2,
                                         width: clipWidth, height: labelSize.height)
            titleLabel.frame = NSRect(origin: .zero, size: labelSize)
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
