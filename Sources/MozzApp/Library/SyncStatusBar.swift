import SwiftUI

/// A slim, non-blocking status bar shown at the top of the app while a catalog
/// sync is running. It persists across every tab (it's a top safe-area inset on
/// the tab shell), so the user can browse and play freely during the first sync
/// and always knows it's still working — instead of being stuck on the setup
/// screen watching a progress bar.
struct SyncStatusBar: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if env.isSyncing {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(env.syncStatusText ?? "Syncing your library…")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    if let fraction = env.syncFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(height: 2)
                            .tint(.accentColor)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.06)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(env.syncStatusText ?? "Syncing your library"))
        }
    }
}
