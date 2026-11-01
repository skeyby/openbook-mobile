import Foundation
import Testing
@testable import OpenBookCore

private let ownedPostID = "01900000-0000-7000-8000-000000000002"
private let olderPostID = "01900000-0000-7000-8000-000000000004"

private final class MyPostsBackend: @unchecked Sendable {
    static let shared = MyPostsBackend()
    struct State { var requests = 0; var valid = true; var status = 200 }
    private let lock = NSLock()
    private var sessions: [String: State] = [:]
    func update(_ key: String, _ edit: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var value = sessions[key] ?? State(); edit(&value); sessions[key] = value
    }
    func state(_ key: String) -> State { lock.lock(); defer { lock.unlock() }; return sessions[key] ?? State() }
    func response(_ request: URLRequest) -> (Int, Data, [String: String]) {
        let key = request.value(forHTTPHeaderField: "X-Test-Session")!
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        update(key) {
            $0.requests += 1
            $0.valid = $0.valid && request.url?.path == "/rest/v1/me/posts" && request.httpMethod == "GET" &&
                request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" &&
                query["sort"] == "postPublishedAt" && query["direction"] == "desc" && query["limit"] == "20" &&
                Set(query.keys).isSubset(of: ["after", "limit", "sort", "direction"])
        }
        let status = state(key).status
        if status != 200 { return (status, Data(#"{"detail":"Ricarica la lista."}"#.utf8), [:]) }
        let fixture = Bundle.module.url(forResource: "my-posts", withExtension: "json", subdirectory: "Fixtures")!
        let original = (try! JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [[String: Any]])[0]
        var older = original
        older["postId"] = olderPostID; older["postPublishedAt"] = "2026-10-24T10:00:00Z"
        older["postVisibility"] = "followers"
        let posts: [[String: Any]]
        let next: String?
        switch query["after"] {
        case nil: posts = [original]; next = ownedPostID
        case ownedPostID: posts = [original, older]; next = olderPostID
        default: posts = []; next = nil
        }
        let headers = next.map { ["Link": "<https://example.org/rest/v1/me/posts?limit=20&sort=postPublishedAt&direction=desc&after=\($0)>; rel=\"next\""] } ?? [:]
        return (200, try! JSONSerialization.data(withJSONObject: posts), headers)
    }
}

private final class MyPostsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data, headers) = MyPostsBackend.shared.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct MyPostsTests {
    private func setup() throws -> (String, APIClient, Credentials) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MyPostsProtocol.self]; config.httpAdditionalHeaders = ["X-Test-Session": key]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (key, APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token))
    }

    @Test func ownedPostsUsePublicationCursorAndKeepRestrictedPosts() async throws {
        let (key, api, credentials) = try setup()
        let feed = PostFeed(source: .mine, api: api)
        await feed.load(reset: true) { credentials }
        let first = try #require(feed.timeline.posts.first)
        #expect(first.postAnnounce == nil && first.postTimelineAt == nil)
        #expect(first.isOwned(by: "01900000-0000-7000-8000-000000000001"))
        let next = try #require(feed.timeline.nextPage)
        #expect(next.path == "/rest/v1/me/posts")
        await feed.load(reset: false) { credentials }
        #expect(feed.timeline.posts.map(\.id) == [ownedPostID, olderPostID])
        #expect(feed.timeline.posts.last?.postVisibility == "followers")
        await feed.load(reset: false) { credentials }
        #expect(!feed.timeline.hasNext)
        #expect(MyPostsBackend.shared.state(key).valid)
        #expect(MyPostsBackend.shared.state(key).requests == 3)
    }

    @Test(arguments: [422, 503]) func failedPageKeepsPostsAndAllowsRestart(status: Int) async throws {
        let (key, api, credentials) = try setup()
        let feed = PostFeed(source: .mine, api: api)
        await feed.load(reset: true) { credentials }
        let next = feed.timeline.nextPage
        MyPostsBackend.shared.update(key) { $0.status = status }
        await feed.load(reset: false) { credentials }
        #expect(feed.errorMessage != nil)
        #expect(feed.timeline.posts.count == 1)
        #expect(feed.timeline.nextPage == next)
        #expect(MyPostsBackend.shared.state(key).requests == 2)
        MyPostsBackend.shared.update(key) { $0.status = 200 }
        await feed.load(reset: true) { credentials }
        #expect(feed.errorMessage == nil)
        #expect(feed.timeline.posts.map(\.id) == [ownedPostID])
    }

    @Test(arguments: [401, 403]) func lostAccessClearsPrivateRows(status: Int) async throws {
        let (key, api, credentials) = try setup()
        let feed = PostFeed(source: .mine, api: api)
        await feed.load(reset: true) { credentials }
        MyPostsBackend.shared.update(key) { $0.status = status }
        await feed.load(reset: false) { credentials }
        #expect(feed.timeline.posts.isEmpty)
        #expect(!feed.timeline.hasNext)
    }

    @Test func paginationCannotSwitchSourceOrUseUnsupportedParameters() async throws {
        let (key, api, credentials) = try setup()
        let base = "https://example.org/rest/v1/me/posts?after=\(ownedPostID)"
        for link in [base + "&engine=world", base + "&afterAt=2026-10-25T12:00:00Z", base + "&cursor=x", base + "&page=2", base + "&sort=postTimelineAt", base + "&direction=asc", base + "&after=\(olderPostID)", base.replacingOccurrences(of: "/me/", with: "/persons/01900000-0000-7000-8000-000000000001/"), base.replacingOccurrences(of: "example.org", with: "other.example"), base.replacingOccurrences(of: ownedPostID, with: "invalid")] {
            await #expect(throws: (any Error).self) { try await api.posts(source: .mine, nextPage: URL(string: link), credentials: credentials) }
        }
        // A /me/posts cursor must also be rejected when loading somebody else's profile.
        await #expect(throws: (any Error).self) { try await api.posts(source: .person("01900000-0000-7000-8000-000000000001"), nextPage: URL(string: base), credentials: credentials) }
        #expect(MyPostsBackend.shared.state(key).requests == 0)
    }
}
