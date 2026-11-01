import Foundation
import Testing
@testable import OpenBookCore

private final class LikeBackend: @unchecked Sendable {
    static let shared = LikeBackend()
    struct State {
        var liked = false
        var count = 3
        var writes = 0
        var reads = 0
        var writeFailure: Int?
        var failRead = false
        var validRequest = true
    }
    private let lock = NSLock()
    private var sessions: [String: State] = [:]

    func update(_ key: String, _ edit: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var state = sessions[key] ?? State()
        edit(&state)
        sessions[key] = state
    }
    func snapshot(_ key: String) -> State {
        lock.lock(); defer { lock.unlock() }
        return sessions[key] ?? State()
    }
    func respond(_ request: URLRequest) -> (Int, Data) {
        let key = request.value(forHTTPHeaderField: "X-Test-Session")!
        var status = 200
        var body = Data()
        update(key) { state in
            let base = "/rest/v1/posts/01900000-0000-7000-8000-000000000002"
            state.validRequest = state.validRequest && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
            if request.url?.path == base + "/like" {
                state.writes += 1
                state.validRequest = state.validRequest && request.httpBody == nil && request.httpBodyStream == nil
                if let failure = state.writeFailure { status = failure; body = Data(#"{"detail":"Operazione non consentita."}"#.utf8); return }
                if request.httpMethod == "PUT" {
                    status = state.liked ? 204 : 201
                    if !state.liked { state.liked = true; state.count += 1 }
                } else if request.httpMethod == "DELETE" {
                    status = 204
                    if state.liked { state.liked = false; state.count -= 1 }
                } else { state.validRequest = false; status = 405 }
            } else if request.url?.path == base && request.httpMethod == "GET" {
                state.reads += 1
                if state.failRead { status = 503; return }
                let fixture = Bundle.module.url(forResource: "posts-world", withExtension: "json", subdirectory: "Fixtures")!
                var post = (try! JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [[String: Any]])[0]
                var counters = post["postCounters"] as! [String: Any]
                counters["postLikesCount"] = state.count; post["postCounters"] = counters
                var interactions = post["postMyInteractions"] as! [String: Any]
                interactions["postLiked"] = state.liked; post["postMyInteractions"] = interactions
                body = try! JSONSerialization.data(withJSONObject: post)
            } else { state.validRequest = false; status = 404 }
        }
        return (status, body)
    }
}

private final class LikeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = LikeBackend.shared.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct LikeTests {
    private func setup() throws -> (String, APIClient, Credentials, Post) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LikeProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Session": key]
        let api = APIClient(session: URLSession(configuration: config))
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        let credentials = try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token)
        let fixture = Bundle.module.url(forResource: "posts-world", withExtension: "json", subdirectory: "Fixtures")!
        let post = try JSONDecoder().decode([Post].self, from: Data(contentsOf: fixture))[0]
        return (key, api, credentials, post)
    }

    @Test func put201And204AndDelete204HaveNoJSONBody() async throws {
        let (key, api, credentials, post) = try setup()
        try await api.setLike(postID: post.id, liked: true, credentials: credentials)
        try await api.setLike(postID: post.id, liked: true, credentials: credentials)
        #expect(LikeBackend.shared.snapshot(key).count == 4)
        try await api.setLike(postID: post.id, liked: false, credentials: credentials)
        try await api.setLike(postID: post.id, liked: false, credentials: credentials)
        #expect(LikeBackend.shared.snapshot(key).count == 3)
        #expect(LikeBackend.shared.snapshot(key).validRequest)
    }

    @Test func toggleUsesServerStateAndDoesNotAcceptAnOlderFeedRead() async throws {
        let (key, api, credentials, post) = try setup()
        let likes = PostLikes(api: api)
        let earlierRead = likes.revision
        await likes.toggle(post: post) { credentials }
        #expect(likes.state(for: post).liked)
        #expect(likes.state(for: post).count == 4)
        likes.ingest([post], ifRevision: earlierRead)
        #expect(likes.state(for: post).count == 4)
        await likes.toggle(post: post) { credentials }
        #expect(!likes.state(for: post).liked)
        #expect(likes.state(for: post).count == 3)
        #expect(LikeBackend.shared.snapshot(key).reads == 2)
        #expect(likes.pending.isEmpty)
    }

    @Test(arguments: [403, 404, 429]) func failedWritePreservesState(status: Int) async throws {
        let (key, api, credentials, post) = try setup()
        LikeBackend.shared.update(key) { $0.writeFailure = status }
        let likes = PostLikes(api: api)
        await likes.toggle(post: post) { credentials }
        #expect(!likes.state(for: post).liked)
        #expect(likes.state(for: post).count == 3)
        #expect(likes.errors[post.id] != nil)
        #expect(likes.pending.isEmpty)
        #expect(LikeBackend.shared.snapshot(key).reads == 0)
    }

    @Test func successfulWriteWithFailedReadRecoversWithoutAnotherWrite() async throws {
        let (key, api, credentials, post) = try setup()
        LikeBackend.shared.update(key) { $0.failRead = true }
        let likes = PostLikes(api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await likes.toggle(post: post) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        let readStartedBeforeWriteConfirmation = likes.revision
        release?.resume(returning: credentials)
        await task.value
        likes.ingest([post], ifRevision: readStartedBeforeWriteConfirmation)
        #expect(likes.state(for: post).liked)
        #expect(likes.state(for: post).count == nil)
        #expect(likes.needsRefresh.contains(post.id))
        #expect(likes.errors[post.id] != nil)
        LikeBackend.shared.update(key) { $0.failRead = false }
        await likes.refresh(post: post) { credentials }
        #expect(likes.state(for: post).count == 4)
        #expect(likes.errors[post.id] == nil)
        #expect(!likes.needsRefresh.contains(post.id))
        #expect(LikeBackend.shared.snapshot(key).writes == 1)
    }

    @Test func duplicateTapWhileCredentialsArePendingDoesNotSendTwice() async throws {
        let (key, api, credentials, post) = try setup()
        let likes = PostLikes(api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let first = Task { await likes.toggle(post: post) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        await likes.toggle(post: post) { Issue.record("Duplicate tap requested credentials"); return credentials }
        release?.resume(returning: credentials)
        await first.value
        #expect(LikeBackend.shared.snapshot(key).writes == 1)
    }

    @Test func disconnectDiscardsPendingWorkAndClearsSessionState() async throws {
        let (key, api, credentials, post) = try setup()
        let likes = PostLikes(api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await likes.toggle(post: post) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        likes.reset()
        release?.resume(returning: credentials)
        await task.value
        #expect(likes.states.isEmpty)
        #expect(likes.pending.isEmpty)
        #expect(likes.errors.isEmpty)
        #expect(LikeBackend.shared.snapshot(key).writes == 0)
    }

    @Test func invalidPostIDIsRejectedBeforeSending() async throws {
        let (key, api, credentials, _) = try setup()
        await #expect(throws: (any Error).self) { try await api.setLike(postID: "../invalid", liked: true, credentials: credentials) }
        #expect(LikeBackend.shared.snapshot(key).writes == 0)
    }
}
