import SwiftUI

struct MenuBarRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: $appState.settings.isEnabled) {
                    Text("museq").font(.headline)
                }
                .toggleStyle(.switch)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            if case .error = appState.status {
                Button("Open Privacy Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
                .font(.caption)
            }

            OutputDevicePicker()

            Toggle(isOn: $appState.settings.followTrackRate) {
                Text("Follow track sample rate (bit-perfect)")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            ResponseCurveView(bands: appState.settings.bands,
                              preGainDB: appState.settings.preGainDB,
                              sampleRate: appState.engineSampleRate)
                .frame(height: 90)

            HStack {
                Text("Pre-gain").font(.caption)
                Slider(value: $appState.settings.preGainDB, in: -24...6)
                Text(appState.settings.preGainDB, format: .number.precision(.fractionLength(1)))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                Text("dB").font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($appState.settings.bands) { $band in
                        EQBandRow(band: $band)
                    }
                }
            }
            .frame(maxHeight: 320)

            Divider()

            HStack {
                Button("Reset EQ") {
                    for index in appState.settings.bands.indices {
                        appState.settings.bands[index].gainDB = 0
                    }
                    appState.settings.preGainDB = 0
                }
                Spacer()
                Button("Quit museq") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 380)
    }

    private var statusText: String {
        if case .running = appState.status {
            return "Running · \(appState.formatLabel)"
        }
        return appState.status.label
    }

    private var statusColor: Color {
        switch appState.status {
        case .running: .green
        case .waitingForMusic: .orange
        case .error: .red
        case .disabled: .secondary
        }
    }
}
