import SwiftUI
import MozzCore
import MozzSync

/// Server info, capability report, sync control, benchmarks entry, and sign-out.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var isSyncing = false
    @State private var syncProgressText: String?

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
                            Task { await sync() }
                        } label: {
                            HStack {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if isSyncing { ProgressView() }
                            }
                        }
                        .disabled(isSyncing)
                        if let text = syncProgressText {
                            Text(text).font(.caption).foregroundStyle(.secondary)
                        }
                        if let summary = env.lastSyncSummary {
                            Text("Last sync: \(summary)").font(.caption).foregroundStyle(.secondary)
                        }
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
                    Text("Mozz · GPL-3.0 · offline-first music for Plex & Jellyfin")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Settings")
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

    private func sync() async {
        isSyncing = true
        syncProgressText = "Starting…"
        defer { isSyncing = false; syncProgressText = nil }
        do {
            _ = try await env.syncNow { progress in
                Task { @MainActor in
                    syncProgressText = "\(progress.phase.rawValue): \(progress.itemsSynced)"
                }
            }
        } catch {
            syncProgressText = "Sync failed: \(error.localizedDescription)"
        }
    }
}
