import SwiftUI
import MozzCore
import MozzSync

/// Server info, capability report, sync control, benchmarks entry, and sign-out.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    /// Persisted across launches; mirrors `PlaybackEngine.normalizationEnabled`.
    @AppStorage("mozz.normalizationEnabled") private var normalizationEnabled = true

    var body: some View {
        NavigationStack {
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
                    }

                    Section("Capabilities") {
                        capabilityRow("Offline download", "arrow.down.circle", active.capabilities.supportsOriginalFileDownload)
                        capabilityRow("Transcoding", "waveform.path", active.capabilities.supportsTranscoding)
                        capabilityRow("Favorites", "heart", active.capabilities.supportsFavorites)
                        capabilityRow("Lyrics", "quote.bubble", active.capabilities.supportsLyrics)
                        capabilityRow("Normalization gain", "waveform", active.capabilities.supportsNormalizationGain)
                        capabilityRow("Scrobble / progress", "dot.radiowaves.left.and.right", active.capabilities.supportsProgressReporting)
                        if let plexPass = active.capabilities.hasPlexPass {
                            capabilityRow("Plex Pass", "star", plexPass)
                        }
                    }

                    Section("Library") {
                        Button {
                            env.startSync()
                        } label: {
                            HStack {
                                Label(env.isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if env.isSyncing { ProgressView() }
                            }
                        }
                        .disabled(env.isSyncing)
                        if active.connection.kind == .plex {
                            NavigationLink {
                                PlexLibraryPickerView()
                            } label: {
                                Label("Server & Libraries", systemImage: "square.stack.3d.up")
                            }
                        }
                        if let text = env.syncStatusText {
                            Text(text).font(.caption).foregroundStyle(.secondary)
                        }
                        if let summary = env.lastSyncSummary {
                            Text("Last sync: \(summary)").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Section("Playback") {
                        Toggle(isOn: $normalizationEnabled) {
                            Label("Volume Normalization", systemImage: "waveform")
                        }
                        Text("Plays tracks at a consistent loudness using each track's normalization gain, when available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section {
                        NavigationLink {
                            BenchmarksView()
                        } label: {
                            Label("Performance Benchmarks", systemImage: "speedometer")
                        }
                    }

                    Section {
                        Button(role: .destructive) { env.signOut() } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }

                Section {
                    Link(destination: Self.repoURL) {
                        Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityHint("Opens in Safari")
                    Link(destination: Self.sponsorURL) {
                        Label("Support Development", systemImage: "heart")
                    }
                    .accessibilityHint("Opens in Safari")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mozz \(Self.appVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("GPL-3.0 · offline-first music for Plex & Jellyfin")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { env.playback.normalizationEnabled = normalizationEnabled }
            .onChange(of: normalizationEnabled) { _, enabled in
                env.playback.normalizationEnabled = enabled
            }
        }
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

    private static let repoURL = URL(string: "https://github.com/thatcube/mozz")!
    private static let sponsorURL = URL(string: "https://github.com/sponsors/thatcube")!

    /// Marketing version + build from the bundle, e.g. "0.1.0 (1)".
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
