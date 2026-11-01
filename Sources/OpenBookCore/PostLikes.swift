import Foundation
import Observation

public struct PostLikeState: Sendable {
    public let liked: Bool
    /// Nil while the write succeeded but the authoritative count is not yet available.
    public let count: Int?
}

@MainActor @Observable
public final class PostLikes {
    public private(set) var states: [String: PostLikeState] = [:]
    public private(set) var pending: Set<String> = []
    public private(set) var errors: [String: String] = [:]
    public private(set) var needsRefresh: Set<String> = []
    public private(set) var revision = 0
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var sessionGeneration = 0

    public init(api: APIClient = APIClient()) { self.api = api }

    public func state(for post: Post) -> PostLikeState {
        states[post.id] ?? PostLikeState(liked: post.postMyInteractions.postLiked, count: post.postCounters.postLikesCount)
    }

    public func ingest(_ posts: [Post], ifRevision expected: Int) {
        // A feed read started before a reaction must not overwrite its newer result.
        guard expected == revision else { return }
        for post in posts where !pending.contains(post.id) {
            states[post.id] = PostLikeState(liked: post.postMyInteractions.postLiked, count: post.postCounters.postLikesCount)
            errors[post.id] = nil
            needsRefresh.remove(post.id)
        }
    }

    public func reset() {
        sessionGeneration += 1
        revision += 1
        states = [:]; pending = []; errors = [:]; needsRefresh = []
    }

    public func toggle(post: Post, credentials: () async throws -> Credentials) async {
        guard !pending.contains(post.id) else { return }
        let current = state(for: post)
        let target = !current.liked
        let generation = sessionGeneration
        states[post.id] = current
        pending.insert(post.id)
        errors[post.id] = nil
        revision += 1
        defer { if generation == sessionGeneration { pending.remove(post.id) } }
        var saved = false
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard generation == sessionGeneration else { return }
            try await api.setLike(postID: post.id, liked: target, credentials: credentials)
            guard generation == sessionGeneration else { return }
            saved = true
            revision += 1
            states[post.id] = PostLikeState(liked: target, count: nil)
            needsRefresh.insert(post.id)
            let updated = try await api.post(id: post.id, credentials: credentials)
            guard generation == sessionGeneration else { return }
            accept(updated)
        } catch {
            guard generation == sessionGeneration else { return }
            errors[post.id] = saved
                ? "Mi piace aggiornato, ma il contatore non è disponibile. Riprova ad aggiornarlo."
                : error.localizedDescription
        }
    }

    /// Read-only recovery: never resends a successful write just to obtain the count.
    public func refresh(post: Post, credentials: () async throws -> Credentials) async {
        guard !pending.contains(post.id) else { return }
        let generation = sessionGeneration
        pending.insert(post.id)
        revision += 1
        defer { if generation == sessionGeneration { pending.remove(post.id) } }
        do {
            let credentials = try await credentials()
            guard generation == sessionGeneration else { return }
            let updated = try await api.post(id: post.id, credentials: credentials)
            guard generation == sessionGeneration else { return }
            accept(updated)
        } catch {
            if generation == sessionGeneration { errors[post.id] = error.localizedDescription }
        }
    }

    private func accept(_ post: Post) {
        states[post.id] = PostLikeState(liked: post.postMyInteractions.postLiked, count: post.postCounters.postLikesCount)
        errors[post.id] = nil
        needsRefresh.remove(post.id)
        revision += 1
    }
}
