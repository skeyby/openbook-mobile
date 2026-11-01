import Foundation
import Testing
@testable import OpenBookCore

private let profileID = "01900000-0000-7000-8000-000000000003"
private let firstPostID = "01900000-0000-7000-8000-000000000002"
private let secondPostID = "01900000-0000-7000-8000-000000000004"
private let boundary = "2026-10-26T12:00:00.123456+02:00"

private final class ProfileFeedBackend: @unchecked Sendable {
    static let shared = ProfileFeedBackend()
    struct State { var requests = 0; var valid = true; var status = 200 }
    private let lock = NSLock()
    private var sessions: [String: State] = [:]
    func update(_ key: String, _ edit: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }; var value = sessions[key] ?? State(); edit(&value); sessions[key] = value
    }
    func state(_ key: String) -> State { lock.lock(); defer { lock.unlock() }; return sessions[key] ?? State() }
    func response(_ request: URLRequest) -> (Int, Data, [String: String]) {
        let key = request.value(forHTTPHeaderField: "X-Test-Session")!
        let url = request.url!
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        update(key) {
            $0.requests += 1
            $0.valid = $0.valid && request.httpMethod == "GET" && url.path == "/rest/v1/persons/\(profileID)/posts" &&
                request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" &&
                query["sort"] == "postTimelineAt" && query["direction"] == "desc" &&
                query["limit"] == nil && query["engine"] == nil
            if query["after"] == firstPostID { $0.valid = $0.valid && query["afterAt"] == boundary }
            if query["after"] == nil { $0.valid = $0.valid && query["afterAt"] == nil }
        }
        let status = state(key).status
        if status != 200 { return (status, Data(#"{"detail":"Feed non disponibile."}"#.utf8), [:]) }
        let fixture = Bundle.module.url(forResource: "person-posts", withExtension: "json", subdirectory: "Fixtures")!
        var original = (try! JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [[String: Any]])[0]
        original["postTimelineAt"] = boundary
        var older = original
        older["postId"] = secondPostID; older["postTimelineAt"] = "2026-10-25T10:00:00Z"
        older["postUri"] = "https://example.org/posts/\(secondPostID)"
        let posts: [[String: Any]]
        let cursor: String?
        let time: String
        switch query["after"] {
        case nil: posts = [original]; cursor = firstPostID; time = boundary
        case firstPostID: posts = [original, older]; cursor = secondPostID; time = "2026-10-25T10:00:00Z"
        default: posts = []; cursor = nil; time = ""
        }
        var headers: [String: String] = [:]
        if let cursor {
            var parts = URLComponents(string: "https://example.org/rest/v1/persons/\(profileID)/posts")!
            parts.queryItems = [.init(name: "sort", value: "postTimelineAt"), .init(name: "direction", value: "desc"), .init(name: "after", value: cursor), .init(name: "afterAt", value: time)]
            let link = parts.url!.absoluteString.replacingOccurrences(of: "+", with: "%2B")
            headers["Link"] = "<\(link)>; rel=\"next\""
        }
        return (200, try! JSONSerialization.data(withJSONObject: posts), headers)
    }
}

private final class ProfileFeedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data, headers) = ProfileFeedBackend.shared.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct ProfileFeedTests {
    private func setup() throws -> (String, APIClient, Credentials) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileFeedProtocol.self]; config.httpAdditionalHeaders = ["X-Test-Session": key]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (key, APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token))
    }

    @Test func profileUsesCompositeCursorWithoutEngineOrPageSize() async throws {
        let (key, api, credentials) = try setup()
        let feed = PostFeed(source: .person(profileID.uppercased()), api: api)
        await feed.load(reset: true) { credentials }
        let first = try #require(feed.timeline.posts.first)
        #expect(first.postAuthor.id != profileID)
        #expect(first.postAnnounce?.announceAuthor.id == profileID)
        let next = try #require(feed.timeline.nextPage)
        #expect(URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "afterAt" }?.value == boundary)
        await feed.load(reset: false) { credentials }
        #expect(feed.timeline.posts.map(\.id) == [firstPostID, secondPostID])
        await feed.load(reset: false) { credentials }
        #expect(!feed.timeline.hasNext)
        #expect(feed.timeline.posts.count == 2)
        #expect(ProfileFeedBackend.shared.state(key).requests == 3)
        #expect(ProfileFeedBackend.shared.state(key).valid)
    }

    @Test(arguments: [401, 403, 404]) func unavailableProfileFeedClearsLoadedPosts(status: Int) async throws {
        let (key, api, credentials) = try setup()
        let feed = PostFeed(source: .person(profileID), api: api)
        await feed.load(reset: true) { credentials }
        ProfileFeedBackend.shared.update(key) { $0.status = status }
        await feed.load(reset: false) { credentials }
        #expect(feed.timeline.posts.isEmpty)
        #expect(!feed.timeline.hasNext)
        #expect(feed.errorMessage != nil)
    }

    @Test func temporaryFailureKeepsRowsAndCursorUntilExplicitRetry() async throws {
        let (key, api, credentials) = try setup()
        let feed = PostFeed(source: .person(profileID), api: api)
        await feed.load(reset: true) { credentials }
        let cursor = feed.timeline.nextPage
        ProfileFeedBackend.shared.update(key) { $0.status = 503 }
        await feed.load(reset: false) { credentials }
        #expect(feed.timeline.posts.count == 1)
        #expect(feed.timeline.nextPage == cursor)
        #expect(ProfileFeedBackend.shared.state(key).requests == 2)
        ProfileFeedBackend.shared.update(key) { $0.status = 200 }
        await feed.load(reset: false) { credentials }
        #expect(feed.timeline.posts.count == 2)
        #expect(feed.errorMessage == nil)
        await feed.load(reset: true) { credentials }
        #expect(feed.timeline.posts.map(\.id) == [firstPostID])
    }

    @Test func cannotFollowLinksForOtherProfilesOrUnsupportedParameters() async throws {
        let (key, api, credentials) = try setup()
        let base = "https://example.org/rest/v1/persons/\(profileID)/posts?after=\(firstPostID)&afterAt=2026-10-26T10:00:00Z"
        for link in [base + "&limit=20", base + "&engine=timeline", base.replacingOccurrences(of: profileID, with: secondPostID), base.replacingOccurrences(of: "example.org", with: "untrusted.example"), base.components(separatedBy: "&afterAt")[0]] {
            await #expect(throws: (any Error).self) {
                try await api.posts(source: .person(profileID), nextPage: URL(string: link), credentials: credentials)
            }
        }
        #expect(ProfileFeedBackend.shared.state(key).requests == 0)
    }

    @Test func duplicateAndCancelledLoadsDoNotSendRequests() async throws {
        let (key, api, credentials) = try setup()
        let feed = PostFeed(source: .person(profileID), api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await feed.load(reset: true) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        #expect(await feed.load(reset: true) { Issue.record("Duplicate requested credentials"); return credentials } == nil)
        task.cancel(); release?.resume(returning: credentials)
        #expect(await task.value == nil)
        #expect(!feed.isLoading)
        #expect(feed.errorMessage == nil)
        #expect(ProfileFeedBackend.shared.state(key).requests == 0)
    }

    @Test func invalidPersonIdentifierDoesNotSendRequests() async throws {
        let (key, api, credentials) = try setup()
        await #expect(throws: (any Error).self) { try await api.posts(source: .person("../invalid"), credentials: credentials) }
        #expect(ProfileFeedBackend.shared.state(key).requests == 0)
    }
}
