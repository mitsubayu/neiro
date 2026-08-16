import SwiftUI

/// Short answers to "what does this control actually do", written for the
/// person using the app rather than the person who built it.
struct HelpView: View {
    private struct Topic: Identifiable {
        let id = UUID()
        let title: String
        let points: [String]
    }

    private let topics: [Topic] = [
        Topic(title: String(localized: "Playback"), points: [
            String(localized: "neiro captures Music.app and plays it back through the output device you pick. Music's own output stays muted meanwhile, so you hear one signal, not two."),
            String(localized: "bit-perfect follows each track's own sample rate. When a track needs a different rate there is a short silence, then the track plays from its beginning at the right rate."),
            String(localized: "Mid-track it never interrupts: a rate change for the next song waits for the track boundary."),
        ]),
        Topic(title: String(localized: "EQ"), points: [
            String(localized: "Drag a handle on the curve to change its gain. Hold ⌥ while dragging to move its frequency instead."),
            String(localized: "The band list edits gain, Q and frequency directly. The checkbox disables a band without losing its settings."),
            String(localized: "Pre-gain trims the level before the EQ — lower it if boosts start to distort."),
            String(localized: "Bypass passes audio through untouched for an instant A/B. Turning neiro off in ⚙ instead releases the capture entirely and hands playback back to Music."),
            String(localized: "⌘Z and ⇧⌘Z undo and redo EQ changes; a whole drag counts as one step."),
        ]),
        Topic(title: String(localized: "Presets"), points: [
            String(localized: "Save the current EQ under a name, update it later, or delete it."),
            String(localized: "A preset can be bound to an output device and is applied automatically whenever that device becomes the output — useful when headphones and speakers need different correction."),
        ]),
        Topic(title: String(localized: "Panel"), points: [
            String(localized: "The pin keeps the panel open when you click elsewhere; click the menu bar icon to close it."),
            String(localized: "The menu bar shows the track, its codec and the rate currently being played."),
        ]),
        Topic(title: String(localized: "If something goes wrong"), points: [
            String(localized: "No sound or an error: grant System Settings → Privacy & Security → Screen & System Audio Recording, and allow neiro to control Music when asked."),
            String(localized: "neiro needs Music.app running; otherwise it waits and picks up automatically once playback starts."),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(topics) { topic in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(topic.title)
                            .font(.headline)
                        ForEach(topic.points, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(point)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 560)
    }
}
