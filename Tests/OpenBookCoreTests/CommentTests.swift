import Foundation
import Testing
@testable import OpenBookCore

private let commentPostID = "01900000-0000-7000-8000-000000000002"
private let commentID = "01900000-0000-7000-8000-000000000004"
private let commentOwnID = "01900000-0000-7000-8000-000000000001"
private let replyID = "01900000-0000-7000-8000-000000000005"

private func commentFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}
private func commentDocument(id: String = commentID, parent: String? = nil, content: String = "Original", author: String = commentOwnID) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: commentFixture("comment")) as! [String: Any]
    object["commentId"] = id
    object["commentParentId"] = parent.map { $0 as Any } ?? NSNull()
    object["commentContent"] = content
    var person = object["commentAuthor"] as! [String: Any]
    person["personId"] = author; object["commentAuthor"] = person
    return try JSONSerialization.data(withJSONObject: object)
}

private final class CommentBackend: @unchecked Sendable {
    static let shared = CommentBackend()
    struct Call { let method: String; let url: URL; let body: Data; let bearer: String?; let contentType: String?; let conditional: String? }
    struct State {
        var calls: [Call] = []
        var pages: [[Data]] = []
        var next: String?
        var document: Data = Data()
        var failure: Int?
        var failureOnlyComments = false
        var errorCode: String?
        var overrideStatus: Int?
        var malformed = false
        var rootCount = 7
    }
    private let lock = NSLock()
    private var sessions: [String: State] = [:]
    func update(_ key: String, _ change: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var state = sessions[key] ?? State(); change(&state); sessions[key] = state
    }
    func state(_ key: String) -> State { lock.lock(); defer { lock.unlock() }; return sessions[key]! }
    func response(_ request: URLRequest, body: Data) -> (Int, Data, [String: String]) {
        let key = request.value(forHTTPHeaderField: "X-Comment-Test")!
        var status = 200; var data = Data(); var headers: [String: String] = [:]
        update(key) { state in
            let method = request.httpMethod!
            state.calls.append(Call(method: method, url: request.url!, body: body,
                                    bearer: request.value(forHTTPHeaderField: "Authorization"),
                                    contentType: request.value(forHTTPHeaderField: "Content-Type"), conditional: request.value(forHTTPHeaderField: "If-None-Match")))
            if let failure = state.failure, !state.failureOnlyComments || request.url!.path.contains("/comments") {
                status = failure
                data = try! JSONSerialization.data(withJSONObject: ["code": state.errorCode ?? "otherReason"])
                return
            }
            let path = request.url!.path
            if path == "/rest/v1/posts", method == "POST" {
                status = 201; data = try! commentFixture("created-post")
            } else if !path.contains("/comments") {
                var object = try! JSONSerialization.jsonObject(with: commentFixture("created-post")) as! [String: Any]
                var counts = object["postCounters"] as! [String: Any]
                counts["postCommentsCount"] = state.rootCount; object["postCounters"] = counts
                data = try! JSONSerialization.data(withJSONObject: object)
            } else if method == "GET", path.hasSuffix("/comments") {
                let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }
                let index = after == nil ? 0 : 1
                let page = state.pages.indices.contains(index) ? state.pages[index] : []
                let objects = page.map { try! JSONSerialization.jsonObject(with: $0) }
                data = try! JSONSerialization.data(withJSONObject: objects)
                if let next = state.next { headers["Link"] = "<\(next)>; rel=\"next\"" }
            } else {
                data = state.document
                if method == "POST" { status = 201 }
                if method == "DELETE" { status = 204; data = Data() }
                if method == "PATCH" {
                    var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                    let patch = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                    object["commentContent"] = patch["commentContent"]
                    object["commentEditedAt"] = "2026-11-08T12:00:00Z"
                    data = try! JSONSerialization.data(withJSONObject: object)
                }
            }
            if state.malformed { data = Data("invalid".utf8) }
            status = state.overrideStatus ?? status
        }
        return (status, data, headers)
    }
}
private final class CommentProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        let (status, data, headers) = CommentBackend.shared.response(request, body: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct CommentTests {
    private func setup() throws -> (String, APIClient, Credentials) {
        let key = UUID().uuidString
        let document = try commentDocument()
        CommentBackend.shared.update(key) { $0.document = document; $0.pages = [[document]] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommentProtocol.self]; config.httpAdditionalHeaders = ["X-Comment-Test": key]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (key, APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "test-client", token: token))
    }

    @Test func officialExamplesOptionalFieldsAndExactInputBodies() throws {
        let comment = try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentFixture("comment"))
        #expect(comment.commentPostId == commentPostID && comment.commentParentId == nil)
        #expect(comment.publishedDate != nil && comment.commentAttachments == nil)
        #expect(comment.isOwned(by: commentOwnID.uppercased()))
        #expect(!comment.isOwned(by: nil) && !comment.isOwned(by: replyID))
        let content = "  Testo\n**Markdown** :wave:  "
        let top = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NewComment(content: content))) as! [String: Any]
        #expect(Set(top.keys) == ["commentContent"] && top["commentContent"] as? String == content)
        let reply = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NewComment(content: content, parentID: commentID))) as! [String: Any]
        #expect(Set(reply.keys) == ["commentContent", "commentParentId"])
        let patch = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PatchComment(content: content))) as! [String: Any]
        #expect(Set(patch.keys) == ["commentContent"])
        #expect(throws: (any Error).self) { try NewComment(content: " \n ") }
        #expect(throws: (any Error).self) { try PatchComment(content: "\n") }
        #expect(throws: (any Error).self) { try NewComment(content: "Test", parentID: "../other") }
    }

    @Test func pathsBodiesSuccessStatusesAndNoConditionalCacheHeaders() async throws {
        let (key, api, credentials) = try setup()
        let page = try await api.comments(postID: commentPostID, credentials: credentials)
        #expect(page.comments.count == 1)
        _ = try await api.comment(postID: commentPostID, id: commentID, credentials: credentials)
        _ = try await api.createComment(postID: commentPostID, draft: NewComment(content: "Reply", parentID: commentID), credentials: credentials)
        _ = try await api.editComment(postID: commentPostID, id: commentID, patch: PatchComment(content: "Edited"), credentials: credentials)
        try await api.deleteComment(postID: commentPostID, id: commentID, credentials: credentials)
        let calls = CommentBackend.shared.state(key).calls
        #expect(calls.map(\.method) == ["GET", "GET", "POST", "PATCH", "DELETE"])
        #expect(calls.allSatisfy { $0.bearer == "Bearer test-token" && $0.conditional == nil })
        #expect(calls[1].url.path == "/rest/v1/posts/\(commentPostID)/comments/\(commentID)")
        #expect(calls[4].body.isEmpty)
        #expect(calls[2].contentType == "application/json" && calls[3].contentType == "application/json")
        let query = URLComponents(url: calls[0].url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) }) == ["limit":"20", "sort":"commentPublishedAt", "direction":"asc"])
    }

    @Test func paginationPreservesLinkAndRejectsForeignOrUnsupportedCursors() async throws {
        let (key, api, credentials) = try setup()
        let safe = "https://example.org/rest/v1/posts/\(commentPostID)/comments?after=\(commentID)&sort=commentPublishedAt&direction=asc&limit=7"
        CommentBackend.shared.update(key) { $0.next = safe }
        let first = try await api.comments(postID: commentPostID, credentials: credentials)
        _ = try await api.comments(postID: commentPostID, nextPage: first.nextPage, credentials: credentials)
        #expect(CommentBackend.shared.state(key).calls.last?.url.absoluteString == safe)
        let bad = [safe.replacingOccurrences(of: "example.org", with: "evil.example"),
                   safe.replacingOccurrences(of: commentPostID, with: replyID), safe + "&afterAt=now", safe + "&page=2",
                   safe + "&cursor=abc", safe + "&after=\(replyID)", safe + "#fragment",
                   safe.replacingOccurrences(of: "direction=asc", with: "direction=desc"),
                   safe.replacingOccurrences(of: "limit=7", with: "limit=101"),
                   safe.replacingOccurrences(of: "https://", with: "https://user:secret@")]
        let count = CommentBackend.shared.state(key).calls.count
        for raw in bad {
            await #expect(throws: (any Error).self) { try await api.comments(postID: commentPostID, nextPage: URL(string: raw)!, credentials: credentials) }
        }
        #expect(CommentBackend.shared.state(key).calls.count == count)
        CommentBackend.shared.update(key) { $0.next = bad[0] }
        await #expect(throws: (any Error).self) { try await api.comments(postID: commentPostID, credentials: credentials) }
    }

    @Test func invalidIDsAndMismatchedRepresentationsNeverBecomeEditable() async throws {
        let (key, api, credentials) = try setup()
        await #expect(throws: (any Error).self) { try await api.comment(postID: "../posts", id: commentID, credentials: credentials) }
        await #expect(throws: (any Error).self) { try await api.deleteComment(postID: commentPostID, id: "../other", credentials: credentials) }
        #expect(CommentBackend.shared.state(key).calls.isEmpty)
        let wrong = try commentDocument(id: replyID)
        CommentBackend.shared.update(key) { $0.document = wrong }
        await #expect(throws: (any Error).self) { try await api.comment(postID: commentPostID, id: commentID, credentials: credentials) }
    }

    @Test func paginationDeduplicatesStopsAndRestartsAfter422() async throws {
        let (key, api, credentials) = try setup()
        let child = try commentDocument(id: replyID, parent: commentID)
        let next = "https://example.org/rest/v1/posts/\(commentPostID)/comments?after=\(commentID)&direction=asc"
        CommentBackend.shared.update(key) { $0.pages.append([$0.document, child]); $0.next = next }
        let feed = CommentFeed(postID: commentPostID, api: api)
        await feed.load(reset: true) { credentials }
        CommentBackend.shared.update(key) { $0.failure = 422 }
        await feed.load(reset: false) { credentials }
        #expect(feed.needsRestart && feed.comments.count == 1)
        let count = CommentBackend.shared.state(key).calls.count
        await feed.load(reset: false) { credentials }
        #expect(CommentBackend.shared.state(key).calls.count == count)
        CommentBackend.shared.update(key) { $0.failure = nil }
        await feed.load(reset: true) { credentials }
        await feed.load(reset: false) { credentials }
        #expect(feed.comments.count == 2 && !feed.hasNext && !feed.needsRestart)
        #expect(feed.comments.last?.commentParentId == commentID)
    }

    @Test func feedAccessFailureClearsPrivateDataAndEmptyPageStops() async throws {
        let (key, api, credentials) = try setup()
        let feed = CommentFeed(postID: commentPostID, api: api)
        await feed.load(reset: true) { credentials }
        CommentBackend.shared.update(key) { $0.failure = 403 }
        await feed.load(reset: true) { credentials }
        #expect(feed.comments.isEmpty && !feed.hasLoaded && feed.errorMessage != nil)
        CommentBackend.shared.update(key) { $0.failure = nil; $0.pages = [[]]; $0.next = "https://evil.example/page" }
        await feed.load(reset: true) { credentials }
        #expect(feed.hasLoaded && !feed.hasNext && feed.comments.isEmpty)
    }

    @Test func editOverlayResistsOldReadsAndDeletionKeepsReplies() async throws {
        let (key, api, credentials) = try setup()
        let original = try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentDocument())
        let child = try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentDocument(id: replyID, parent: commentID))
        let state = CommentManagement(api: api)
        let beforeEdit = state.revision
        _ = try await state.edit(original, content: "New", currentPersonID: commentOwnID) { credentials }
        state.ingest([original], ifRevision: beforeEdit)
        #expect(state.current(original)?.commentContent == "New")
        try await state.delete(original, currentPersonID: commentOwnID) { credentials }
        state.ingest([original, child], ifRevision: state.revision)
        #expect(state.current(original) == nil && state.current(child)?.id == replyID)
        #expect(state.unknownCounts.contains(commentPostID))
        await state.refreshCount(postID: commentPostID) { credentials }
        let root = try JSONDecoder().decode(Post.self, from: commentFixture("created-post"))
        #expect(state.count(for: root) == 7)
        #expect(!state.unknownCounts.contains(commentPostID))
        #expect(CommentBackend.shared.state(key).calls.map(\.method) == ["PATCH", "DELETE", "GET"])
    }

    @Test func deletion404AndUnexpectedSuccessAreNotSuccess() async throws {
        let (key, api, credentials) = try setup()
        let original = try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentDocument())
        let state = CommentManagement(api: api)
        for status in [404, 200] {
            CommentBackend.shared.update(key) { $0.failure = status == 404 ? status : nil; $0.overrideStatus = status == 200 ? status : nil }
            await #expect(throws: (any Error).self) { try await state.delete(original, currentPersonID: commentOwnID) { credentials } }
            #expect(state.current(original) != nil && state.deleted.isEmpty)
        }
    }

    @Test func ownershipDoesNotUsePostOwnerOrStaffAndResetClearsOverlays() async throws {
        let (key, api, credentials) = try setup()
        let other = try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentDocument(author: replyID))
        let state = CommentManagement(api: api)
        await #expect(throws: (any Error).self) { try await state.edit(other, content: "Changed", currentPersonID: commentOwnID) { credentials } }
        await #expect(throws: (any Error).self) { try await state.delete(other, currentPersonID: nil) { credentials } }
        #expect(CommentBackend.shared.state(key).calls.isEmpty)
        let own = try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentDocument())
        try await state.delete(own, currentPersonID: commentOwnID) { credentials }
        state.reset()
        #expect(state.current(own) != nil && state.unknownCounts.isEmpty && state.pending.isEmpty)
    }

    @Test func failedCountRefreshNeverRepeatsAConfirmedWrite() async throws {
        let (key, api, credentials) = try setup()
        let state = CommentManagement(api: api)
        _ = try await state.create(postID: commentPostID, draft: NewComment(content: "New")) { credentials }
        CommentBackend.shared.update(key) { $0.failure = 503 }
        await state.refreshCount(postID: commentPostID) { credentials }
        #expect(state.unknownCounts.contains(commentPostID))
        CommentBackend.shared.update(key) { $0.failure = nil }
        await state.refreshCount(postID: commentPostID) { credentials }
        #expect(CommentBackend.shared.state(key).calls.map(\.method) == ["POST", "GET", "GET"])
    }

    @Test func uncertainCreationPreservesDraftRequiresExplicitRetry() async throws {
        let (key, api, credentials) = try setup()
        let state = CommentManagement(api: api)
        let editor = CommentEditor(postID: commentPostID, mode: .create(parentID: commentID, parentName: "Alex"), currentPersonID: commentOwnID, api: api)
        editor.content = "  My reply  "
        CommentBackend.shared.update(key) { $0.failure = 503 }
        #expect(!(await editor.save(using: state) { credentials }))
        #expect(editor.uncertain && editor.hasDraft && !editor.canSave && editor.content == "  My reply  ")
        #expect(!(await editor.save(using: state) { credentials }))
        #expect(CommentBackend.shared.state(key).calls.count == 1)
        CommentBackend.shared.update(key) { $0.failure = nil; $0.malformed = true }
        editor.allowAnotherAttempt()
        #expect(await editor.save(using: state) { credentials })
        #expect(editor.content.isEmpty && !editor.hasDraft)
        #expect(CommentBackend.shared.state(key).calls.count == 2)
    }

    @Test func confirmedMalformedCreationAndUnexpectedStatusAreDistinct() async throws {
        let (key, api, credentials) = try setup()
        CommentBackend.shared.update(key) { $0.malformed = true }
        let result = try await api.createComment(postID: commentPostID, draft: NewComment(content: "Test"), credentials: credentials)
        #expect(result.comment == nil)
        CommentBackend.shared.update(key) { $0.overrideStatus = 200 }
        await #expect(throws: CommentCreationError.self) { try await api.createComment(postID: commentPostID, draft: NewComment(content: "Test"), credentials: credentials) }
    }

    @Test func emailVerificationIsActionableForBothPostAndCommentWithoutUncertainOutcome() async throws {
        let (key, api, credentials) = try setup()
        CommentBackend.shared.update(key) { $0.failure = 403; $0.errorCode = "emailVerificationRequired" }
        let composer = PostComposer(api: api); composer.content = "Post"
        #expect(await composer.submit(credentials: { credentials }) == nil)
        #expect(composer.errorMessage?.contains("Verifica il tuo indirizzo email") == true && !composer.uncertain && composer.hasDraft)
        let editor = CommentEditor(postID: commentPostID, mode: .create(parentID: nil, parentName: nil), currentPersonID: commentOwnID, api: api)
        editor.content = "Comment"
        #expect(!(await editor.save(using: CommentManagement(api: api)) { credentials }))
        #expect(editor.errorMessage?.contains("Verifica il tuo indirizzo email") == true && !editor.uncertain && editor.hasDraft)
        CommentBackend.shared.update(key) { $0.failure = nil }
        #expect(await composer.submit(credentials: { credentials }) != nil)
        #expect(await editor.save(using: CommentManagement(api: api)) { credentials })
    }

    @Test func editLoadsAuthoritativeTextAndPreservesDraftOnFailure() async throws {
        let (key, api, credentials) = try setup()
        let editor = CommentEditor(postID: commentPostID, mode: .edit(commentID: commentID), currentPersonID: commentOwnID, api: api)
        await editor.load { credentials }
        #expect(editor.content == "Original" && !editor.canSave)
        editor.content = "Edited"
        CommentBackend.shared.update(key) { $0.failure = 500 }
        #expect(!(await editor.save(using: CommentManagement(api: api)) { credentials }))
        #expect(editor.requiresReload && editor.hasDraft && !editor.canSave && editor.content == "Edited")
        CommentBackend.shared.update(key) { $0.failure = nil }
        await editor.load { credentials }
        #expect(editor.content == "Original" && !editor.requiresReload)
        editor.content = "Edited again"
        #expect(await editor.save(using: CommentManagement(api: api)) { credentials })
    }
    @Test func pendingWritesAndSessionResetCannotContaminateAnotherAccount() async throws {
        let (key, api, credentials) = try setup()
        let state = CommentManagement(api: api)
        let gate = CommentCredentialGate()
        let task = Task { try await state.create(postID: commentPostID, draft: NewComment(content: "Draft")) {
            await gate.wait()
        } }
        while gate.continuation == nil { await Task.yield() }
        await #expect(throws: (any Error).self) { try await state.create(postID: commentPostID, draft: NewComment(content: "Second")) { credentials } }
        #expect(CommentBackend.shared.state(key).calls.isEmpty)
        state.reset()
        gate.continuation?.resume(returning: credentials)
        do { _ = try await task.value; Issue.record("Old session must not publish") }
        catch { #expect(error is CancellationError) }
        #expect(state.pending.isEmpty && state.updates.isEmpty && state.unknownCounts.isEmpty)
        #expect(CommentBackend.shared.state(key).calls.isEmpty)
    }

    @Test func refreshRequestedDuringLoadingIsSerializedAndApplied() async throws {
        let (key, api, credentials) = try setup()
        let feed = CommentFeed(postID: commentPostID, api: api)
        let gate = CommentCredentialGate()
        var lookups = 0
        let first = Task { await feed.load(reset: true) {
            lookups += 1
            if lookups == 1 { return await gate.wait() }
            return credentials
        } }
        while gate.continuation == nil { await Task.yield() }
        await feed.load(reset: true) { credentials }
        #expect(CommentBackend.shared.state(key).calls.isEmpty)
        gate.continuation?.resume(returning: credentials)
        _ = await first.value
        #expect(CommentBackend.shared.state(key).calls.count == 2)
        #expect(feed.hasLoaded && !feed.isLoading && feed.comments.count == 1)
    }

    @Test func threadGroupsRepliesAndKeepsRootAndSiblingOrder() throws {
        let thirdID = "01900000-0000-7000-8000-000000000006"
        let fourthID = "01900000-0000-7000-8000-000000000007"
        let fifthID = "01900000-0000-7000-8000-000000000008"
        let data = [try commentDocument(), try commentDocument(id: replyID),
                    try commentDocument(id: thirdID, parent: commentID),
                    try commentDocument(id: fourthID, parent: thirdID),
                    try commentDocument(id: fifthID, parent: commentID)]
        let comments = try data.map { try JSONDecoder().decode(OpenBookCore.Comment.self, from: $0) }
        let rows = CommentThread.rows(in: comments)
        #expect(rows.map(\.id) == [commentID, thirdID, fourthID, fifthID, replyID])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 0])
        #expect(rows.allSatisfy { !$0.parentUnavailable })
        #expect(comments.map(\.id) == [commentID, replyID, thirdID, fourthID, fifthID])
    }

    @Test func missingParentReplyRejoinsThreadWhenParentArrives() throws {
        let child = try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentDocument(id: replyID, parent: commentID))
        let parent = try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentDocument())
        let orphan = CommentThread.rows(in: [child])
        #expect(orphan.count == 1 && orphan[0].depth == 1 && orphan[0].parentUnavailable)
        let joined = CommentThread.rows(in: [child, parent])
        #expect(joined.map(\.id) == [commentID, replyID] && joined.map(\.depth) == [0, 1])
        #expect(!joined[1].parentUnavailable)
    }

    @Test func cyclesSelfReferencesAndDuplicateIDsDoNotHideComments() throws {
        let selfID = "01900000-0000-7000-8000-000000000006"
        let data = [try commentDocument(parent: replyID), try commentDocument(id: replyID, parent: commentID),
                    try commentDocument(id: selfID, parent: selfID), try commentDocument(id: commentID.uppercased())]
        let comments = try data.map { try JSONDecoder().decode(OpenBookCore.Comment.self, from: $0) }
        let rows = CommentThread.rows(in: comments)
        #expect(rows.count == 3 && Set(rows.map(\.id)) == [commentID, replyID, selfID])
        #expect(rows.contains { $0.id == selfID && $0.parentUnavailable })
        #expect(rows.contains { $0.id == commentID && $0.parentUnavailable })
    }

    @Test func deepThreadRetainsEveryReplyWithoutRecursiveLayout() throws {
        var comments: [OpenBookCore.Comment] = []
        var parent: String?
        for n in 0..<500 {
            let id = String(format: "01900000-0000-7000-8000-%012d", n)
            comments.append(try JSONDecoder().decode(OpenBookCore.Comment.self, from: commentDocument(id: id, parent: parent)))
            parent = id
        }
        let rows = CommentThread.rows(in: comments)
        #expect(rows.count == 500 && rows.last?.depth == 499)
        #expect(Set(rows.map(\.id)).count == 500)
    }

    @Test func unavailableCommentEndpointsSoftFailAndRecoverAfterUpgrade() async throws {
        for status in [404, 405, 501] {
            let (key, api, credentials) = try setup()
            let feed = CommentFeed(postID: commentPostID, api: api)
            #expect(!feed.canWrite && feed.availability == .unknown)
            CommentBackend.shared.update(key) { $0.failure = status; $0.failureOnlyComments = true }
            await feed.load(reset: true) { credentials }
            #expect(feed.availability == .unsupported && !feed.canWrite)
            #expect(feed.unavailableMessage != nil && feed.errorMessage == nil)
            #expect(!feed.hasLoaded && !feed.hasNext && feed.comments.isEmpty)
            let calls = CommentBackend.shared.state(key).calls
            #expect(calls.count == (status == 404 ? 2 : 1))
            #expect(calls.allSatisfy { $0.method == "GET" })
            if status == 404 { #expect(calls.last?.url.path == "/rest/v1/posts/\(commentPostID)") }
            await feed.load(reset: false) { credentials }
            #expect(CommentBackend.shared.state(key).calls.count == calls.count)
            CommentBackend.shared.update(key) { $0.failure = nil }
            await feed.load(reset: true) { credentials }
            #expect(feed.availability == .available && feed.canWrite && feed.hasLoaded)
            #expect(feed.unavailableMessage == nil && feed.errorMessage == nil)
        }
    }

    @Test func inaccessiblePost404IsNotAnUnsupportedInstance() async throws {
        let (key, api, credentials) = try setup()
        let feed = CommentFeed(postID: commentPostID, api: api)
        await feed.load(reset: true) { credentials }
        CommentBackend.shared.update(key) { $0.failure = 404 }
        await feed.load(reset: true) { credentials }
        #expect(feed.availability == .unknown && !feed.canWrite)
        #expect(feed.unavailableMessage == nil && feed.errorMessage != nil)
        #expect(feed.comments.isEmpty && !feed.hasLoaded)
    }

    @Test func transientErrorsDoNotDisablePreviouslyVerifiedSupport() async throws {
        for status in [429, 500, 503] {
            let (key, api, credentials) = try setup()
            let feed = CommentFeed(postID: commentPostID, api: api)
            await feed.load(reset: true) { credentials }
            CommentBackend.shared.update(key) { $0.failure = status }
            await feed.load(reset: true) { credentials }
            #expect(feed.availability == .available && feed.canWrite)
            #expect(feed.errorMessage != nil && feed.unavailableMessage == nil && feed.comments.count == 1)
        }
    }

    @Test func accessErrorsAndInvalidRepresentationsNeverClaimMissingEndpoints() async throws {
        for status in [401, 403, 200, 503] {
            let (key, api, credentials) = try setup()
            CommentBackend.shared.update(key) {
                if status == 200 { $0.malformed = true } else { $0.failure = status }
            }
            let feed = CommentFeed(postID: commentPostID, api: api)
            await feed.load(reset: true) { credentials }
            #expect(feed.availability == .unknown && !feed.canWrite)
            #expect(feed.unavailableMessage == nil && feed.errorMessage != nil)
            #expect(CommentBackend.shared.state(key).calls.count == 1)
        }
    }

    @Test func editingPreservesExistingMediaEmojiAndReplyRelationship() async throws {
        let (key, api, credentials) = try setup()
        var object = try JSONSerialization.jsonObject(with: commentDocument(parent: replyID)) as! [String: Any]
        object["commentCustomEmojis"] = [":wave:": "https://example.org/wave.png"]
        object["commentLanguage"] = "it"
        object["commentAttachments"] = [["mediaId": replyID, "mediaUrl": "https://example.org/photo.png",
                                          "mediaPreviewUrl": "https://example.org/preview.png", "mediaMimeType": "image/png",
                                          "mediaAltText": "Una foto"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        CommentBackend.shared.update(key) { $0.document = data }
        let edited = try await api.editComment(postID: commentPostID, id: commentID, patch: PatchComment(content: "Changed"), credentials: credentials)
        #expect(edited.commentParentId == replyID && edited.commentLanguage == "it")
        #expect(edited.commentAttachments?.first?.mediaAltText == "Una foto")
        #expect(edited.commentCustomEmojis?[":wave:"]?.absoluteString == "https://example.org/wave.png")
        #expect(edited.commentPublishedAt == object["commentPublishedAt"] as? String)
        let sent = try JSONSerialization.jsonObject(with: CommentBackend.shared.state(key).calls.last!.body) as! [String: Any]
        #expect(Set(sent.keys) == ["commentContent"])
    }

}


@MainActor private final class CommentCredentialGate {
    var continuation: CheckedContinuation<Credentials, Never>?
    func wait() async -> Credentials { await withCheckedContinuation { continuation = $0 } }
}
