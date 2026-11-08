import Foundation
import Observation

@MainActor @Observable
public final class CommentFeed {
    public enum Availability: Equatable, Sendable { case unknown, available, unsupported }
    public private(set) var availability: Availability = .unknown
    public var canWrite: Bool { availability == .available }
    public var unavailableMessage: String? {
        availability == .unsupported
            ? "Questa istanza non rende disponibili i commenti per questo post. Il server potrebbe non supportare ancora questa funzione."
            : nil
    }
    public let postID: String
    public private(set) var comments: [Comment] = []
    public private(set) var nextPage: URL?
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var needsRestart = false
    public var hasNext: Bool { nextPage != nil }
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var seenPages: Set<URL> = []
    @ObservationIgnored private var resetRequested = false

    public init(postID: String, api: APIClient = APIClient()) { self.postID = postID; self.api = api }

    @discardableResult
    public func load(reset: Bool, retry: Bool = false, credentials: () async throws -> Credentials) async -> [Comment]? {
        if isLoading {
            if reset { resetRequested = true }
            return nil
        }
        guard reset || (hasNext && !needsRestart && (errorMessage == nil || retry)) else { return nil }
        isLoading = true; errorMessage = nil
        var result: [Comment]?
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            let page = try await api.comments(postID: postID, nextPage: reset ? nil : nextPage, credentials: credentials)
            try Task.checkCancellation()
            // A mutation requested a fresh first page while this read was in flight.
            // Do not publish the obsolete cursor: changing it would cancel the List task.
            if !resetRequested {
                if reset { comments = []; seenPages = []; needsRestart = false }
                var ids = Set(comments.map { $0.id.lowercased() })
                comments.append(contentsOf: page.comments.filter { ids.insert($0.id.lowercased()).inserted })
                if !page.comments.isEmpty, let next = page.nextPage, seenPages.insert(next).inserted { nextPage = next }
                else { nextPage = nil }
                hasLoaded = true
                availability = .available
                result = page.comments
            }
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            errorMessage = error.localizedDescription
            if case OpenBookError.http(let code, _) = error {
                if code == 422 { needsRestart = true }
                if [401, 403, 404, 405, 501].contains(code) {
                    comments = []; nextPage = nil; seenPages = []; hasLoaded = false
                    availability = .unknown
                }
                if [405, 501].contains(code) { markUnsupported() }
                if code == 404 {
                    // A list 404 can also mean the post disappeared or lost visibility.
                    // Only soften it into feature unavailability if the post is still readable.
                    do {
                        let auth = try await credentials()
                        try Task.checkCancellation()
                        _ = try await api.post(id: postID, credentials: auth)
                        try Task.checkCancellation()
                        markUnsupported()
                    } catch is CancellationError { }
                    catch let checkError as URLError where checkError.code == .cancelled { }
                    catch { /* Keep the original access/resource error and offer explicit retry. */ }
                }
            }
        }
        isLoading = false
        let restart = resetRequested
        resetRequested = false
        if restart && !Task.isCancelled { return await load(reset: true, credentials: credentials) }
        return result
    }

    private func markUnsupported() {
        availability = .unsupported
        errorMessage = nil
        needsRestart = false
        resetRequested = false
    }
}
