import SwiftUI
import MozzSync

/// A slim, non-blocking status bar shown at the top of the app while a catalog
/// sync is running. It persists across every tab (a top safe-area inset on the
/// tab shell), so the user can browse and play freely during the first sync and
/// always sees exactly what's happening — a live per-type breakdown plus an
/// overall percentage — instead of one opaque number that jumps and stalls.
struct SyncStatusBar: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if env.isSyncing {
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
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(env.syncStatusText ?? "Syncing your library"))
        }
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
                    if d.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                    Text(d.phase.label)
                        .foregroundStyle(.secondary)
                    Text(count(d))
                        .foregroundStyle(d.isComplete ? .secondary : .primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.caption2)
                .opacity(d.isComplete ? 0.6 : 1)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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
