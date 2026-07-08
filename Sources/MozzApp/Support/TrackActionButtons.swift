import SwiftUI
import MozzCore
import MozzDatabase

/// The surface a track menu is shown on. Drives conditional inclusion — e.g. we
/// hide "Go to Album" on the album's own detail page, and the player pushes nav
/// cross-context (it lives outside the tab stacks).
enum TrackActionSurface {
    case row, albumDetail, artistDetail, player

    var navOrigin: NavOrigin { self == .player ? .player : .tab }
}

/// The shared, backend-agnostic set of track actions rendered as menu content.
///
/// This is the single source of truth for the "what can I do with this track"
/// buttons, so the row "…" menu (``SongActionsMenu``), long-press context menus,
/// and the Now Playing overflow menu all offer the same actions in the same order
/// and never drift. It emits only the *stateless, fire-and-forget* actions
/// (queue, station, navigation, download); surface-specific stateful controls
/// (Like/Rate, which need a popover/anchor, and the Add-to-Playlist sheet) stay
/// with the host so their presentation can be anchored correctly — a `.popover`/
/// `.confirmationDialog` attached to menu content does not present reliably.
///
/// Drop it inside any `Menu { }` or `.contextMenu { }`:
/// ```swift
/// Menu { TrackActionButtons(track: rec.toDomain(), downloadState: state, internalId: rec.id) }
///     label: { … }
/// ```
struct TrackActionButtons: View {
    @EnvironmentObject private var env: AppEnvironment

    /// The domain track the actions operate on (queue/station/download all take
    /// a ``Track``). Rows convert their `TrackRecord` via `toDomain()`; the player
    /// passes `playback.currentTrack` directly.
    let track: Track
    /// Current download state, used to swap Download ⇄ Remove Download.
    var downloadState: DownloadState?
    /// The catalog's internal `Int64` id, required to *remove* a download
    /// (`DownloadManager.deleteDownload(trackInternalId:)`). Rows have it; if a
    /// caller can't supply it, Remove Download is hidden.
    var internalId: Int64?
    /// Which surface this menu is shown on (drives Go to Artist/Album visibility
    /// and the cross-context player push).
    var surface: TrackActionSurface = .row

    private var canGoToArtist: Bool { track.artistID != nil && surface != .artistDetail }
    private var canGoToAlbum: Bool { track.albumID != nil && surface != .albumDetail }

    var body: some View {
        Button {
            env.playback.playNext([track])
        } label: {
            Label("Play Next", mozz: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            env.playback.append([track])
        } label: {
            Label("Add to Queue", mozz: "text.append")
        }
        Button {
            env.startRadio(fromTrack: track)
        } label: {
            Label("Start Station", mozz: "dot.radiowaves.left.and.right")
        }

        if canGoToArtist || canGoToAlbum {
            Divider()
            if canGoToArtist {
                Button {
                    let remoteId = track.artistID
                    let origin = surface.navOrigin
                    Task {
                        // Present-but-unsynced → no-op (rare; the nil-id case is
                        // already hidden above). No toast surface exists yet.
                        guard let artist = await env.resolveArtist(remoteId: remoteId) else { return }
                        env.requestNavigation(to: .artist(artist), from: origin)
                    }
                } label: {
                    Label("Go to Artist", mozz: "music.mic")
                }
            }
            if canGoToAlbum {
                Button {
                    let remoteId = track.albumID
                    let origin = surface.navOrigin
                    Task {
                        guard let album = await env.resolveAlbum(remoteId: remoteId) else { return }
                        env.requestNavigation(to: .album(album), from: origin)
                    }
                } label: {
                    Label("Go to Album", mozz: "square.stack")
                }
            }
        }

        Divider()

        if downloadState == .downloaded {
            if let internalId {
                Button(role: .destructive) {
                    Task { try? await env.downloads.deleteDownload(trackInternalId: internalId) }
                } label: {
                    Label("Remove Download", mozz: "trash")
                }
            }
        } else {
            Button {
                let snapshot = track
                Task { await env.downloadTrack(snapshot) }
            } label: {
                Label("Download", mozz: "arrow.down.circle")
            }
        }

        Divider()

        Button {
            let snapshot = track
            Task { await env.suppressTrack(snapshot) }
        } label: {
            Label("Don't recommend this track", mozz: "hand.thumbsdown")
        }
        if track.artistID != nil {
            Button {
                let snapshot = track
                Task { await env.suppressArtist(ofTrack: snapshot) }
            } label: {
                Label("Don't recommend this artist", mozz: "hand.thumbsdown")
            }
        }
    }
}
