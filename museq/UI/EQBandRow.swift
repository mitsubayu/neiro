import SwiftUI

struct EQBandRow: View {
    @Binding var band: EQBand

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(isOn: $band.isEnabled) {
                    Text(frequencyLabel)
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .leading)
                }
                .toggleStyle(.checkbox)
                Text(typeLabel).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(band.gainDB >= 0 ? "+" : "")\(band.gainDB, specifier: "%.1f") dB  Q \(band.q, specifier: "%.2f")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                LabeledSlider(label: "f", value: logBinding($band.frequency, range: 20...20_000), range: log10(20)...log10(20_000))
                LabeledSlider(label: "g", value: $band.gainDB, range: -24...24)
                LabeledSlider(label: "Q", value: logBinding($band.q, range: 0.1...10), range: log10(0.1)...log10(10))
            }
            .disabled(!band.isEnabled)
            .opacity(band.isEnabled ? 1 : 0.4)
        }
    }

    private var frequencyLabel: String {
        band.frequency >= 1000
            ? String(format: "%.1f kHz", band.frequency / 1000)
            : String(format: "%.0f Hz", band.frequency)
    }

    private var typeLabel: String {
        switch band.type {
        case .peak: "peak"
        case .lowShelf: "low shelf"
        case .highShelf: "high shelf"
        }
    }

    private func logBinding(_ source: Binding<Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { log10(source.wrappedValue) },
            set: { source.wrappedValue = min(max(pow(10, $0), range.lowerBound), range.upperBound) }
        )
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Slider(value: $value, in: range)
                .controlSize(.mini)
        }
    }
}
