import Foundation
import Observation

@MainActor @Observable
public final class CommentEditor {
    public enum Mode: Sendable {
        case create(parentID: String?, parentName: String?)
        case edit(commentID: String)
    }
    public let postID: String
    public let mode: Mode
    public var content = ""
    public private(set) var original: Comment?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var uncertain = false
    public private(set) var requiresReload = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private let currentPersonID: String?
    @ObservationIgnored private let api: APIClient
    public init(postID: String, mode: Mode, currentPersonID: String?, api: APIClient = APIClient()) {
        self.postID = postID; self.mode = mode; self.currentPersonID = currentPersonID; self.api = api
    }
    public var isEditing: Bool { if case .edit = mode { true } else { false } }
    public var hasDraft: Bool { isEditing ? original.map { content != $0.commentContent } ?? !content.isEmpty : !content.isEmpty }
    public var canSave: Bool {
        !isLoading && !isSaving && !uncertain && !requiresReload && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (!isEditing || (original != nil && hasDraft))
    }
    public func load(credentials: () async throws -> Credentials) async {
        guard case .edit(let id) = mode, !isLoading, !isSaving else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            let fresh = try await api.comment(postID: postID, id: id, credentials: credentials)
            try Task.checkCancellation()
            guard fresh.isOwned(by: currentPersonID) else { throw OpenBookError.message("Puoi modificare soltanto i tuoi commenti.") }
            original = fresh; content = fresh.commentContent; requiresReload = false
        } catch {
            requiresReload = true
            errorMessage = error.localizedDescription
        }
    }
    /// Only called after explicit duplicate-warning confirmation.
    public func allowAnotherAttempt() { guard !isSaving else { return }; uncertain = false }

    public func save(using management: CommentManagement, credentials: () async throws -> Credentials) async -> Bool {
        guard canSave else { return false }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            switch mode {
            case .create(let parentID, _):
                let draft = try NewComment(content: content, parentID: parentID)
                _ = try await management.create(postID: postID, draft: draft, credentials: credentials)
            case .edit:
                guard let original else { return false }
                _ = try await management.edit(original, content: content, currentPersonID: currentPersonID, credentials: credentials)
            }
            content = ""; original = nil
            return true
        } catch {
            uncertain = error is CommentCreationError
            if isEditing { requiresReload = true }
            errorMessage = isEditing
                ? "Salvataggio non confermato. \(error.localizedDescription) Rileggi il commento prima di riprovare."
                : error.localizedDescription
            return false
        }
    }
}
