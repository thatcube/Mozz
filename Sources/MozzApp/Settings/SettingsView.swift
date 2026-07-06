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
                        LabeledContent("Name", value: active.connection.name)
                        LabeledContent("Type", value: active.connection.kind.displayName)
                        LabeledContent("Address", value: active.connection.baseURL.absoluteString)
                    }

                    Section("Capabilities") {
                        capabilityRow("Offline download", active.capabilities.supportsOriginalFileDownload)
                        capabilityRow("Transcoding", active.capabilities.supportsTranscoding)
                        capabilityRow("Favorites", active.capabilities.supportsFavorites)
                        capabilityRow("Lyrics", active.capabilities.supportsLyrics)
                        capabilityRow("Normalization gain", active.capabilities.supportsNormalizationGain)
                        capabilityRow("Scrobble / progress", active.capabilities.supportsProgressReporting)
                        if let plexPass = active.capabilities.hasPlexPass {
                            capabilityRow("Plex Pass", plexPass)
                        }
                    }

                    Section("Library") {
                        Button {
                            env.startSync()
                        } label: {
                            HStack {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mozz \(Self.appVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("GPL-3.0 · offline-first music for Plex & Jellyfin")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
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

    private func capabilityRow(_ title: String, _ enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? .green : .secondary)
        }
    }

    /// Marketing version + build from the bundle, e.g. "0.1.0 (1)".
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
