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

    public init(content: String, visibility: PostVisibility) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenBookError.message("Scrivi il testo del post prima di pubblicare.")
        }
        postContent = content
        postVisibility = visibility
    }
}

public struct PostCreation: Sendable {
    /// HTTP 201 confirms publication even if a newer representation cannot be decoded.
    public let post: Post?
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
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?
    public private(set) var uncertain = false
    public private(set) var publication: PostCreation?
    @ObservationIgnored private let api: APIClient

    public init(api: APIClient = APIClient()) { self.api = api }
    public var hasDraft: Bool { !content.isEmpty }
    public var canSubmit: Bool {
        !isSubmitting && !uncertain && publication == nil && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func submit(credentials: () async throws -> Credentials) async -> PostCreation? {
        guard canSubmit else { return nil }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let draft = try NewPost(content: content, visibility: visibility)
            let credentials = try await credentials()
            try Task.checkCancellation()
            let result = try await api.createPost(draft, credentials: credentials)
            publication = result
            return result
        } catch {
            uncertain = error is PostCreationError
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Only after an explicit user decision: POST has no idempotency guarantee.
    public func allowAnotherAttempt() { guard !isSubmitting else { return }; uncertain = false }
    public func reset() {
        guard !isSubmitting else { return }
        content = ""; visibility = .public; errorMessage = nil; uncertain = false; publication = nil
    }
}
