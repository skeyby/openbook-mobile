import Foundation
import Testing
@testable import OpenBookCore

private final class AnnounceBackend: @unchecked Sendable {
    static let shared = AnnounceBackend()
    struct State {
        var announced = false
        var implicitShare = false
        var count = 1
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
            if request.url?.path == base + "/announce" {
                state.writes += 1
                state.validRequest = state.validRequest && request.httpBody == nil && request.httpBodyStream == nil
                if let failure = state.writeFailure { status = failure; body = Data(#"{"detail":"Operazione non consentita."}"#.utf8); return }
                if request.httpMethod == "PUT" {
                    status = state.announced ? 204 : 201
                    if !state.announced { state.announced = true; if !state.implicitShare { state.count += 1 } }
                } else if request.httpMethod == "DELETE" {
                    status = 204
                    if state.announced { state.announced = false; if !state.implicitShare { state.count -= 1 } }
                } else { state.validRequest = false; status = 405 }
            } else if request.url?.path == base && request.httpMethod == "GET" {
                state.reads += 1
                if state.failRead { status = 503; return }
                let fixture = Bundle.module.url(forResource: "posts-world", withExtension: "json", subdirectory: "Fixtures")!
                var post = (try! JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [[String: Any]])[0]
                var counters = post["postCounters"] as! [String: Any]
                counters["postAnnouncesCount"] = state.count; post["postCounters"] = counters
                var interactions = post["postMyInteractions"] as! [String: Any]
                interactions["postDirectAnnounced"] = state.announced
                interactions["postAnnounced"] = state.announced || state.implicitShare
                post["postMyInteractions"] = interactions
                body = try! JSONSerialization.data(withJSONObject: post)
            } else { state.validRequest = false; status = 404 }
        }
        return (status, body)
    }
}

private final class AnnounceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = AnnounceBackend.shared.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct AnnounceTests {
    private func setup() throws -> (String, APIClient, Credentials, Post) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnnounceProtocol.self]
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
        try await api.setAnnounce(postID: post.id, announced: true, credentials: credentials)
        try await api.setAnnounce(postID: post.id, announced: true, credentials: credentials)
        #expect(AnnounceBackend.shared.snapshot(key).count == 2)
        try await api.setAnnounce(postID: post.id, announced: false, credentials: credentials)
        try await api.setAnnounce(postID: post.id, announced: false, credentials: credentials)
        #expect(AnnounceBackend.shared.snapshot(key).count == 1)
        #expect(AnnounceBackend.shared.snapshot(key).validRequest)
    }

    @Test func toggleUsesServerStateAndDoesNotAcceptAnOlderFeedRead() async throws {
        let (key, api, credentials, post) = try setup()
        let announces = PostAnnounces(api: api)
        let earlierRead = announces.revision
        await announces.toggle(post: post) { credentials }
        #expect(announces.state(for: post).announced)
        #expect(announces.state(for: post).count == 2)
        announces.ingest([post], ifRevision: earlierRead)
        #expect(announces.state(for: post).count == 2)
        await announces.toggle(post: post) { credentials }
        #expect(!announces.state(for: post).announced)
        #expect(announces.state(for: post).count == 1)
        #expect(AnnounceBackend.shared.snapshot(key).reads == 2)
        #expect(announces.pending.isEmpty)
    }

    @Test(arguments: [401, 403, 404, 429, 500, 503, 200]) func failedWritePreservesState(status: Int) async throws {
        let (key, api, credentials, post) = try setup()
        AnnounceBackend.shared.update(key) { $0.writeFailure = status }
        let announces = PostAnnounces(api: api)
        await announces.toggle(post: post) { credentials }
        #expect(!announces.state(for: post).announced)
        #expect(announces.state(for: post).count == 1)
        #expect(announces.errors[post.id] != nil)
        #expect(announces.pending.isEmpty)
        #expect(AnnounceBackend.shared.snapshot(key).reads == 0)
    }

    @Test func successfulWriteWithFailedReadRecoversWithoutAnotherWrite() async throws {
        let (key, api, credentials, post) = try setup()
        AnnounceBackend.shared.update(key) { $0.failRead = true }
        let announces = PostAnnounces(api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await announces.toggle(post: post) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        let readStartedBeforeWriteConfirmation = announces.revision
        release?.resume(returning: credentials)
        await task.value
        announces.ingest([post], ifRevision: readStartedBeforeWriteConfirmation)
        #expect(announces.state(for: post).announced)
        #expect(announces.state(for: post).count == nil)
        #expect(announces.needsRefresh.contains(post.id))
        #expect(announces.errors[post.id] != nil)
        AnnounceBackend.shared.update(key) { $0.failRead = false }
        await announces.refresh(post: post) { credentials }
        #expect(announces.state(for: post).count == 2)
        #expect(announces.errors[post.id] == nil)
        #expect(!announces.needsRefresh.contains(post.id))
        #expect(AnnounceBackend.shared.snapshot(key).writes == 1)
    }

    @Test func duplicateTapWhileCredentialsArePendingDoesNotSendTwice() async throws {
        let (key, api, credentials, post) = try setup()
        let announces = PostAnnounces(api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let first = Task { await announces.toggle(post: post) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        await announces.toggle(post: post) { Issue.record("Duplicate tap requested credentials"); return credentials }
        release?.resume(returning: credentials)
        await first.value
        #expect(AnnounceBackend.shared.snapshot(key).writes == 1)
    }

    @Test func disconnectDiscardsPendingWorkAndClearsSessionState() async throws {
        let (key, api, credentials, post) = try setup()
        let announces = PostAnnounces(api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await announces.toggle(post: post) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        announces.reset()
        release?.resume(returning: credentials)
        await task.value
        #expect(announces.states.isEmpty)
        #expect(announces.pending.isEmpty)
        #expect(announces.errors.isEmpty)
        #expect(AnnounceBackend.shared.snapshot(key).writes == 0)
    }

    @Test func quoteShareIsPromotedAndRemovalPreservesTheImplicitShare() async throws {
        let (key, api, credentials, post) = try setup()
        AnnounceBackend.shared.update(key) { $0.implicitShare = true }
        let quoted = try await api.post(id: post.id, credentials: credentials)
        #expect(quoted.postMyInteractions.postAnnounced)
        let announces = PostAnnounces(api: api)
        #expect(!announces.state(for: quoted).announced)
        await announces.toggle(post: quoted) { credentials }
        #expect(announces.state(for: quoted).announced)
        #expect(announces.state(for: quoted).count == 1)
        await announces.toggle(post: quoted) { credentials }
        #expect(!announces.state(for: quoted).announced)
        #expect(announces.state(for: quoted).count == 1)
        let fresh = try await api.post(id: post.id, credentials: credentials)
        #expect(fresh.postMyInteractions.postAnnounced)
        #expect(!fresh.postMyInteractions.postDirectAnnounced)
    }

    @Test func restrictedVisibilityBlocksNewAnnounceButAllowsRemoval() async throws {
        let (key, api, credentials, _) = try setup()
        let fixture = Bundle.module.url(forResource: "posts-timeline", withExtension: "json", subdirectory: "Fixtures")!
        var json = (try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [[String: Any]])[0]
        json["postVisibility"] = "followers"
        var interactions = json["postMyInteractions"] as! [String: Any]
        interactions["postDirectAnnounced"] = false
        json["postMyInteractions"] = interactions
        let restricted = try JSONDecoder().decode(Post.self, from: JSONSerialization.data(withJSONObject: json))
        let announces = PostAnnounces(api: api)
        #expect(!announces.canToggle(post: restricted))
        await announces.toggle(post: restricted) { credentials }
        #expect(AnnounceBackend.shared.snapshot(key).writes == 0)
        interactions["postDirectAnnounced"] = true
        json["postMyInteractions"] = interactions
        let shared = try JSONDecoder().decode(Post.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(announces.canToggle(post: shared))
        AnnounceBackend.shared.update(key) { $0.announced = true; $0.failRead = true }
        await announces.toggle(post: shared) { credentials }
        #expect(AnnounceBackend.shared.snapshot(key).writes == 1)
        #expect(!announces.state(for: shared).announced)
        #expect(announces.state(for: shared).count == nil)
    }

    @Test func invalidPostIDIsRejectedBeforeSending() async throws {
        let (key, api, credentials, _) = try setup()
        await #expect(throws: (any Error).self) { try await api.setAnnounce(postID: "../invalid", announced: true, credentials: credentials) }
        #expect(AnnounceBackend.shared.snapshot(key).writes == 0)
    }
}
