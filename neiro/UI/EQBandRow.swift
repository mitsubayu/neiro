import SwiftUI

/// One line per band with every parameter inline, each slider followed by its
/// own readout so the numbers are visible while dragging.
struct EQBandRow: View {
    @Binding var band: EQBand

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $band.isEnabled) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(typeLabel)

            Group {
                // Gain first: with ten bands parked on fixed frequencies this
                // reads like a graphic EQ, and gain is what actually gets
                // dragged. Frequency is rarely touched (and can be moved on
                // the curve with ⌥), so it sits last.
                parameter("g", value: $band.gainDB, range: -24...24,
                          readout: gainLabel, readoutWidth: 34)
                parameter("Q", value: logBinding($band.q, range: 0.1...10),
                          range: log10(0.1)...log10(10),
                          readout: String(format: "%.2f", band.q), readoutWidth: 30)
                parameter("f", value: logBinding($band.frequency, range: 20...20_000),
                          range: log10(20)...log10(20_000),
                          readout: frequencyLabel, readoutWidth: 44)
            }
            .disabled(!band.isEnabled)
            .opacity(band.isEnabled ? 1 : 0.35)
        }
    }

    private func parameter(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           readout: String, readoutWidth: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Slider(value: value, in: range).controlSize(.mini)
            Text(readout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: readoutWidth, alignment: .trailing)
        }
    }

    private var frequencyLabel: String {
        band.frequency >= 1000
            ? String(format: "%.1fk", band.frequency / 1000)
            : String(format: "%.0f", band.frequency)
    }

    private var gainLabel: String {
        String(format: "%@%.1f", band.gainDB >= 0 ? "+" : "", band.gainDB)
    }

    private var typeLabel: String {
        switch band.type {
        case .peak: "peak"
        case .lowShelf: "low shelf"
        case .highShelf: "high shelf"
        }
    }

    /// Frequency and Q feel linear to the ear on a log scale, so the sliders
    /// move in log space and convert back.
    private func logBinding(_ source: Binding<Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { log10(source.wrappedValue) },
            set: { source.wrappedValue = min(max(pow(10, $0), range.lowerBound), range.upperBound) }
        )
    }
}
