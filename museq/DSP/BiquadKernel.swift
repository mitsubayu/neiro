import Foundation

/// Normalized biquad coefficients (a0 divided out).
struct BiquadCoefficients {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0

    static let identity = BiquadCoefficients()

    /// RBJ Audio EQ Cookbook formulas.
    static func make(type: BandType, frequency: Double, gainDB: Double, q: Double,
                     sampleRate: Double) -> BiquadCoefficients {
        // Clamp so bands parked above Nyquist (e.g. 16 kHz shelf at fs=32k)
        // stay stable instead of folding over.
        let f0 = min(max(frequency, 10), sampleRate * 0.45)
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2 * max(q, 0.05))

        var b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
        switch type {
        case .peak:
            b0 = 1 + alpha * A
            b1 = -2 * cosw0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosw0
            a2 = 1 - alpha / A
        case .lowShelf:
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosw0 + twoSqrtAAlpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosw0)
            b2 = A * ((A + 1) - (A - 1) * cosw0 - twoSqrtAAlpha)
            a0 = (A + 1) + (A - 1) * cosw0 + twoSqrtAAlpha
            a1 = -2 * ((A - 1) + (A + 1) * cosw0)
            a2 = (A + 1) + (A - 1) * cosw0 - twoSqrtAAlpha
        case .highShelf:
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosw0 + twoSqrtAAlpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosw0)
            b2 = A * ((A + 1) + (A - 1) * cosw0 - twoSqrtAAlpha)
            a0 = (A + 1) - (A - 1) * cosw0 + twoSqrtAAlpha
            a1 = 2 * ((A - 1) - (A + 1) * cosw0)
            a2 = (A + 1) - (A - 1) * cosw0 - twoSqrtAAlpha
        }
        return BiquadCoefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                                  a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// Magnitude response at `frequency` — used by the UI curve and tests.
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numReal = Double(b0) + Double(b1) * cos1 + Double(b2) * cos2
        let numImag = -(Double(b1) * sin1 + Double(b2) * sin2)
        let denReal = 1 + Double(a1) * cos1 + Double(a2) * cos2
        let denImag = -(Double(a1) * sin1 + Double(a2) * sin2)
        let num = numReal * numReal + numImag * numImag
        let den = denReal * denReal + denImag * denImag
        return sqrt(num / max(den, .leastNormalMagnitude))
    }
}

/// Per-channel state for one biquad section (transposed direct form II).
struct BiquadState {
    var z1: Float = 0
    var z2: Float = 0

    mutating func process(_ x: Float, _ c: BiquadCoefficients) -> Float {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}
