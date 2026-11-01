import Foundation
import Observation

public enum PostSource: Hashable, Sendable {
    case feed(PostEngine)
    case person(String)
    case mine

    var path: String {
        switch self {
        case .feed: "/rest/v1/posts"
        case .mine: "/rest/v1/me/posts"
        case .person(let id): "/rest/v1/persons/\(id.lowercased())/posts"
        }
    }
    var sort: String {
        switch self { case .feed(let engine): engine.sort; case .person: "postTimelineAt"; case .mine: "postPublishedAt" }
    }
    var query: [URLQueryItem] {
        var items = [URLQueryItem(name: "sort", value: sort), .init(name: "direction", value: "desc")]
        if case .feed(let engine) = self {
            items += [.init(name: "engine", value: engine.rawValue), .init(name: "limit", value: "20")]
        }
        if case .mine = self { items.append(.init(name: "limit", value: "20")) }
        return items
    }
    func validate() throws {
        if case .person(let id) = self, UUID(uuidString: id) == nil {
            throw OpenBookError.message("Identificativo della persona non valido.")
        }
    }
}

/// The same loading, pagination and failure semantics for home and profile feeds.
@MainActor @Observable
public final class PostFeed {
    public let source: PostSource
    public private(set) var timeline = PostTimeline()
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private let api: APIClient

    public init(source: PostSource, api: APIClient = APIClient()) { self.source = source; self.api = api }

    @discardableResult
    public func load(reset: Bool, credentials: () async throws -> Credentials) async -> PostsPage? {
        guard !isLoading, reset || timeline.hasNext else { return nil }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            let page = try await api.posts(source: source, nextPage: reset ? nil : timeline.nextPage, credentials: credentials)
            try Task.checkCancellation()
            timeline.apply(page, replacing: reset)
            return page
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            if case OpenBookError.http(let status, _) = error, [401, 403, 404].contains(status) { timeline.clear() }
            errorMessage = error.localizedDescription
        }
        return nil
    }
}
