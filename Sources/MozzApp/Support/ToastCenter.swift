import SwiftUI

/// A transient, non-modal confirmation shown briefly at the bottom of the screen.
///
/// Toasts are Mozz's answer to "did that action work?" — and, for a small set of
/// reversible actions, "let me take that back". The research behind the feature
/// (design-doc §9) is explicit that Undo must be *reserved*: undo-on-everything
/// trains users to ignore toasts (the "cry-wolf" effect) and floods VoiceOver. So
/// only two actions carry an ``action`` (Undo): "Don't recommend" and "Remove
/// Download". Everything additive gets a plain confirmation; visual toggles
/// (Like/Rate) and navigation get no toast at all.
public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    /// One short line, directly describing what just happened.
    public let message: String
    /// Optional leading SF Symbol / Tabler glyph name (resolved via `Image(mozz:)`).
    public var icon: String?
    /// The single optional action (Material's one-action-per-snackbar rule). When
    /// present it renders as a trailing button — used exclusively for Undo.
    public var action: ToastAction?
    /// Auto-dismiss delay. ~2.5s for plain confirmations, ~8s when an Undo action
    /// is present so a deliberate user has time to reach for it.
    public var duration: Double

    public static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// The single trailing action a toast may carry (Undo).
public struct ToastAction {
    public let title: String
    public let handler: @MainActor () -> Void
}

/// Owns the currently-visible toast and its auto-dismiss timer.
///
/// Held by ``AppEnvironment`` as a stable reference and injected as its own
/// `environmentObject`, so any `env`-scoped view can raise a toast without
/// threading a binding through, and the overlay observes *only* the toast state
/// (not the whole environment's `@Published` graph).
@MainActor
public final class ToastCenter: ObservableObject {
    @Published public private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    /// Standard durations (Material's 4s/10s split, tuned down a touch for iOS).
    enum Duration {
        static let plain: Double = 2.5
        static let undo: Double = 8
    }

    /// Present a toast, replacing any current one and (re)arming auto-dismiss.
    public func show(_ toast: Toast) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            current = toast
        }
        announce(toast)
        let id = toast.id
        let delay = toast.duration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    /// Convenience for a plain confirmation toast (no action).
    public func confirm(_ message: String, icon: String? = nil) {
        show(Toast(message: message, icon: icon, action: nil, duration: Duration.plain))
    }

    /// Convenience for a reversible action toast carrying a single Undo button.
    public func undoable(_ message: String, icon: String? = nil,
                  undoTitle: String = "Undo", undo: @MainActor @escaping () -> Void) {
        show(Toast(message: message, icon: icon,
                   action: ToastAction(title: undoTitle, handler: undo),
                   duration: Duration.undo))
    }

    /// Dismiss the given toast if it is still the current one (ignore stale timers).
    public func dismiss(id: UUID) {
        guard current?.id == id else { return }
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            current = nil
        }
    }

    /// Run a toast's action then dismiss it (used by the overlay's Undo button).
    public func performAction(_ toast: Toast) {
        toast.action?.handler()
        dismiss(id: toast.id)
    }

    /// Post a VoiceOver announcement so the toast is perceivable without moving
    /// focus (WCAG 4.1.3). Undo toasts hint how to reverse.
    private func announce(_ toast: Toast) {
        var phrase = toast.message
        if toast.action != nil { phrase += ". Double-tap to \(toast.action!.title.lowercased())." }
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: phrase)
        #endif
    }
}
