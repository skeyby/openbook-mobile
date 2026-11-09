import Foundation
import Observation

public enum PostVisibility: String, CaseIterable, Identifiable, Codable, Sendable {
    case `public`, unlisted, followers
    public var id: String { rawValue }
    public var title: String {
        switch self { case .public: "Pubblico"; case .unlisted: "Non in elenco"; case .followers: "Solo follower" }
    }
}

public struct NewPost: Encodable, Sendable {
    public let postContent: String
    public let postVisibility: PostVisibility
    public let postAttachments: [NewPostAttachment]?

    public init(content: String, visibility: PostVisibility, attachments: [NewPostAttachment]? = nil) throws {
        let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || (content.isEmpty && !(attachments?.isEmpty ?? true)) else {
            throw OpenBookError.message("Scrivi il testo del post prima di pubblicare.")
        }
        postContent = content
        postVisibility = visibility
        postAttachments = attachments
    }
}

public struct PostCreation: Sendable {
    /// HTTP 201 confirms publication even if a newer representation cannot be decoded.
    public let post: Post?
    public let wasDeferred: Bool
    public let deferredPublication: PostPublication?
    public let monitorID: String?
    public init(post: Post?, wasDeferred: Bool = false, deferredPublication: PostPublication? = nil, monitorID: String? = nil) {
        self.post = post; self.wasDeferred = wasDeferred; self.deferredPublication = deferredPublication; self.monitorID = monitorID
    }
}

public enum PostCreationError: LocalizedError, Sendable {
    case uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .uncertain(let detail):
            "Pubblicazione non confermata. Il post potrebbe essere già stato creato: controlla la timeline prima di riprovare. \(detail)"
        }
    }
}

@MainActor @Observable
public final class PostComposer {
    public var content = ""
    public var visibility: PostVisibility = .public
    public var isImporting = false
    public private(set) var attachments: [DraftAttachment] = []
    public private(set) var uploadLimits: InstanceUploadLimits?
    public func setUploadLimits(_ limits: InstanceUploadLimits?) { uploadLimits = limits }
    public var requestByteCount: Int64? {
        guard let draft = try? makeDraft(files: attachments) else { return nil }
        if attachments.isEmpty { return try? Int64(JSONEncoder().encode(draft).count) }
        return try? MultipartPost.bodyByteCount(draft: draft, files: attachments)
    }
    public var preflightError: String? {
        guard !attachments.isEmpty || uploadLimits?.maxRequestBytes != nil else { return nil }
        guard let draft = try? makeDraft(files: attachments) else { return nil }
        do { try validate(files: attachments, draft: draft, limits: uploadLimits); return nil }
        catch { return error.localizedDescription }
    }
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?
    public private(set) var uncertain = false
    public private(set) var publication: PostCreation?
    @ObservationIgnored private let api: APIClient

    public init(api: APIClient = APIClient()) { self.api = api }
    public var hasDraft: Bool { !content.isEmpty || !attachments.isEmpty }
    public var isBusy: Bool { isSubmitting || isImporting }
    public var canSubmit: Bool {
        !isBusy && !uncertain && publication == nil &&
            (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (content.isEmpty && !attachments.isEmpty)) &&
            attachments.allSatisfy { $0.altText.unicodeScalars.count <= 1000 } && preflightError == nil
    }
    @discardableResult public func add(_ attachment: DraftAttachment) -> Bool {
        guard !isSubmitting, !uncertain, publication == nil, !attachments.contains(where: { $0.id == attachment.id }) else { return false }
        let candidates = attachments + [attachment]
        do {
            guard let uploadLimits else { throw OpenBookError.message("Questa istanza non comunica i limiti di caricamento: gli allegati non sono disponibili.") }
            try uploadLimits.validate(files: candidates)
            if let draft = try? makeDraft(files: candidates) {
                try uploadLimits.validate(requestBytes: MultipartPost.bodyByteCount(draft: draft, files: candidates))
            }
            attachments = candidates; errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    public func removeAttachment(id: UUID) {
        guard !isBusy, !uncertain else { return }
        attachments.removeAll { $0.id == id }; errorMessage = nil
    }
    public func setAltText(id: UUID, text: String) {
        guard !isBusy, !uncertain, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].altText = text
    }
    public func moveAttachment(id: UUID, offset: Int) {
        guard !isBusy, !uncertain, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard attachments.indices.contains(target) else { return }
        attachments.swapAt(index, target)
    }

    public func submit(refreshLimits: (() async throws -> InstanceUploadLimits?)? = nil, credentials: () async throws -> Credentials) async -> PostCreation? {
        guard canSubmit else { return nil }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let files = attachments
            let draft = try makeDraft(files: files)
            if !files.isEmpty {
                if let refreshLimits { uploadLimits = try await refreshLimits() }
            }
            try validate(files: files, draft: draft, limits: uploadLimits)
            let credentials = try await credentials()
            try Task.checkCancellation()
            let result = try await api.createPost(draft, files: files, limits: uploadLimits, credentials: credentials)
            publication = result
            return result
        } catch {
            uncertain = error is PostCreationError
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func makeDraft(files: [DraftAttachment]) throws -> NewPost {
        let metadata = try files.enumerated().map { try NewPostAttachment(filePart: "attachment\($0.offset + 1)", altText: $0.element.altText) }
        return try NewPost(content: content, visibility: visibility, attachments: files.isEmpty ? nil : metadata)
    }
    private func validate(files: [DraftAttachment], draft: NewPost, limits: InstanceUploadLimits?) throws {
        if files.isEmpty {
            try limits?.validate(requestBytes: Int64(JSONEncoder().encode(draft).count))
            return
        }
        guard let limits else { throw OpenBookError.message("Questa istanza non comunica i limiti di caricamento: gli allegati non sono disponibili.") }
        try limits.validate(files: files)
        try limits.validate(requestBytes: MultipartPost.bodyByteCount(draft: draft, files: files))
    }

    /// Only after an explicit user decision: POST has no idempotency guarantee.
    public func allowAnotherAttempt() { guard !isSubmitting else { return }; uncertain = false }
    public func reset() {
        guard !isBusy else { return }
        content = ""; visibility = .public; attachments = []; errorMessage = nil; uncertain = false; publication = nil
    }
}
