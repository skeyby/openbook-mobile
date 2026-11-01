import Foundation
import Observation

/// Requests addressed to the authenticated account, independent of outgoing follows.
@MainActor @Observable
public final class IncomingFollowRequests {
    public private(set) var people: [PersonReference] = []
    public private(set) var cursor: String?
    public private(set) var pageRevision = 0
    public private(set) var hasNext = false
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var changingID: String?
    public private(set) var errorMessage: String?
    public private(set) var requiresReload = false
    public var isChanging: Bool { changingID != nil }
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seenCursors: Set<String> = []

    public init(api: APIClient = APIClient()) { self.api = api }

    public func reset() {
        generation += 1
        pageRevision += 1
        people = []; cursor = nil; hasNext = false; hasLoaded = false
        isLoading = false; changingID = nil; errorMessage = nil; requiresReload = false; seenCursors = []
    }

    public func load(reset: Bool, credentials: () async throws -> Credentials) async {
        guard !isLoading, !isChanging, reset || (hasNext && !requiresReload) else { return }
        let session = generation
        isLoading = true
        errorMessage = nil
        defer { if session == generation { isLoading = false } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard session == generation else { return }
            let page = try await api.followRequests(after: reset ? nil : cursor, credentials: credentials)
            try Task.checkCancellation()
            guard session == generation else { return }
            if reset { people = []; seenCursors = []; requiresReload = false }
            var ids = Set(people.map(\.id))
            people.append(contentsOf: page.people.filter { ids.insert($0.id).inserted })
            cursor = page.people.last?.id
            if let cursor { hasNext = page.hasNext && seenCursors.insert(cursor).inserted }
            else { hasNext = false }
            hasLoaded = true
            pageRevision += 1
        } catch {
            guard session == generation else { return }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            if case OpenBookError.http(let code, _) = error, [401, 403].contains(code) {
                people = []; cursor = nil; hasNext = false; hasLoaded = false; seenCursors = []
            }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func decide(personID: String, accept: Bool, credentials: () async throws -> Credentials) async -> Bool {
        let id = personID.lowercased()
        guard !isLoading, !isChanging, !requiresReload, people.contains(where: { $0.id.lowercased() == id }) else { return false }
        let session = generation
        changingID = id
        errorMessage = nil
        defer { if session == generation { changingID = nil } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard session == generation else { return false }
            try await api.decideFollowRequest(personID: id, accept: accept, credentials: credentials)
            guard session == generation else { return false }
            people.removeAll { $0.id.lowercased() == id }
            return true
        } catch {
            guard session == generation else { return false }
            // No automatic replay: the request may have been withdrawn or handled meanwhile.
            requiresReload = true
            errorMessage = "\(error.localizedDescription) Ricarica le richieste prima di riprovare."
            if case OpenBookError.http(let code, _) = error, [401, 403].contains(code) {
                people = []; cursor = nil; hasNext = false; hasLoaded = false
            }
            return false
        }
    }
}
