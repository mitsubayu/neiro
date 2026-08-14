import SwiftUI

struct MenuBarRootView: View {
    @Environment(AppState.self) private var appState
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var bandsExpanded = false

    private static let contentWidth: CGFloat = 352

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: $appState.settings.isEnabled) {
                    Text("neiro").font(.headline)
                }
                .toggleStyle(.switch)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            if let title = appState.nowPlayingTitle {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let artwork = appState.nowPlayingArtwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.quaternary.opacity(0.5))
                        }
                    }
                    .frame(width: Self.contentWidth, height: Self.contentWidth)
                    .clipped()

                    LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                   startPoint: .center, endPoint: .bottom)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(2)
                        if let artist = appState.nowPlayingArtist, !artist.isEmpty {
                            Text(artist)
                                .font(.caption)
                                .opacity(0.85)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
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

            HStack {
                Menu {
                    Section("Built-in") {
                        ForEach(BuiltInPresets.all) { preset in
                            Button(preset.name) { appState.applyPreset(preset) }
                        }
                    }
                    if !appState.userPresets.isEmpty {
                        Section("My Presets") {
                            ForEach(appState.userPresets) { preset in
                                Menu(preset.name) {
                                    Button("Apply") { appState.applyPreset(preset) }
                                    Button("Update with Current EQ") { appState.updatePreset(preset) }
                                    Button("Delete", role: .destructive) { appState.deletePreset(preset) }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Save Current as Preset…") {
                        presetName = ""
                        isNamingPreset = true
                    }
                } label: {
                    Label(appState.activePresetName ?? "Presets", systemImage: "square.stack.3d.up")
                        .font(appState.activePresetName == nil ? .caption : .caption.bold())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .alert("Save Preset", isPresented: $isNamingPreset) {
                TextField("Preset name", text: $presetName)
                Button("Save") { appState.saveCurrentAsPreset(named: presetName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves the current bands and pre-gain.")
            }

            ResponseCurveView(bands: $appState.settings.bands,
                              preGainDB: appState.settings.preGainDB,
                              sampleRate: appState.engineSampleRate)
                .frame(height: 150)

            HStack {
                Text("Pre-gain").font(.caption)
                Slider(value: $appState.settings.preGainDB, in: -24...6)
                Text(appState.settings.preGainDB, format: .number.precision(.fractionLength(1)))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                Text("dB").font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            DisclosureGroup(isExpanded: $bandsExpanded) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($appState.settings.bands) { $band in
                            EQBandRow(band: $band)
                        }
                    }
                }
                .frame(maxHeight: 200)
            } label: {
                Text("Bands (freq / gain / Q)")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { bandsExpanded.toggle() }
                    }
            }

            Divider()

            HStack {
                Button("Reset EQ") {
                    for index in appState.settings.bands.indices {
                        appState.settings.bands[index].gainDB = 0
                    }
                    appState.settings.preGainDB = 0
                }
                Spacer()
                Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit neiro") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 380)
    }

    private var statusText: String {
        if case .running = appState.status {
            let codec = appState.trackCodec.map { "\($0) " } ?? ""
            return "Running · \(codec)\(appState.formatLabel)"
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
