import SwiftUI

struct OutputDevicePicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Picker(selection: $appState.settings.outputDeviceUID) {
            Text("System Default").tag(String?.none)
            ForEach(appState.deviceMonitor.devices) { device in
                Text(device.name).tag(String?.some(device.uid))
            }
        } label: {
            Text("Output").font(.caption)
        }
        .pickerStyle(.menu)
    }
}
