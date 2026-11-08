import Foundation
import Observation

/// Shared session overlays: old lists cannot restore deleted comments or undo edits.
@MainActor @Observable
public final class CommentManagement {
    public private(set) var updates: [String: Comment] = [:]
    public private(set) var deleted: Set<String> = []
    public private(set) var pending: Set<String> = []
    public private(set) var revision = 0
    public private(set) var unknownCounts: Set<String> = []
    public private(set) var countPending: Set<String> = []
    public private(set) var countErrors: [String: String] = [:]
    private var postCounts: [String: Int] = [:]
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var generation = 0

    public init(api: APIClient = APIClient()) { self.api = api }
    public func reset() {
        generation += 1; revision += 1
        updates = [:]; deleted = []; pending = []
        postCounts = [:]; unknownCounts = []; countPending = []; countErrors = [:]
    }
    public func current(_ comment: Comment) -> Comment? {
        let id = comment.id.lowercased()
        return deleted.contains(id) ? nil : updates[id] ?? comment
    }
    public func ingest(_ comments: [Comment], ifRevision expected: Int) {
        guard expected == revision else { return }
        for comment in comments where !pending.contains(comment.id.lowercased()) { updates[comment.id.lowercased()] = nil }
    }
    public func count(for post: Post) -> Int? {
        unknownCounts.contains(post.id.lowercased()) ? nil : postCounts[post.id.lowercased()] ?? post.postCounters.postCommentsCount
    }
    public func ingestPosts(_ posts: [Post], ifRevision expected: Int) {
        guard expected == revision else { return }
        for post in posts where !countPending.contains(post.id.lowercased()) {
            let id = post.id.lowercased()
            postCounts[id] = post.postCounters.postCommentsCount
            unknownCounts.remove(id); countErrors[id] = nil
        }
    }
    public func refreshCount(postID: String, credentials: () async throws -> Credentials) async {
        let id = postID.lowercased()
        guard !countPending.contains(id) else { return }
        let session = generation; let expected = revision
        countPending.insert(id)
        defer { if generation == session { countPending.remove(id) } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard generation == session else { return }
            let post = try await api.post(id: id, credentials: credentials)
            try Task.checkCancellation()
            guard generation == session, expected == revision else { return }
            postCounts[id] = post.postCounters.postCommentsCount
            unknownCounts.remove(id); countErrors[id] = nil
        } catch {
            guard generation == session, !Task.isCancelled else { return }
            unknownCounts.insert(id)
            countErrors[id] = "Contatore commenti non disponibile. Puoi rileggerlo senza ripetere l’operazione."
        }
    }

    public func create(postID: String, draft: NewComment, credentials: () async throws -> Credentials) async throws -> CommentCreation {
        let key = "create:\(postID.lowercased())"
        guard !pending.contains(key) else { throw OpenBookError.message("Pubblicazione già in corso.") }
        let session = generation
        pending.insert(key); revision += 1
        defer { if session == generation { pending.remove(key) } }
        let credentials = try await credentials()
        try Task.checkCancellation()
        guard session == generation else { throw CancellationError() }
        let result = try await api.createComment(postID: postID, draft: draft, credentials: credentials)
        guard session == generation else { throw CancellationError() }
        if let comment = result.comment { updates[comment.id.lowercased()] = comment }
        changed(postID: postID)
        return result
    }

    public func edit(_ comment: Comment, content: String, currentPersonID: String?, credentials: () async throws -> Credentials) async throws -> Comment {
        let id = comment.id.lowercased()
        guard comment.isOwned(by: currentPersonID), !deleted.contains(id), !pending.contains(id) else {
            throw OpenBookError.message("Non puoi modificare questo commento.")
        }
        let patch = try PatchComment(content: content)
        let session = generation
        pending.insert(id); revision += 1
        defer { if session == generation { pending.remove(id) } }
        let credentials = try await credentials()
        try Task.checkCancellation()
        guard session == generation else { throw CancellationError() }
        let result = try await api.editComment(postID: comment.commentPostId, id: id, patch: patch, credentials: credentials)
        guard session == generation else { throw CancellationError() }
        updates[id] = result; revision += 1
        return result
    }

    public func delete(_ comment: Comment, currentPersonID: String?, credentials: () async throws -> Credentials) async throws {
        let id = comment.id.lowercased()
        guard comment.isOwned(by: currentPersonID), !deleted.contains(id), !pending.contains(id) else {
            throw OpenBookError.message("Non puoi eliminare questo commento.")
        }
        let session = generation
        pending.insert(id); revision += 1
        defer { if session == generation { pending.remove(id) } }
        let credentials = try await credentials()
        try Task.checkCancellation()
        guard session == generation else { throw CancellationError() }
        try await api.deleteComment(postID: comment.commentPostId, id: id, credentials: credentials)
        guard session == generation else { throw CancellationError() }
        deleted.insert(id); updates[id] = nil
        changed(postID: comment.commentPostId)
    }

    private func changed(postID: String) {
        revision += 1
        unknownCounts.insert(postID.lowercased())
    }
}
