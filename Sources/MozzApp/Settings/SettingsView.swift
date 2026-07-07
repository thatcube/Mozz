import SwiftUI
import MozzCore
import MozzSync

/// Server info, capability report, sync control, benchmarks entry, and sign-out.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    /// Persisted across launches; mirrors `PlaybackEngine.normalizationEnabled`.
    @AppStorage("mozz.normalizationEnabled") private var normalizationEnabled = true
    /// Open metadata enrichment on/off (default on). Read live by
    /// `AppEnvironment.enrichment`, so no wiring is needed beyond this store.
    @AppStorage("mozz.enrichmentEnabled") private var enrichmentEnabled = true

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
                        Toggle(isOn: $enrichmentEnabled) {
                            Label("Improve Recommendations", systemImage: "sparkles")
                        }
                        Text("Looks up open music data from MusicBrainz to make radio and mixes more accurate. Only song and artist names are sent, no account or personal data. Turn this off to keep the app fully offline.")
                            .font(.caption).foregroundStyle(.secondary)
                        if enrichmentEnabled {
                            EnrichmentCoverageView()
                        }
                    } header: {
                        Text("Recommendations")
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

/// A live, non-intrusive readout of how much of the library has been enhanced
/// with open MusicBrainz data — the signal that answers "are my radio/mixes
/// using the improved engine yet?". Coverage grows in the background (rate-
/// limited) after each sync, so this polls the cheap count while Settings is
/// open and the number ticks up on its own.
private struct EnrichmentCoverageView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var coverage: (total: Int, matched: Int, genreTagged: Int)?

    var body: some View {
        Group {
            if let c = coverage, c.total > 0 {
                content(c)
            }
            // Before the first count loads (or nothing synced yet), show nothing —
            // the toggle's own description already explains the feature.
        }
        .task(id: env.isSyncing) {
            // Reload on appear and whenever a sync starts/finishes, then poll so
            // the count climbs live while the background pass runs. Cancels when
            // the view goes away or a sync toggles this task's id.
            while !Task.isCancelled {
                coverage = await env.enrichmentCoverage()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func content(_ c: (total: Int, matched: Int, genreTagged: Int)) -> some View {
        let done = c.matched >= c.total
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.seal.fill" : "sparkles")
                    .font(.footnote)
                    .foregroundStyle(done ? Color.green : Color.accentColor)
                Text(headline(c, done: done))
                    .font(.footnote.weight(.medium))
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                Text("\(percent(c))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            ProgressView(value: Double(c.matched), total: Double(max(c.total, 1)))
                .progressViewStyle(.linear)
                .tint(done ? .green : .accentColor)
            Text(caption(c, done: done))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .animation(.default, value: c.matched)
    }

    private func headline(_ c: (total: Int, matched: Int, genreTagged: Int), done: Bool) -> String {
        if done { return "Library enhanced" }
        if c.matched == 0 { return "Enhancing your library…" }
        return "Enhancing your library"
    }

    private func caption(_ c: (total: Int, matched: Int, genreTagged: Int), done: Bool) -> String {
        let matched = "\(fmt(c.matched)) of \(fmt(c.total)) songs matched to MusicBrainz"
        if done {
            return "All songs matched. Radio and mixes use the improved engine."
        }
        return matched + ". This keeps improving in the background as you listen."
    }

    private func percent(_ c: (total: Int, matched: Int, genreTagged: Int)) -> Int {
        guard c.total > 0 else { return 0 }
        return Int((Double(c.matched) / Double(c.total) * 100).rounded())
    }

    private func fmt(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}
