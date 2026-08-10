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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(env.syncStatusText ?? "Syncing your library"))
    }

    // MARK: Header — title, %, progress bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Syncing your library")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(overallText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
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

    private func breakdown(_ details: [SyncProgress.PhaseDetail]) -> some View {
        HStack(spacing: 10) {
            ForEach(details) { d in
                HStack(spacing: 4) {
                    switch d.state {
                    case .done:
                        Image(mozz: "checkmark.circle.fill")
                            .resizable().scaledToFit().frame(width: 9, height: 9)
                            .foregroundStyle(.green)
                    case .syncing:
                        // small active dot
                        Circle().fill(.tint).frame(width: 5, height: 5)
                    case .pending:
                        Image(mozz: "circle")
                            .resizable().scaledToFit().frame(width: 8, height: 8)
                            .foregroundStyle(.tertiary)
                    }
                    Text(d.phase.label)
                        .foregroundStyle(.secondary)
                    if d.state != .pending {
                        Text(count(d))
                            .foregroundStyle(d.state == .done ? .secondary : .primary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .font(.caption2)
                .opacity(opacity(for: d.state))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.65)
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
