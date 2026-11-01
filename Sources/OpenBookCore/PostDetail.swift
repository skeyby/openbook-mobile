import Foundation
import Observation

@MainActor @Observable
public final class PostDetail {
    public let postID: String
    public private(set) var post: Post?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private let api: APIClient

    public init(postID: String, api: APIClient = APIClient()) {
        self.postID = postID
        self.api = api
    }

    @discardableResult
    public func load(credentials: () async throws -> Credentials) async -> Post? {
        guard !isLoading else { return nil }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            let fresh = try await api.post(id: postID, credentials: credentials)
            try Task.checkCancellation()
            post = fresh
            return fresh
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            post = nil
            errorMessage = error.localizedDescription
        }
        return nil
    }
}
