import Foundation
import Observation

public struct PostAnnounceState: Sendable {
    /// Manual share only; quote-associated implicit shares do not activate the toggle.
    public let announced: Bool
    /// Nil while the write succeeded but the authoritative count is not yet available.
    public let count: Int?
}

@MainActor @Observable
public final class PostAnnounces {
    public private(set) var states: [String: PostAnnounceState] = [:]
    public private(set) var pending: Set<String> = []
    public private(set) var errors: [String: String] = [:]
    public private(set) var needsRefresh: Set<String> = []
    public private(set) var revision = 0
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var sessionGeneration = 0

    public init(api: APIClient = APIClient()) { self.api = api }

    public func state(for post: Post) -> PostAnnounceState {
        states[post.id] ?? PostAnnounceState(announced: post.postMyInteractions.postDirectAnnounced, count: post.postCounters.postAnnouncesCount)
    }

    /// Removal remains possible even when the post's visibility has become restricted.
    public func canToggle(post: Post) -> Bool {
        state(for: post).announced || ["public", "unlisted"].contains(post.postVisibility)
    }

    public func ingest(_ posts: [Post], ifRevision expected: Int) {
        // A feed read started before a reaction must not overwrite its newer result.
        guard expected == revision else { return }
        for post in posts where !pending.contains(post.id) {
            states[post.id] = PostAnnounceState(announced: post.postMyInteractions.postDirectAnnounced, count: post.postCounters.postAnnouncesCount)
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
        guard canToggle(post: post) else { return }
        let current = state(for: post)
        let target = !current.announced
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
            try await api.setAnnounce(postID: post.id, announced: target, credentials: credentials)
            guard generation == sessionGeneration else { return }
            saved = true
            revision += 1
            states[post.id] = PostAnnounceState(announced: target, count: nil)
            needsRefresh.insert(post.id)
            let updated = try await api.post(id: post.id, credentials: credentials)
            guard generation == sessionGeneration else { return }
            accept(updated)
        } catch {
            guard generation == sessionGeneration else { return }
            errors[post.id] = saved
                ? "Rilancio aggiornato, ma il contatore non è disponibile. Riprova ad aggiornarlo."
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
        states[post.id] = PostAnnounceState(announced: post.postMyInteractions.postDirectAnnounced, count: post.postCounters.postAnnouncesCount)
        errors[post.id] = nil
        needsRefresh.remove(post.id)
        revision += 1
    }
}
