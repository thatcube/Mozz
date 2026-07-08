import SwiftUI
import MozzCore
import MozzDatabase

/// The per-track overflow ("…") menu shown on list rows. Replaces the inline
/// like/rating control: the like/rate actions now live here alongside queue and
/// download actions, keeping rows clean.
///
/// The like/rate action is backend-aware (heart for favorites backends, a star
/// submenu for ratings backends) and writes through ``AppEnvironment`` (local DB
/// first, server sync queued).
struct SongActionsMenu: View {
    @EnvironmentObject private var env: AppEnvironment
    let track: TrackRecord
    var downloadState: DownloadState?

    @State private var isFavorite: Bool
    @State private var rating: Double?
    @State private var showingRatingPopover = false

    init(track: TrackRecord, downloadState: DownloadState? = nil) {
        self.track = track
        self.downloadState = downloadState
        _isFavorite = State(initialValue: track.isFavorite)
        _rating = State(initialValue: track.rating)
    }

    private var liked: Bool {
        LikePolicy.isLiked(isFavorite: isFavorite, rating: rating)
    }

    var body: some View {
        Menu {
            likeOrRate
            Divider()
            Button {
                env.playback.playNext([track.toDomain()])
            } label: {
                Label("Play Next", mozz: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                env.playback.append([track.toDomain()])
            } label: {
                Label("Add to Queue", mozz: "text.append")
            }
            Button {
                env.startRadio(fromTrack: track.toDomain())
            } label: {
                Label("Start Station", mozz: "dot.radiowaves.left.and.right")
            }
            if downloadState != .downloaded {
                Divider()
                Button {
                    let snapshot = track
                    Task { await env.downloadTrack(snapshot.toDomain()) }
                } label: {
                    Label("Download", mozz: "arrow.down.circle")
                }
            } else if let internalID = track.id {
                Divider()
                Button {
                    Task { try? await env.downloads.deleteDownload(trackInternalId: internalID) }
                } label: {
                    Label("Remove Download", mozz: "trash")
                }
            }
        } label: {
            Image(mozz: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
        .popover(isPresented: $showingRatingPopover) {
            RatingPopoverContent(rating: rating) { newValue in
                let snapshot = track
                rating = newValue
                Task { await env.setRating(newValue, track: snapshot) }
            }
        }
        .onChange(of: track.isFavorite) { _, new in isFavorite = new }
        .onChange(of: track.rating) { _, new in rating = new }
    }

    @ViewBuilder private var likeOrRate: some View {
        if env.usesRatings {
            Button {
                showingRatingPopover = true
            } label: {
                Label("Rate…", mozz: (rating ?? 0) > 0 ? "star.fill" : "star")
            }
        } else {
            Button {
                let snapshot = track
                let next = !liked
                isFavorite = next
                Task { await env.setLiked(next, track: snapshot) }
            } label: {
                Label(liked ? "Unlike" : "Like", mozz: liked ? "heart.fill" : "heart")
            }
        }
    }
}
