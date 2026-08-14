import SwiftUI

/// Combined magnitude response of the current EQ, drawn from the same RBJ
/// coefficient math the DSP uses. Band handles are draggable: horizontal
/// moves frequency (log scale), vertical moves gain.
struct ResponseCurveView: View {
    @Binding var bands: [EQBand]
    let preGainDB: Double
    let sampleRate: Double

    @State private var draggingIndex: Int?

    private static let minFrequency = 20.0
    private static let maxFrequency = 20_000.0
    private static let rangeDB = 27.0
    private static let maxGainDB = 24.0
    private static let sampleCount = 120
    private static let handleRadius: CGFloat = 5
    private static let grabRadius: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, size in
                drawGrid(context: context, size: size)
                drawCurve(context: context, size: size)
                drawHandles(context: context, size: size)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if draggingIndex == nil {
                            draggingIndex = nearestBandIndex(to: value.startLocation, size: size)
                        }
                        guard let index = draggingIndex, bands.indices.contains(index) else { return }
                        // Plain drag adjusts gain only; hold ⌥ to also move
                        // the band's frequency (prevents accidental drift).
                        if NSEvent.modifierFlags.contains(.option) {
                            let frequency = frequency(atX: value.location.x, width: size.width)
                            bands[index].frequency = min(max(frequency, Self.minFrequency), Self.maxFrequency)
                        }
                        let gain = gainDB(atY: value.location.y, height: size.height)
                        bands[index].gainDB = min(max(gain, -Self.maxGainDB), Self.maxGainDB)
                    }
                    .onEnded { _ in draggingIndex = nil }
            )
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Coordinate transforms

    private func xPosition(frequency: Double, width: CGFloat) -> CGFloat {
        let fraction = log(frequency / Self.minFrequency) / log(Self.maxFrequency / Self.minFrequency)
        return fraction * width
    }

    private func frequency(atX x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max(x / max(width, 1), 0), 1)
        return Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, fraction)
    }

    private func yPosition(gainDB: Double, height: CGFloat) -> CGFloat {
        height / 2 - (gainDB / Self.rangeDB) * (height / 2 - 4)
    }

    private func gainDB(atY y: CGFloat, height: CGFloat) -> Double {
        Double((height / 2 - y) / max(height / 2 - 4, 1)) * Self.rangeDB
    }

    private func nearestBandIndex(to point: CGPoint, size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, band) in bands.enumerated() where band.isEnabled {
            let handle = CGPoint(x: xPosition(frequency: band.frequency, width: size.width),
                                 y: yPosition(gainDB: band.gainDB, height: size.height))
            let distance = hypot(handle.x - point.x, handle.y - point.y)
            if distance <= Self.grabRadius, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    // MARK: - Drawing

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var gridLines = Path()
        for decade in [100.0, 1000, 10_000] {
            let x = xPosition(frequency: decade, width: size.width)
            gridLines.move(to: CGPoint(x: x, y: 0))
            gridLines.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(gridLines, with: .color(.secondary.opacity(0.15)), lineWidth: 1)

        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: size.height / 2))
        zeroLine.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(zeroLine, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        let coefficients = bands
            .filter { $0.isEnabled && $0.gainDB != 0 }
            .map { BiquadCoefficients.make(type: $0.type, frequency: $0.frequency,
                                           gainDB: $0.gainDB, q: $0.q, sampleRate: sampleRate) }
        var curve = Path()
        for step in 0..<Self.sampleCount {
            let fraction = Double(step) / Double(Self.sampleCount - 1)
            let frequency = Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, fraction)
            // Pre-gain is headroom management, not tonal shape — drawing it
            // would shift the whole curve away from the band handles.
            var magnitudeDB = 0.0
            for c in coefficients {
                magnitudeDB += 20 * log10(max(c.magnitude(at: frequency, sampleRate: sampleRate), 1e-9))
            }
            let clamped = min(max(magnitudeDB, -Self.rangeDB), Self.rangeDB)
            let point = CGPoint(x: fraction * size.width, y: yPosition(gainDB: clamped, height: size.height))
            step == 0 ? curve.move(to: point) : curve.addLine(to: point)
        }
        context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
    }

    private func drawHandles(context: GraphicsContext, size: CGSize) {
        for (index, band) in bands.enumerated() where band.isEnabled {
            let center = CGPoint(x: xPosition(frequency: band.frequency, width: size.width),
                                 y: yPosition(gainDB: band.gainDB, height: size.height))
            let rect = CGRect(x: center.x - Self.handleRadius, y: center.y - Self.handleRadius,
                              width: Self.handleRadius * 2, height: Self.handleRadius * 2)
            let isDragging = index == draggingIndex
            context.fill(Path(ellipseIn: rect),
                         with: .color(isDragging ? .accentColor : .accentColor.opacity(0.55)))
            context.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(0.4)), lineWidth: 1)
        }
    }
}
