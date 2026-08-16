import SwiftUI

/// Wide three-column panel: artwork, controls, bands. Laying it out sideways
/// keeps the artwork large while halving the height, and it retires the
/// folding section whose expand/collapse used to resize the window.
struct MenuBarRootView: View {
    @Environment(AppState.self) private var appState
    @State private var isNamingPreset = false
    @State private var presetName = ""

    static let artworkSize: CGFloat = 350
    // The extra width goes to the curve, which is the thing you drag.
    static let controlsWidth: CGFloat = 400
    // Wide enough for three sliders each followed by its own readout.
    static let bandsWidth: CGFloat = 400
    static let panelHeight: CGFloat = artworkSize + 14 * 2

    static func panelWidth(bandsVisible: Bool) -> CGFloat {
        let columns = artworkSize + controlsWidth + (bandsVisible ? bandsWidth + 14 : 0)
        return columns + 14 * 3
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            NowPlayingArtwork()
                .frame(width: Self.artworkSize, height: Self.artworkSize)
            controls
                .frame(width: Self.controlsWidth)
            if appState.settings.bandsVisible {
                bands
                    .frame(width: Self.bandsWidth)
            }
        }
        .padding(14)
        .frame(width: Self.panelWidth(bandsVisible: appState.settings.bandsVisible),
               height: Self.panelHeight)
    }

    // MARK: - Middle column

    private var controls: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("neiro").font(.headline)
                Spacer()
                statusAccessory
                if !appState.settings.bandsVisible {
                    PinButton()
                }
            }

            HStack(spacing: 8) {
                Text("Output").font(.caption).foregroundStyle(.secondary)
                OutputDevicePicker()
                Toggle(isOn: $appState.settings.followTrackRate) {
                    Text("bit-perfect").font(.caption)
                }
                .toggleStyle(.button)
                .help("Follow the track's own sample rate")
            }

            HStack(spacing: 8) {
                Text("EQ").font(.caption.bold()).foregroundStyle(.secondary)
                presetMenu
                Toggle(isOn: $appState.settings.isBypassed) {
                    Text("Bypass").font(.caption)
                }
                .toggleStyle(.button)
                .help("Pass audio through untouched for an instant A/B")
                Button {
                    for index in appState.settings.bands.indices {
                        appState.settings.bands[index].gainDB = 0
                    }
                    appState.settings.preGainDB = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset the EQ to flat")
                Spacer()
                HistoryButtons()
                Toggle(isOn: $appState.settings.bandsVisible) {
                    Image(systemName: appState.settings.bandsVisible
                          ? "sidebar.trailing" : "sidebar.leading")
                }
                .toggleStyle(.button)
                .help(appState.settings.bandsVisible ? "Hide the band list" : "Show the band list")
            }

            ResponseCurveView(bands: $appState.settings.bands,
                              preGainDB: appState.settings.preGainDB,
                              sampleRate: appState.engineSampleRate,
                              spectrumTap: appState.spectrumTap)
                .frame(maxHeight: .infinity)
                .opacity(appState.settings.isBypassed ? 0.35 : 1)
                .overlay {
                    if appState.settings.isBypassed {
                        Text("BYPASSED").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                }

            HStack(spacing: 6) {
                Text("Pre-gain").font(.caption).foregroundStyle(.secondary)
                Slider(value: $appState.settings.preGainDB, in: -24...6)
                Text(appState.settings.preGainDB, format: .number.precision(.fractionLength(1)))
                    .font(.caption.monospacedDigit())
                    .frame(width: 32, alignment: .trailing)
                Text("dB").font(.caption2).foregroundStyle(.secondary)
            }

            if !appState.settings.bandsVisible {
                ChromeFooter()
            }
        }
    }

    /// The format now lives on the artwork, so this only speaks up when
    /// something needs attention.
    @ViewBuilder
    private var statusAccessory: some View {
        if let target = appState.switchTargetRate {
            Text("→ \(AppState.rateLabel(target))")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if case .error = appState.status {
            Button("Fix permission…") {
                let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                if let url = URL(string: url) { NSWorkspace.shared.open(url) }
            }
            .font(.caption)
        } else if appState.status != .running {
            Text(appState.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var presetMenu: some View {
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
            if let device = appState.currentOutputDeviceName {
                if appState.boundPresetNameForCurrentDevice != nil {
                    Button("Stop auto-applying on \(device)") {
                        appState.clearPresetBindingForCurrentDevice()
                    }
                }
                Button("Auto-apply this preset on \(device)") {
                    appState.bindActivePresetToCurrentDevice()
                }
                .disabled(appState.activePresetName == nil)
            }
            Button("Save Current as Preset…") {
                presetName = ""
                isNamingPreset = true
            }
        } label: {
            Text(appState.activePresetName ?? "Presets")
                .font(appState.activePresetName == nil ? .caption : .caption.bold())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") { appState.saveCurrentAsPreset(named: presetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current bands and pre-gain.")
        }
    }

    // MARK: - Right column

    private var bands: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bands").font(.caption.bold()).foregroundStyle(.secondary)
                Text("gain / Q / freq").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                PinButton()
            }

            ForEach($appState.settings.bands) { $band in
                Spacer(minLength: 0)
                EQBandRow(band: $band)
            }

            Spacer(minLength: 6)

            ChromeFooter()
        }
    }
}

/// Settings menu and Quit, right-aligned. Lives in whichever column is last.
private struct ChromeFooter: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 6) {
            Spacer()
            Menu {
                Toggle("Enable neiro", isOn: $appState.settings.isEnabled)
                Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
                Divider()
                HelpButton()
                AboutButton()
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.caption)
    }
}

/// Its own view so it can call AppState methods: inside `controls` the name
/// is shadowed by a @Bindable wrapper, which only vends bindings.
private struct HistoryButtons: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 4) {
            Button { appState.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!appState.canUndo)
            .help("Undo (⌘Z)")

            Button { appState.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!appState.canRedo)
            .help("Redo (⇧⌘Z)")
        }
    }
}

/// Shows the standard macOS About window. Our panel floats at pop-up-menu
/// level, so it steps aside first or it would cover the About window.
private struct AboutButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button("About neiro") {
            appState.closePanel()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(options: [.credits: AboutCredits.attributedString()])
        }
    }
}

private struct HelpButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button("Help neiro") { appState.showHelp() }
            .keyboardShortcut("?", modifiers: .command)
    }
}

private struct PinButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Button {
            appState.settings.panelPinned.toggle()
        } label: {
            Image(systemName: appState.settings.panelPinned ? "pin.fill" : "pin")
                .rotationEffect(.degrees(appState.settings.panelPinned ? 0 : 45))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(appState.settings.panelPinned ? Color.accentColor : .secondary)
        .help(appState.settings.panelPinned
              ? "Panel stays open until you close it"
              : "Keep the panel open when clicking elsewhere")
    }
}

/// Artwork with the track and its format overlaid, so "what is playing" and
/// "at what quality" read as one thing.
private struct NowPlayingArtwork: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let artwork = appState.nowPlayingArtwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Nothing playing: the app's own icon reads as "this is
                    // neiro, waiting" rather than as a track that failed to
                    // load its cover.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: MenuBarRootView.artworkSize * 0.42)
                        .opacity(0.9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.5))
                }
            }
            .frame(width: MenuBarRootView.artworkSize, height: MenuBarRootView.artworkSize)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.78)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                if let title = appState.nowPlayingTitle {
                    Text(title).font(.headline).lineLimit(2)
                }
                if let artist = appState.nowPlayingArtist, !artist.isEmpty {
                    Text(artist).font(.caption).opacity(0.85).lineLimit(1)
                }
                if appState.status == .running {
                    Text(appState.menuBarSuffix)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.18), in: Capsule())
                        .padding(.top, 2)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
