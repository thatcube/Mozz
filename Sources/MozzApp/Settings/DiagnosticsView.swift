import SwiftUI
import MozzCore

/// Development- and troubleshooting-oriented details for the active server:
/// connection info, probed capabilities, and performance benchmarks. Grouped
/// out of the main Settings page so day-to-day settings stay uncluttered while
/// self-hosters can still inspect what their server supports.
struct DiagnosticsView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Form {
            if let active = env.active {
                Section("Server") {
                    LabeledContent {
                        Text(active.connection.name)
                    } label: {
                        Label("Name", systemImage: "tag")
                    }
                    LabeledContent {
                        Text(active.connection.kind.displayName)
                    } label: {
                        Label("Type", systemImage: "server.rack")
                    }
                    LabeledContent {
                        Text(active.connection.baseURL.absoluteString)
                    } label: {
                        Label("Address", systemImage: "network")
                    }
                    if let version = active.capabilities.serverVersion, !version.isEmpty {
                        LabeledContent {
                            Text(version)
                        } label: {
                            Label("Version", systemImage: "number")
                        }
                    }
                }

                Section {
                    capabilityRow("Offline download", "arrow.down.circle", active.capabilities.supportsOriginalFileDownload)
                    capabilityRow("Transcoding", "waveform.path", active.capabilities.supportsTranscoding)
                    capabilityRow("Favorites", "heart", active.capabilities.supportsFavorites)
                    capabilityRow("Ratings", "star", active.capabilities.supportsRatings)
                    capabilityRow("Lyrics", "quote.bubble", active.capabilities.supportsLyrics)
                    capabilityRow("Synced lyrics", "text.badge.checkmark", active.capabilities.supportsSyncedLyrics)
                    capabilityRow("Normalization gain", "waveform", active.capabilities.supportsNormalizationGain)
                    capabilityRow("Scrobble / progress", "dot.radiowaves.left.and.right", active.capabilities.supportsProgressReporting)
                    if let plexPass = active.capabilities.hasPlexPass {
                        capabilityRow("Plex Pass", "star.circle", plexPass)
                    }
                } header: {
                    Text("Capabilities")
                } footer: {
                    Text("Probed from your server on \(active.capabilities.detectedAt.formatted(date: .abbreviated, time: .shortened)). These control which features appear in the app.")
                }
            } else {
                ContentUnavailableView("No active server", systemImage: "server.rack")
            }

            Section {
                NavigationLink {
                    BenchmarksView()
                } label: {
                    Label("Performance Benchmarks", systemImage: "speedometer")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .inlineNavigationTitle()
    }

    /// A capability row that scales with Dynamic Type (LabeledContent reflows the
    /// value beneath the label at large text sizes) and announces its state to
    /// VoiceOver as a value rather than relying on icon color alone.
    private func capabilityRow(_ title: String, _ systemImage: String, _ enabled: Bool) -> some View {
        LabeledContent {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(enabled ? "Supported" : "Not supported")
    }
}
