import Foundation
import Observation

public struct PatchPost: Encodable, Sendable {
    public let postContent: String?
    public let postVisibility: PostVisibility?

    public init(content: String? = nil, visibility: PostVisibility? = nil) throws {
        guard content != nil || visibility != nil else { throw OpenBookError.message("Non ci sono modifiche da salvare.") }
        if let content, content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpenBookError.message("Il testo del post non può essere vuoto.")
        }
        postContent = content
        postVisibility = visibility
    }
}

/// Session-only overlays prevent old feed responses from undoing confirmed changes.
@MainActor @Observable
public final class PostManagement {
    public private(set) var updates: [String: Post] = [:]
    public private(set) var deleted: Set<String> = []
    public private(set) var pending: Set<String> = []
    public private(set) var errors: [String: String] = [:]
    public private(set) var revision = 0
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var generation = 0

    public init(api: APIClient = APIClient()) { self.api = api }
    public func current(_ post: Post) -> Post? {
        guard !deleted.contains(post.id) else { return nil }
        return (updates[post.id] ?? post).preservingFeedContext(of: post)
    }
    public func ingest(_ posts: [Post], ifRevision expected: Int) {
        guard expected == revision else { return }
        for post in posts where !pending.contains(post.id) { updates[post.id] = nil }
    }
    public func reset() {
        generation += 1; revision += 1
        updates = [:]; deleted = []; pending = []; errors = [:]
    }

    public func edit(post: Post, patch: PatchPost, currentPersonID: String?, credentials: () async throws -> Credentials) async -> Post? {
        guard post.isOwned(by: currentPersonID), !pending.contains(post.id), !deleted.contains(post.id) else { return nil }
        let session = generation
        pending.insert(post.id); errors[post.id] = nil; revision += 1
        defer { if session == generation { pending.remove(post.id) } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard session == generation else { return nil }
            let updated = try await api.editPost(id: post.id, patch: patch, credentials: credentials)
            guard session == generation else { return nil }
            updates[post.id] = updated
            revision += 1
            return updated
        } catch {
            guard session == generation else { return nil }
            if case OpenBookError.http(409, _) = error {
                errors[post.id] = "Questo post contiene elementi che l’API non permette ancora di modificare. Nessuna modifica applicata."
            } else { errors[post.id] = "Salvataggio non confermato. \(error.localizedDescription) Rileggi il post prima di riprovare." }
            return nil
        }
    }

    public func delete(post: Post, currentPersonID: String?, credentials: () async throws -> Credentials) async -> Bool {
        guard post.isOwned(by: currentPersonID), !pending.contains(post.id), !deleted.contains(post.id) else { return false }
        let session = generation
        pending.insert(post.id); errors[post.id] = nil; revision += 1
        defer { if session == generation { pending.remove(post.id) } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard session == generation else { return false }
            try await api.deletePost(id: post.id, credentials: credentials)
            guard session == generation else { return false }
            deleted.insert(post.id); updates[post.id] = nil; revision += 1
            return true
        } catch {
            if session == generation { errors[post.id] = "Cancellazione non confermata. \(error.localizedDescription) Aggiorna la timeline prima di riprovare." }
            return false
        }
    }
}

@MainActor @Observable
public final class PostEditor: Identifiable {
    public let id: String
    public var content = ""
    public var visibility: PostVisibility = .public
    public private(set) var original: Post?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private let currentPersonID: String
    @ObservationIgnored private let api: APIClient

    public init(postID: String, currentPersonID: String, api: APIClient = APIClient()) {
        id = postID; self.currentPersonID = currentPersonID; self.api = api
    }
    public var hasChanges: Bool {
        guard let original else { return false }
        return content != original.postContent || visibility.rawValue != original.postVisibility
    }
    public var canSave: Bool { original != nil && hasChanges && !isLoading && !isSaving && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func load(credentials: () async throws -> Credentials) async {
        guard !isLoading, !isSaving else { return }
        isLoading = true; errorMessage = nil; original = nil
        defer { isLoading = false }
        do {
            let credentials = try await credentials()
            let post = try await api.post(id: id, credentials: credentials)
            try Task.checkCancellation()
            guard post.isOwned(by: currentPersonID) else { throw OpenBookError.message("Puoi modificare soltanto i tuoi post.") }
            guard post.supportsBasicEditing, let audience = PostVisibility(rawValue: post.postVisibility) else {
                throw OpenBookError.message("Questo post contiene elementi che non sono ancora modificabili nell’app.")
            }
            original = post; content = post.postContent; visibility = audience
        } catch { errorMessage = error.localizedDescription }
    }

    public func save(using management: PostManagement, credentials: () async throws -> Credentials) async -> Bool {
        guard canSave, let original else { return false }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            let patch = try PatchPost(content: content == original.postContent ? nil : content,
                                      visibility: visibility.rawValue == original.postVisibility ? nil : visibility)
            if let updated = await management.edit(post: original, patch: patch, currentPersonID: currentPersonID, credentials: credentials) {
                self.original = updated
                content = updated.postContent
                visibility = PostVisibility(rawValue: updated.postVisibility) ?? visibility
                return true
            }
            errorMessage = management.errors[id] ?? "Impossibile salvare il post."
        } catch { errorMessage = error.localizedDescription }
        return false
    }
}
