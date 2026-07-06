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
                            DiagnosticsView()
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                    }

                    Section {
                        Button(role: .destructive) { env.signOut() } label: {
                            Text("Sign Out")
                                .frame(maxWidth: .infinity)
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
                    if let reviewURL = Self.appStoreReviewURL {
                        Link(destination: reviewURL) {
                            Label("Rate on the App Store", systemImage: "star")
                        }
                        .accessibilityHint("Opens the App Store")
                    }
                    LabeledContent {
                        Text(Self.appVersion)
                    } label: {
                        Label("Version", systemImage: "info.circle")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("A free, open-source app under GPL-3.0. If you enjoy Mozz, a GitHub star, a review, or a small tip means a lot — thank you!")
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

    private static let repoURL = URL(string: "https://github.com/thatcube/mozz")!
    private static let sponsorURL = URL(string: "https://github.com/sponsors/thatcube")!

    /// App Store numeric ID, assigned once Mozz is published (e.g. "1234567890").
    /// While empty, the "Rate on the App Store" row stays hidden so it never
    /// points at a broken link.
    private static let appStoreID = ""

    /// Deep link straight to the App Store review composer, or `nil` until the
    /// app has an App Store ID.
    private static var appStoreReviewURL: URL? {
        guard !appStoreID.isEmpty else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }

    /// Marketing version + build from the bundle, e.g. "0.1.0 (1)".
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
