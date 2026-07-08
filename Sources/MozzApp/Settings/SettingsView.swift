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
    /// Live enrichment coverage for the status line; polled while Settings is open
    /// (the task is hosted on the always-present Form — see `.task` below — because
    /// a `.task` on a view whose only content is conditional never fires until the
    /// content exists, a chicken-and-egg that leaves it permanently hidden).
    @State private var recCoverage: (total: Int, matched: Int, genreTagged: Int)?

    var body: some View {
        NavigationStack {
            Form {
                if let active = env.active {
                    Section("Library") {
                        Button {
                            env.startSync()
                        } label: {
                            HStack {
                                Label(env.isSyncing ? "Syncing…" : "Sync Now", mozz: "arrow.triangle.2.circlepath")
                                Spacer()
                                if env.isSyncing { ProgressView() }
                            }
                        }
                        .disabled(env.isSyncing)
                        if active.connection.kind == .plex {
                            NavigationLink {
                                PlexLibraryPickerView()
                            } label: {
                                Label("Server & Libraries", mozz: "square.stack.3d.up")
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
                            Label("Volume Normalization", mozz: "waveform")
                        }
                        Text("Plays tracks at a consistent loudness using each track's normalization gain, when available.")
                            .font(.caption).foregroundStyle(.secondary)
                        NavigationLink {
                            EqualizerSettingsView()
                        } label: {
                            Label("Equalizer", mozz: "waveform")
                        }
                    }

                    Section {
                        Toggle(isOn: $enrichmentEnabled) {
                            Label("Improve Recommendations", mozz: "sparkles")
                        }
                        .onChange(of: enrichmentEnabled) { _, enabled in
                            // Resume the crawl on ON; on OFF, promptly stop any
                            // in-flight enrichment/seed-prep so no further request
                            // goes out (the "fully offline" promise).
                            env.setEnrichmentEnabled(enabled)
                        }
                        Text("Looks up open music data from MusicBrainz to make radio and mixes more accurate. Only song and artist names are sent, no account or personal data. Turn this off to keep the app fully offline.")
                            .font(.caption).foregroundStyle(.secondary)
                        if enrichmentEnabled, let c = recCoverage, c.total > 0 {
                            EnrichmentCoverageRow(coverage: c)
                        }
                    } header: {
                        Text("Recommendations")
                    }

                    Section {
                        NavigationLink {
                            AppearanceSettingsView()
                        } label: {
                            Label("Appearance", mozz: "paintpalette")
                        }
                    }

                    Section {
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            Label("Diagnostics", mozz: "stethoscope")
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
                        Label("Source on GitHub", mozz: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityHint("Opens in Safari")
                    Link(destination: Self.sponsorURL) {
                        Label("Support Development", mozz: "heart")
                    }
                    .accessibilityHint("Opens in Safari")
                    if let reviewURL = Self.appStoreReviewURL {
                        Link(destination: reviewURL) {
                            Label("Rate on the App Store", mozz: "star")
                        }
                        .accessibilityHint("Opens the App Store")
                    }
                    LabeledContent {
                        Text(Self.appVersion)
                    } label: {
                        Label("Version", mozz: "info.circle")
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
            .task {
                // Poll the cheap coverage count while Settings is open so the status
                // line ticks up live as the rate-limited background pass runs.
                // Hosted here on the always-present Form (not inside the conditional
                // row) so it reliably fires. Cancelled automatically on dismiss.
                while !Task.isCancelled {
                    recCoverage = await env.enrichmentCoverage()
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
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
/// using the improved engine yet?". Pure presentational: `SettingsView` owns the
/// polling `.task` (hosted on the always-present Form) and only renders this row
/// once there's coverage to show, so the count ticks up live as the rate-limited
/// background pass runs.
private struct EnrichmentCoverageRow: View {
    let coverage: (total: Int, matched: Int, genreTagged: Int)

    var body: some View {
        let c = coverage
        let done = c.matched >= c.total
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(mozz: done ? "checkmark.seal.fill" : "sparkles")
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
