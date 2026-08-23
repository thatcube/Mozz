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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let details = env.syncProgress?.details, !details.isEmpty {
                breakdown(details)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
    }

    // MARK: Header — title, %, progress bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
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
            if let fraction = env.syncFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(height: 3)
                    .tint(.accentColor)
            } else {
                IndeterminateBar().frame(height: 3)
            }
        }
    }

    private var titleLine: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Syncing your library")
                .font(.footnote.weight(.semibold))
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
        if let fraction = env.syncFraction {
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
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            statusGlyph(detail.state)
                // Reserve one glyph's width for every row so the labels align in a
                // column regardless of which state each row is in.
                .frame(width: glyph, alignment: .center)
            Text(detail.phase.label)
                .foregroundStyle(detail.state == .pending ? .tertiary : .secondary)
            Spacer(minLength: 6)
            if detail.state != .pending {
                Text(count(detail))
                    .foregroundStyle(detail.state == .done ? .secondary : .primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
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
        case .syncing: return Text("\(detail.phase.label), \(count(detail))")
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
        if let total = d.total {
            return "\(Self.compact(d.synced))/\(Self.compact(total))"
        }
        return Self.compact(d.synced)
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
