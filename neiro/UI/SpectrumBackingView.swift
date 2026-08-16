import AppKit
import SwiftUI

/// The spectrum redraws 30 times a second forever, so it must not go through
/// SwiftUI: publishing the levels as observable state re-evaluated the panel's
/// hierarchy on every frame (~33% CPU, and ~12% even after isolating the
/// curve). This view owns its refresh loop, pulls straight from the audio tap
/// and draws itself — SwiftUI creates it once and never hears from it again.
final class SpectrumBackingView: NSView {
    private let tap: SpectrumTap
    /// Updated from SwiftUI only when the engine's rate actually changes.
    var sampleRate: Double
    private let analyzer = SpectrumAnalyzer()
    private let window_ = UnsafeMutablePointer<Float>.allocate(capacity: SpectrumTap.fftSize)
    private var timer: Timer?
    // Drawing the fill in draw(_:) every frame cost ~5% CPU. A gradient layer
    // masked by a shape layer means each tick only swaps a path and the render
    // server does the rest.
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()

    init(tap: SpectrumTap, sampleRate: Double) {
        self.tap = tap
        self.sampleRate = sampleRate
        super.init(frame: .zero)
        window_.initialize(repeating: 0, count: SpectrumTap.fftSize)
        wantsLayer = true
        layer = CALayer()
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.mask = maskLayer
        layer?.addSublayer(gradientLayer)
        applyAccentColor()
    }

    private func applyAccentColor() {
        var accent = NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor(cgColor: NSColor.controlAccentColor.cgColor) ?? accent
        }
        gradientLayer.colors = [accent.withAlphaComponent(0.40).cgColor,
                                accent.withAlphaComponent(0.05).cgColor]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccentColor()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        maskLayer.frame = bounds
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timer?.invalidate()
        window_.deallocate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Capture and animation are tied to being on screen: with the panel
    /// closed the IO thread doesn't even copy samples.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window != nil ? start() : stop()
    }

    private func start() {
        guard timer == nil else { return }
        tap.setActive(true)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the display keeps moving while menus track.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        tap.setActive(false)
    }

    private func tick() {
        if tap.latestWindow(into: window_) {
            analyzer.analyze(window: window_, sampleRate: sampleRate)
        } else {
            analyzer.decay()
        }
        updateShape()
    }

    private func updateShape() {
        let levels = analyzer.levels
        guard levels.count > 1, bounds.width > 0, bounds.height > 0 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        for (index, level) in levels.enumerated() {
            let x = CGFloat(index) / CGFloat(levels.count - 1) * bounds.width
            path.addLine(to: CGPoint(x: x, y: CGFloat(level) * bounds.height))
        }
        path.addLine(to: CGPoint(x: bounds.width, y: 0))
        path.closeSubpath()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path
        CATransaction.commit()
    }
}

/// Hosts the analyzer view inside the SwiftUI curve.
struct SpectrumBacking: NSViewRepresentable {
    let tap: SpectrumTap
    let sampleRate: Double

    func makeNSView(context: Context) -> SpectrumBackingView {
        SpectrumBackingView(tap: tap, sampleRate: sampleRate)
    }

    func updateNSView(_ nsView: SpectrumBackingView, context: Context) {
        nsView.sampleRate = sampleRate
    }
}
