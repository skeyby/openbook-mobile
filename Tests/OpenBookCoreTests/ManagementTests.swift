import Foundation
import Testing
@testable import OpenBookCore

private final class ManagementBackend: @unchecked Sendable {
    static let shared = ManagementBackend()
    struct State {
        var reads = 0
        var patches = 0
        var deletes = 0
        var valid = true
        var lastPatch: [String: String] = [:]
        var patchStatus = 200
        var deleteStatus = 204
        var readStatus = 200
        var unsupported = false
    }
    private let lock = NSLock()
    private var states: [String: State] = [:]
    func update(_ key: String, _ body: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var state = states[key] ?? State(); body(&state); states[key] = state
    }
    func state(_ key: String) -> State {
        lock.lock(); defer { lock.unlock() }; return states[key] ?? State()
    }
    func respond(_ request: URLRequest) -> (Int, Data) {
        let key = request.value(forHTTPHeaderField: "X-Test-Session")!
        var status = 200
        var data = Data()
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count))
            }
        }
        update(key) { state in
            state.valid = state.valid && request.url?.path == "/rest/v1/posts/01900000-0000-7000-8000-000000000002" && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
            if request.httpMethod == "DELETE" {
                state.deletes += 1; status = state.deleteStatus
                state.valid = state.valid && body.isEmpty
            } else {
                let fixture = Bundle.module.url(forResource: "posts-timeline", withExtension: "json", subdirectory: "Fixtures")!
                var post = (try! JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [[String: Any]])[0]
                post["postTimelineAt"] = nil; post["postAnnounce"] = nil
                post["postName"] = "Titolo originale"; post["postCW"] = true; post["postLanguage"] = "it"
                if state.unsupported {
                    post["postAttachments"] = [["mediaId": "01900000-0000-7000-8000-000000000008", "mediaUrl": "https://example.org/photo.jpg", "mediaPreviewUrl": "https://example.org/photo.jpg", "mediaMimeType": "image/jpeg", "mediaWidth": NSNull(), "mediaHeight": NSNull(), "mediaAltText": NSNull()]]
                }
                if request.httpMethod == "PATCH" {
                    state.patches += 1; status = state.patchStatus
                    let patch = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
                    state.lastPatch = patch ?? [:]
                    state.valid = state.valid && request.value(forHTTPHeaderField: "Content-Type") == "application/json" && patch?.isEmpty == false
                    for (key, value) in patch ?? [:] { post[key] = value }
                    post["postEditedAt"] = "2026-10-27T10:00:00Z"
                } else { state.reads += 1; status = state.readStatus }
                data = try! JSONSerialization.data(withJSONObject: post)
            }
            if status >= 400 { data = Data(#"{"detail":"Operazione non consentita."}"#.utf8) }
        }
        return (status, data)
    }
}

private final class ManagementProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = ManagementBackend.shared.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct ManagementTests {
    private func setup() throws -> (String, APIClient, Credentials, Post) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManagementProtocol.self]; config.httpAdditionalHeaders = ["X-Test-Session": key]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        let fixture = Bundle.module.url(forResource: "posts-timeline", withExtension: "json", subdirectory: "Fixtures")!
        let post = try JSONDecoder().decode([Post].self, from: Data(contentsOf: fixture))[0]
        return (key, APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token), post)
    }

    @Test func patchRequiresChangesAndOmitsAbsentFields() throws {
        #expect(throws: (any Error).self) { try PatchPost() }
        #expect(throws: (any Error).self) { try PatchPost(content: " \n\t") }
        let data = try JSONEncoder().encode(PatchPost(visibility: .followers))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: String]
        #expect(object == ["postVisibility": "followers"])
    }

    @Test func editingReadsLatestAndSendsOnlyChangedTextPreservingFeedContext() async throws {
        let (key, api, credentials, post) = try setup()
        let editor = PostEditor(postID: post.id, currentPersonID: post.postAuthor.id, api: api)
        let management = PostManagement(api: api)
        await editor.load { credentials }
        #expect(editor.original?.postName == "Titolo originale")
        #expect(!editor.canSave)
        editor.content = "**Testo modificato**\nSeconda riga"
        let oldRead = management.revision
        #expect(await editor.save(using: management) { credentials })
        #expect(ManagementBackend.shared.state(key).lastPatch == ["postContent": editor.content])
        #expect(ManagementBackend.shared.state(key).valid)
        #expect(!editor.canSave)
        #expect(await editor.save(using: management) { credentials } == false)
        #expect(ManagementBackend.shared.state(key).patches == 1)
        management.ingest([post], ifRevision: oldRead)
        let displayed = try #require(management.current(post))
        #expect(displayed.postContent == editor.content)
        #expect(displayed.postName == "Titolo originale")
        #expect(displayed.postCW)
        #expect(displayed.postLanguage == "it")
        #expect(displayed.postTimelineAt == post.postTimelineAt)
        #expect(displayed.postAnnounce?.announceAuthor.id == post.postAnnounce?.announceAuthor.id)
    }

    @Test func visibilityOnlyPatchDoesNotSendText() async throws {
        let (key, api, credentials, post) = try setup()
        let editor = PostEditor(postID: post.id, currentPersonID: post.postAuthor.id, api: api)
        await editor.load { credentials }
        editor.visibility = .followers
        #expect(await editor.save(using: PostManagement(api: api)) { credentials })
        #expect(ManagementBackend.shared.state(key).lastPatch == ["postVisibility": "followers"])
    }

    @Test func cannotManageOtherAuthorsEvenWithAvailablePostData() async throws {
        let (key, api, credentials, post) = try setup()
        let management = PostManagement(api: api)
        let wrongID = "01900000-0000-7000-8000-000000000099"
        #expect(!post.isOwned(by: nil))
        #expect(!post.isOwned(by: wrongID))
        #expect(await management.edit(post: post, patch: try PatchPost(content: "Altro"), currentPersonID: wrongID) { credentials } == nil)
        #expect(await management.delete(post: post, currentPersonID: wrongID) { credentials } == false)
        let editor = PostEditor(postID: post.id, currentPersonID: wrongID, api: api)
        await editor.load { credentials }
        #expect(editor.original == nil)
        #expect(!editor.canSave)
        #expect(ManagementBackend.shared.state(key).patches == 0)
        #expect(ManagementBackend.shared.state(key).deletes == 0)
    }

    @Test(arguments: [409, 422, 403]) func rejectedEditPreservesDraftAndDisplayedPost(status: Int) async throws {
        let (key, api, credentials, post) = try setup()
        ManagementBackend.shared.update(key) { $0.patchStatus = status }
        let editor = PostEditor(postID: post.id, currentPersonID: post.postAuthor.id, api: api)
        let management = PostManagement(api: api)
        await editor.load { credentials }; editor.content = "Bozza da conservare"
        #expect(await editor.save(using: management) { credentials } == false)
        #expect(editor.content == "Bozza da conservare")
        #expect(editor.errorMessage != nil)
        #expect(management.current(post)?.postContent == post.postContent)
        #expect(management.updates.isEmpty)
        #expect(management.pending.isEmpty)
    }

    @Test func delete204RemovesPostAndOldFeedPagesCannotRestoreIt() async throws {
        let (key, api, credentials, post) = try setup()
        let management = PostManagement(api: api)
        let oldRead = management.revision
        #expect(await management.delete(post: post, currentPersonID: post.postAuthor.id) { credentials })
        management.ingest([post], ifRevision: oldRead)
        management.ingest([post], ifRevision: management.revision)
        #expect(management.current(post) == nil)
        #expect(ManagementBackend.shared.state(key).valid)
        #expect(ManagementBackend.shared.state(key).deletes == 1)
    }

    @Test func delete404DoesNotPretendDeletionSucceeded() async throws {
        let (key, api, credentials, post) = try setup()
        ManagementBackend.shared.update(key) { $0.deleteStatus = 404 }
        let management = PostManagement(api: api)
        #expect(await management.delete(post: post, currentPersonID: post.postAuthor.id) { credentials } == false)
        #expect(management.current(post) != nil)
        #expect(management.errors[post.id] != nil)
    }

    @Test func unsupportedEditCanStillBeDeletedAndFailedReloadDisablesSave() async throws {
        let (key, api, credentials, post) = try setup()
        let editor = PostEditor(postID: post.id, currentPersonID: post.postAuthor.id, api: api)
        await editor.load { credentials }
        editor.content = "Bozza"
        ManagementBackend.shared.update(key) { $0.readStatus = 403 }
        await editor.load { credentials }
        #expect(!editor.canSave)
        ManagementBackend.shared.update(key) { $0.readStatus = 200; $0.unsupported = true }
        let unsupported = try await api.post(id: post.id, credentials: credentials)
        #expect(!unsupported.supportsBasicEditing)
        await editor.load { credentials }
        #expect(editor.original == nil)
        #expect(await PostManagement(api: api).delete(post: unsupported, currentPersonID: post.postAuthor.id) { credentials })
    }

    @Test func duplicateDeleteAndSessionResetDoNotSendExtraRequests() async throws {
        let (key, api, credentials, post) = try setup()
        let management = PostManagement(api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await management.delete(post: post, currentPersonID: post.postAuthor.id) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        #expect(await management.delete(post: post, currentPersonID: post.postAuthor.id) { credentials } == false)
        management.reset()
        release?.resume(returning: credentials)
        #expect(await task.value == false)
        #expect(ManagementBackend.shared.state(key).deletes == 0)
        #expect(management.deleted.isEmpty)
        #expect(management.pending.isEmpty)
    }

    @Test func postDetailLoadsOriginalResourceWithoutFeedContext() async throws {
        let (key, api, credentials, post) = try setup()
        let detail = PostDetail(postID: post.id, api: api)
        let loaded = await detail.load { credentials }
        #expect(loaded?.id == post.id)
        #expect(detail.post?.postName == "Titolo originale")
        #expect(detail.post?.postAnnounce == nil)
        #expect(detail.post?.postTimelineAt == nil)
        #expect(detail.errorMessage == nil)
        #expect(!detail.isLoading)
        #expect(ManagementBackend.shared.state(key).reads == 1)
        #expect(ManagementBackend.shared.state(key).valid)
    }

    @Test(arguments: [401, 403, 404]) func inaccessiblePostDetailClearsPreviouslyDisplayedContent(status: Int) async throws {
        let (key, api, credentials, post) = try setup()
        let detail = PostDetail(postID: post.id, api: api)
        await detail.load { credentials }
        #expect(detail.post != nil)
        ManagementBackend.shared.update(key) { $0.readStatus = status }
        await detail.load { credentials }
        #expect(detail.post == nil)
        #expect(detail.errorMessage != nil)
        #expect(!detail.isLoading)
    }

    @Test func detailIgnoresDuplicateLoadAndCanBeCancelledBeforeRequest() async throws {
        let (key, api, credentials, post) = try setup()
        let detail = PostDetail(postID: post.id, api: api)
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await detail.load { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        let duplicate = await detail.load { Issue.record("Duplicate detail requested credentials"); return credentials }
        #expect(duplicate == nil)
        task.cancel()
        release?.resume(returning: credentials)
        #expect(await task.value == nil)
        #expect(detail.post == nil)
        #expect(detail.errorMessage == nil)
        #expect(!detail.isLoading)
        #expect(ManagementBackend.shared.state(key).reads == 0)
    }

    @Test func invalidDetailIdentifierDoesNotSendRequest() async throws {
        let (key, api, credentials, _) = try setup()
        let detail = PostDetail(postID: "../invalid", api: api)
        await detail.load { credentials }
        #expect(detail.post == nil)
        #expect(detail.errorMessage != nil)
        #expect(ManagementBackend.shared.state(key).reads == 0)
    }

}
