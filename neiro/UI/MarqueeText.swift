import AppKit
import SwiftUI

/// Pixel-smooth marquee for the menu bar label. Holds at the start, scrolls
/// left at constant speed, holds at the end, snaps back — timing derived
/// from `anchor` so every view of the same title stays in phase.
struct MarqueeText: View {
    let text: String
    let anchor: Date

    private static let maxWidth: CGFloat = 110
    private static let speed: CGFloat = 30          // points per second
    private static let startHold: TimeInterval = 2
    private static let endHold: TimeInterval = 1

    private var textWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + 2
    }

    var body: some View {
        let width = textWidth
        if width <= Self.maxWidth {
            Text(text)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Text(text)
                    .fixedSize()
                    .offset(x: -offset(at: timeline.date, distance: width - Self.maxWidth))
                    .frame(width: Self.maxWidth, alignment: .leading)
                    .clipped()
            }
        }
    }

    private func offset(at date: Date, distance: CGFloat) -> CGFloat {
        let scrollDuration = TimeInterval(distance / Self.speed)
        let cycle = Self.startHold + scrollDuration + Self.endHold
        let elapsed = date.timeIntervalSince(anchor)
        guard elapsed > 0 else { return 0 }
        let t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < Self.startHold { return 0 }
        let scrollTime = t - Self.startHold
        guard scrollTime < scrollDuration else { return distance }
        return CGFloat(scrollTime) * Self.speed
    }
}
