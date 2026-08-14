import SwiftUI

/// Combined magnitude response of the current EQ, drawn from the same RBJ
/// coefficient math the DSP uses.
struct ResponseCurveView: View {
    let bands: [EQBand]
    let preGainDB: Double
    let sampleRate: Double

    private static let minFrequency = 20.0
    private static let maxFrequency = 20_000.0
    private static let rangeDB = 27.0
    private static let sampleCount = 120

    var body: some View {
        Canvas { context, size in
            drawGrid(context: context, size: size)
            drawCurve(context: context, size: size)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

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
            var magnitudeDB = preGainDB
            for c in coefficients {
                magnitudeDB += 20 * log10(max(c.magnitude(at: frequency, sampleRate: sampleRate), 1e-9))
            }
            let clamped = min(max(magnitudeDB, -Self.rangeDB), Self.rangeDB)
            let point = CGPoint(x: fraction * size.width,
                                y: size.height / 2 - (clamped / Self.rangeDB) * (size.height / 2 - 4))
            step == 0 ? curve.move(to: point) : curve.addLine(to: point)
        }
        context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
    }

    private func xPosition(frequency: Double, width: CGFloat) -> CGFloat {
        let fraction = log(frequency / Self.minFrequency) / log(Self.maxFrequency / Self.minFrequency)
        return fraction * width
    }
}
