import SwiftUI
import MozzSync

/// A slim, non-blocking status card shown while a catalog sync is running.
///
/// It lives in the Home tab's scroll content — NOT in a top safe-area inset on
/// the tab shell, which is where it used to sit. As an inset it overlapped the
/// tight header on every tab, and that header carries the Settings avatar, so a
/// running sync sat on top of the profile navigation. In the scroll content it
/// can't cover anything, and it scrolls away like the rest of the page.
///
/// The caller decides when to show it (`if env.isSyncing`), so the insertion and
/// removal transition belongs to the caller's `if` rather than firing inside a
/// view that's already mounted.
struct SyncStatusBar: View {
    @EnvironmentObject private var env: AppEnvironment
    /// Status glyphs are sized in scaled points so they keep their proportion to
    /// the label beside them instead of shrivelling as the text grows.
    @ScaledMetric(relativeTo: .caption) private var glyph: CGFloat = 11

    /// Walks the counters up to each new page instead of letting them jump, so a
    /// slow sync still looks like it's moving. See `SyncProgressSmoother`.
    @StateObject private var smoother = SyncProgressSmoother()
    @State private var quipIndex = 0

    /// Rotates the status line. Slow enough to read, quick enough that a long
    /// sync never shows the same words for long.
    private let quipTimer = Timer.publish(every: 7, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let details = env.syncProgress?.details, !details.isEmpty {
                breakdown(details)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        // Matches the horizontal inset of Home's other sections so the card lines
        // up with the grid and shelves below it.
        .padding(.horizontal, 20)
        .transition(.opacity.combined(with: .move(edge: .top)))
        // `.contain`, not `.combine`: the phase rows carry their own spoken state
        // ("Albums, done"), and combining would flatten the whole checklist into
        // one summary — losing exactly the detail this card exists to give.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Library sync"))
        .accessibilityValue(Text(env.syncStatusText ?? "Syncing your library"))
        .onAppear { smoother.update(from: env.syncProgress) }
        .onChange(of: env.syncProgress) { _, progress in
            smoother.update(from: progress)
        }
        .onChange(of: env.isSyncing) { _, syncing in
            if !syncing { smoother.reset() }
        }
        .onReceive(quipTimer) { _ in
            // The line is decoration, not information — announcing every rotation
            // would interrupt VoiceOver mid-sentence for no gain.
            withAnimation(.easeInOut(duration: 0.35)) { quipIndex += 1 }
        }
    }

    // MARK: Header — title, %, progress bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title and total sit side by side when they fit and stack when they
            // don't, rather than the total squeezing the title into an ellipsis.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    titleLine
                    Spacer(minLength: 8)
                    totalLabel
                }
                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    totalLabel
                }
            }
            quipLine
            if let fraction = displayFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(height: 3)
                    .tint(.accentColor)
            } else {
                IndeterminateBar().frame(height: 3)
            }
        }
    }

    /// The rotating "we know it's slow" line.
    ///
    /// Wraps rather than truncates at large Dynamic Type sizes — it's a full
    /// sentence, so clipping it would leave a dangling half-thought. Hidden from
    /// VoiceOver: the card already exposes the real status as its
    /// `accessibilityValue`, and a line that changes every seven seconds would
    /// interrupt whatever was being read.
    private var quipLine: some View {
        Text(SyncQuips.line(index: quipIndex, fraction: displayFraction))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .id(quipIndex)
            .accessibilityHidden(true)
    }

    /// The eased fraction, falling back to the raw one before the smoother has
    /// anything (so the bar is never stuck at zero on first paint).
    private var displayFraction: Double? {
        guard let raw = env.syncFraction else { return nil }
        return smoother.fraction > 0 ? smoother.fraction : raw
    }

    private var titleLine: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Syncing your library")
                // A notch larger than the rows beneath it: this is the card's
                // headline and was reading as just another line of small text.
                .font(.subheadline.weight(.semibold))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var totalLabel: some View {
        Text(overallText)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
    }

    /// "42%" once a total is known, else a live item count so the number always
    /// means something.
    private var overallText: String {
        if let fraction = displayFraction {
            return "\(Int((fraction * 100).rounded()))%"
        }
        if let n = env.syncProgress?.itemsSynced, n > 0 {
            return "\(Self.compact(n)) items"
        }
        return ""
    }

    // MARK: Per-phase breakdown

    /// The phases as a vertical checklist, one per line.
    ///
    /// This used to be a single horizontal row. It fitted at the default text
    /// size and fell apart above it: four labels and their counts competing for
    /// one line meant everything truncated to "Albu… 1k/6…", which is worse than
    /// useless — and it was worst at exactly the sizes chosen by people who need
    /// the text bigger. Stacked, each phase gets a full line at any size, and the
    /// list doubles as a progress checklist: what's done, what's happening, and
    /// what's still to come.
    private func breakdown(_ details: [SyncProgress.PhaseDetail]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(details) { detail in
                phaseRow(detail)
            }
        }
    }

    private func phaseRow(_ detail: SyncProgress.PhaseDetail) -> some View {
        // Label and count share a line when they fit and stack when they don't.
        // This matters more now the active row shows exact digits — at the larger
        // accessibility text sizes "Songs" and "5,143/9,512" cannot share a line,
        // and stacking keeps both fully readable instead of truncating either.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                phaseGlyphAndLabel(detail)
                Spacer(minLength: 6)
                phaseCount(detail)
            }
            VStack(alignment: .leading, spacing: 2) {
                phaseGlyphAndLabel(detail)
                phaseCount(detail)
                    .padding(.leading, glyph + 7)
            }
        }
        .font(.caption)
        // Long labels wrap rather than truncate now that each has its own line.
        .fixedSize(horizontal: false, vertical: true)
        .opacity(opacity(for: detail.state))
        .animation(.easeInOut(duration: 0.25), value: detail.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(detail))
    }

    private func phaseGlyphAndLabel(_ detail: SyncProgress.PhaseDetail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            statusGlyph(detail.state)
                // Reserve one glyph's width for every row so the labels align in a
                // column regardless of which state each row is in.
                .frame(width: glyph, alignment: .center)
            Text(detail.phase.label)
                .foregroundStyle(detail.state == .pending ? .tertiary : .secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func phaseCount(_ detail: SyncProgress.PhaseDetail) -> some View {
        if detail.state != .pending {
            Text(count(detail))
                .foregroundStyle(detail.state == .done ? .secondary : .primary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private func statusGlyph(_ state: SyncProgress.PhaseDetail.State) -> some View {
        switch state {
        case .done:
            Image(mozz: "checkmark.circle.fill")
                .resizable().scaledToFit()
                .frame(width: glyph, height: glyph)
                .foregroundStyle(.green)
        case .syncing:
            Circle()
                .fill(.tint)
                .frame(width: glyph * 0.55, height: glyph * 0.55)
        case .pending:
            Image(mozz: "circle")
                .resizable().scaledToFit()
                .frame(width: glyph * 0.85, height: glyph * 0.85)
                .foregroundStyle(.tertiary)
        }
    }

    /// Spoken as a state rather than a bare number, so the checklist reads as one.
    private func accessibilityLabel(_ detail: SyncProgress.PhaseDetail) -> Text {
        switch detail.state {
        case .done: return Text("\(detail.phase.label), done")
        // The *real* count, not the eased one: the smoothing exists to make the
        // screen feel alive, and reading a deliberately-lagging number aloud
        // would just be inaccurate.
        case .syncing:
            let total = detail.total.map { " of \(Self.exact($0))" } ?? ""
            return Text("\(detail.phase.label), \(Self.exact(detail.synced))\(total)")
        case .pending: return Text("\(detail.phase.label), waiting")
        }
    }

    private func opacity(for state: SyncProgress.PhaseDetail.State) -> Double {
        switch state {
        case .done: return 0.6
        case .syncing: return 1
        case .pending: return 0.45
        }
    }

    private func count(_ d: SyncProgress.PhaseDetail) -> String {
        // The row being worked on shows exact digits, because that is where the
        // eased counter lives and compact form would hide it: at 9.5k totals a
        // "0.1k" step is 100 items, so the number would still sit still for
        // seconds at a time — the very thing the smoothing exists to fix.
        // Finished and queued rows stay compact, where width matters more.
        let synced = smoother.counts[d.phase] ?? d.synced
        if d.state == .syncing {
            if let total = d.total {
                return "\(Self.exact(synced))/\(Self.exact(total))"
            }
            return Self.exact(synced)
        }
        if let total = d.total {
            return "\(Self.compact(synced))/\(Self.compact(total))"
        }
        return Self.compact(synced)
    }

    /// Grouped digits: 5143 → "5,143" (localized separator).
    static func exact(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    /// Compact number formatting: 3720 → "3.7k", 950 → "950".
    static func compact(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000
            let s = String(format: "%.1f", k)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "k"
        }
        return "\(n)"
    }
}

/// A perpetually-animating thin bar, shown before a determinate total is known
/// so the sync UI never looks frozen.
private struct IndeterminateBar: View {
    @State private var animating = false
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule().fill(.secondary.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(30, w * 0.35))
                        .offset(x: animating ? w * 0.95 : -w * 0.35)
                }
                .clipShape(Capsule())
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: false)) {
                animating = true
            }
        }
    }
}
