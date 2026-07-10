import SwiftUI
import MozzCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Reorder events

/// Emitted by an up-next row's drag handle and consumed by the container
/// (`NowPlayingMorph`), which owns the whole reorder session + the overlay that
/// renders the floating row. Coordinates are GLOBAL (screen) space so the
/// container can position the overlay against the same coordinate system.
enum QueueReorderEvent {
    /// Finger pressed a handle and started dragging. `index` is the grabbed row's
    /// up-next offset (0-based, 0 = plays next). `rowHeight`/`regionTopY` are the
    /// list geometry captured at pickup.
    case begin(index: Int, fingerY: CGFloat, rowHeight: CGFloat, regionTopY: CGFloat)
    /// Finger moved to a new global Y.
    case change(fingerY: CGFloat)
    /// Finger lifted — commit the current target.
    case end
    /// Gesture cancelled — abandon without moving.
    case cancel
}

// MARK: - Reorder session

/// A live drag-reorder session's mutable state, owned by the container while a
/// row is being dragged. `tracks` is the up-next snapshot taken at pickup; all Y
/// values are GLOBAL. Auto-scroll shifts `contentBaseY`; the finger drives
/// `fingerY`; `targetIndex` is the current insertion slot (final-position
/// semantics — the grabbed row will land AT this offset).
struct QueueReorderSession: Equatable {
    var tracks: [Track]
    var fromIndex: Int
    var rowHeight: CGFloat
    /// Global Y of the visible region's top (just under the pinned "Queue" header)
    /// — rows above this are clipped.
    var regionTopY: CGFloat
    /// Global Y the reordering list may extend down to (the reclaimed drawer
    /// bottom once the transport chrome has slid away).
    var regionBottomY: CGFloat
    /// Global Y of slot-0's top. Seeded so the grabbed row sits exactly under the
    /// finger at pickup; shifted by auto-scroll thereafter.
    var contentBaseY: CGFloat
    var fingerY: CGFloat
    var targetIndex: Int

    var count: Int { tracks.count }

    /// The tracks excluding the grabbed one, preserving order (the rows that part
    /// to open a gap).
    var otherTracks: [Track] {
        var t = tracks
        if t.indices.contains(fromIndex) { t.remove(at: fromIndex) }
        return t
    }

    /// Total laid-out height of all up-next slots.
    var contentHeight: CGFloat { CGFloat(count) * rowHeight }

    /// Clamp `contentBaseY` so the list can't be auto-scrolled past its ends.
    mutating func clampContentBase() {
        let maxBase = regionTopY                                   // slot 0 pinned at region top
        let minBase = min(regionTopY, regionBottomY - contentHeight) // last slot at region bottom
        contentBaseY = Swift.min(maxBase, Swift.max(minBase, contentBaseY))
    }

    /// The insertion slot nearest the finger, clamped to a valid offset.
    func computeTarget() -> Int {
        let raw = (fingerY - contentBaseY) / max(rowHeight, 1)
        return Swift.max(0, Swift.min(count - 1, Int(raw.rounded(.down))))
    }
}

// MARK: - Reorder overlay

/// The full-drawer layer shown while a row is being dragged. Draws every up-next
/// row from the session snapshot: the non-grabbed rows part to open a row-sized
/// gap at `targetIndex`, and the grabbed row floats under the finger with a
/// lifted highlight + shadow. Positioned in GLOBAL space (the host ZStack fills
/// the screen from the top-left origin), so slot Y values are used directly.
struct QueueReorderOverlay: View {
    let session: QueueReorderSession
    /// Global X of the row content's left edge and its width (drawer inset by 24).
    let contentLeftX: CGFloat
    let contentWidth: CGFloat

    var body: some View {
        let others = session.otherTracks
        ZStack(alignment: .topLeading) {
            ForEach(Array(others.enumerated()), id: \.offset) { j, track in
                rowContent(track, lifted: false)
                    .frame(width: contentWidth, height: session.rowHeight, alignment: .center)
                    .offset(x: contentLeftX, y: slotY(forOther: j))
            }

            if session.tracks.indices.contains(session.fromIndex) {
                rowContent(session.tracks[session.fromIndex], lifted: true)
                    .frame(width: contentWidth, height: session.rowHeight, alignment: .center)
                    .offset(x: contentLeftX,
                            y: session.fingerY - session.rowHeight / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: session.targetIndex)
        // Only paint within the reclaimed list region; rows scrolled above the
        // header or below the drawer are clipped away.
        .mask(alignment: .topLeading) {
            Rectangle()
                .frame(height: max(0, session.regionBottomY - session.regionTopY))
                .offset(y: session.regionTopY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Y (global) of a non-grabbed row: its slot, pushed down by one row once past
    /// the open gap at `targetIndex`.
    private func slotY(forOther j: Int) -> CGFloat {
        let slot = j < session.targetIndex ? j : j + 1
        return session.contentBaseY + CGFloat(slot) * session.rowHeight
    }

    @ViewBuilder
    private func rowContent(_ track: Track, lifted: Bool) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: track.artwork,
                        seed: track.albumTitle ?? track.title,
                        size: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(mozz: "line.3.horizontal")
                .font(.body)
                .foregroundStyle(lifted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .padding(.vertical, 6)
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    // Extend the highlight a little past the content without
                    // shifting the row itself, so grabbed + parted rows stay aligned.
                    .padding(.horizontal, -10)
            }
        }
        .contentShape(Rectangle())
    }
}
