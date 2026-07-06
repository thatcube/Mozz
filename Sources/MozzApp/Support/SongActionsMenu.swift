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
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                env.playback.append([track.toDomain()])
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            if downloadState != .downloaded {
                Divider()
                Button {
                    let snapshot = track
                    Task { await env.downloadTrack(snapshot.toDomain()) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
        .onChange(of: track.isFavorite) { _, new in isFavorite = new }
        .onChange(of: track.rating) { _, new in rating = new }
    }

    @ViewBuilder private var likeOrRate: some View {
        if env.usesRatings {
            Menu {
                ForEach((1...5).reversed(), id: \.self) { stars in
                    Button {
                        let snapshot = track
                        rating = Double(stars)
                        Task { await env.setRating(Double(stars), track: snapshot) }
                    } label: {
                        Label("\(stars) Star\(stars == 1 ? "" : "s")", systemImage: "star.fill")
                    }
                }
                if (rating ?? 0) > 0 {
                    Button(role: .destructive) {
                        let snapshot = track
                        rating = nil
                        Task { await env.setRating(nil, track: snapshot) }
                    } label: {
                        Label("Clear Rating", systemImage: "star.slash")
                    }
                }
            } label: {
                Label(liked ? "Rated" : "Rate", systemImage: liked ? "star.fill" : "star")
            }
        } else {
            Button {
                let snapshot = track
                let next = !liked
                isFavorite = next
                Task { await env.setLiked(next, track: snapshot) }
            } label: {
                Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart")
            }
        }
    }
}
