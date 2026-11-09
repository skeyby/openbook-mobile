import Foundation
import Testing
@testable import OpenBookCore

private let publicationID = "5146b1f5-0e95-4be9-a194-25cb5d1d8081"
private let mediaTestLimits = try! InstanceUploadLimits(maxAttachmentsPerPost: 10, maxAttachmentBytes: 10_000_000, maxVideoAttachmentBytes: 10_000_000, maxRequestBytes: 20_000_000)
private let mediaPostID = "01900000-0000-7000-8000-000000000002"
private func mediaFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}
private func attachment(_ contents: String = "file-bytes", mime: String = "image/jpeg", alt: String = "") throws -> DraftAttachment {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).jpg")
    try Data(contents.utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    return DraftAttachment(file: try DraftMediaFile(copying: source, mimeType: mime), altText: alt)
}
private final class MediaBackend: @unchecked Sendable {
    static let shared = MediaBackend()
    struct Call { let method: String; let path: String; let contentType: String?; let bearer: String? }
    struct State {
        var calls: [Call] = []
        var createStatus = 202
        var malformed = false
        var location: String? = "https://example.org/rest/v1/postPublication/\(publicationID)"
        var status = "pending"
        var postID: String?
        var getStatus = 200
        var cancelStatus = 204
    }
    private let lock = NSLock()
    private var states: [String: State] = [:]
    func update(_ key: String, _ edit: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }; var value = states[key] ?? State(); edit(&value); states[key] = value
    }
    func state(_ key: String) -> State { lock.lock(); defer { lock.unlock() }; return states[key] ?? State() }
    func response(_ request: URLRequest) -> (Int, Data, [String: String]) {
        let key = request.value(forHTTPHeaderField: "X-Media-Test")!
        var code = 200; var data = Data(); var headers: [String: String] = [:]
        update(key) { state in
            let method = request.httpMethod!
            state.calls.append(Call(method: method, path: request.url!.path,
                                    contentType: request.value(forHTTPHeaderField: "Content-Type"), bearer: request.value(forHTTPHeaderField: "Authorization")))
            if method == "POST" {
                code = state.createStatus
                if let location = state.location { headers["Location"] = location }
                if state.malformed { data = Data("bad representation".utf8) }
                else if code == 201 { data = try! mediaFixture("created-post") }
                else if code == 403 { data = try! mediaFixture("email-verification-required") }
                else if code == 202 { data = try! mediaFixture("post-publication") }
            } else if method == "DELETE" { code = state.cancelStatus }
            else {
                code = state.getStatus
                data = try! JSONSerialization.data(withJSONObject: ["postPublicationId": publicationID,
                    "postPublicationStatus": state.status, "postId": state.postID.map { $0 as Any } ?? NSNull()])
            }
        }
        return (code, data, headers)
    }
}
private final class MediaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data, headers) = MediaBackend.shared.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct PostMediaTests {
    private func setup() throws -> (String, APIClient, Credentials) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaProtocol.self]; config.httpAdditionalHeaders = ["X-Media-Test": key]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (key, APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "test-client", token: token))
    }
    private func draft(_ files: [DraftAttachment], content: String = "") throws -> NewPost {
        try NewPost(content: content, visibility: .followers, attachments: files.enumerated().map {
            try NewPostAttachment(filePart: "attachment\($0.offset + 1)", altText: $0.element.altText)
        })
    }

    @Test func multipartMapsFilesInOrderAndPostPartHasNoFilename() throws {
        let files = [try attachment("first-file", alt: "Foto 👋\nSeconda riga"), try attachment("second-file", mime: "video/mp4")]
        var body: MultipartPost? = try MultipartPost(draft: draft(files, content: "  Testo\n"), files: files)
        let url = body!.url
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.contains("name=\"post\"\r\nContent-Type: application/json\r\n\r\n"))
        #expect(!text.contains("name=\"post\"; filename="))
        #expect(text.contains("name=\"attachment1\"; filename=\"media.jpg\""))
        #expect(text.contains("Content-Type: video/mp4\r\n"))
        #expect(text.range(of: "first-file")!.lowerBound < text.range(of: "second-file")!.lowerBound)
        #expect(text.hasSuffix("--\(body!.boundary)--\r\n"))
        let jsonText = text.components(separatedBy: "\r\n\r\n")[1].components(separatedBy: "\r\n--")[0]
        let json = try JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as! [String: Any]
        #expect(json["postContent"] as? String == "  Testo\n")
        #expect(json["postVisibility"] as? String == "followers")
        let metadata = json["postAttachments"] as! [[String: Any]]
        #expect(metadata.map { $0["filePart"] as! String } == ["attachment1", "attachment2"])
        #expect(metadata[0]["mediaAltText"] as? String == "Foto 👋\nSeconda riga")
        body = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: files[0].file.url.path))
    }

    @Test func temporaryMediaOwnershipAndHeaderValidation() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID()).jpg")
        try Data("source".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var file: DraftMediaFile? = try DraftMediaFile(copying: source, mimeType: "image/jpeg")
        let copied = file!.url
        file = nil
        #expect(!FileManager.default.fileExists(atPath: copied.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        for bad in ["image/png\n", "image/png\r\nX-Test: bad", "text/plain"] {
            #expect(throws: (any Error).self) { try DraftMediaFile(copying: source, mimeType: bad) }
        }
        for part in ["post", "file\n", "file\"bad", "files[0]", "file-name"] {
            #expect(throws: (any Error).self) { try NewPostAttachment(filePart: part) }
        }
        #expect(throws: (any Error).self) { try NewPostAttachment(filePart: "file1", altText: String(repeating: "x", count: 1001)) }
        let files = [try attachment()]
        let duplicate = try NewPost(content: "Text", visibility: .public, attachments: [NewPostAttachment(filePart: "same"), NewPostAttachment(filePart: "same")])
        #expect(throws: (any Error).self) { try MultipartPost(draft: duplicate, files: files + files) }
    }

    @Test func changedFilesCannotCompensateSizesOrGrowThePreparedBody() async throws {
        let (key, api, auth) = try setup()
        let files = [try attachment("12345"), try attachment("12345")]
        let post = try draft(files)
        // Same combined size as imported: checking only the multipart total is insufficient.
        try Data("123456".utf8).write(to: files[0].file.url)
        try Data("1234".utf8).write(to: files[1].file.url)
        await #expect(throws: (any Error).self) {
            try await api.createPost(post, files: files, limits: mediaTestLimits, credentials: auth)
        }
        #expect(MediaBackend.shared.state(key).calls.isEmpty)
        // A truncated file must also fail locally, rather than becoming an uncertain upload.
        try Data("12345".utf8).write(to: files[0].file.url)
        #expect(throws: (any Error).self) { try MultipartPost(draft: post, files: files) }
    }

    @Test func textOnlyRequestsRespectKnownTotalLimitWithoutRequiringMediaSupport() async throws {
        let (key, api, auth) = try setup()
        let post = try NewPost(content: "Testo 👋", visibility: .public)
        let bytes = Int64(try JSONEncoder().encode(post).count)
        let tooSmall = try InstanceUploadLimits(maxAttachmentsPerPost: 0, maxAttachmentBytes: 0,
                                                maxVideoAttachmentBytes: nil, maxRequestBytes: bytes - 1)
        let composer = PostComposer(api: api)
        composer.content = post.postContent
        composer.setUploadLimits(tooSmall)
        #expect(composer.requestByteCount == bytes)
        #expect(!composer.canSubmit && composer.preflightError != nil)
        var credentialCalls = 0
        #expect(await composer.submit { credentialCalls += 1; return auth } == nil)
        #expect(credentialCalls == 0)
        await #expect(throws: (any Error).self) { try await api.createPost(post, limits: tooSmall, credentials: auth) }
        #expect(MediaBackend.shared.state(key).calls.isEmpty)
        MediaBackend.shared.update(key) { $0.createStatus = 201 }
        let exact = try InstanceUploadLimits(maxAttachmentsPerPost: 0, maxAttachmentBytes: 0,
                                             maxVideoAttachmentBytes: nil, maxRequestBytes: bytes)
        composer.setUploadLimits(exact)
        #expect(composer.canSubmit)
        #expect(await composer.submit { auth } != nil)
        #expect(MediaBackend.shared.state(key).calls.count == 1)
    }

    @Test func emptyTextIsOnlyValidWithMediaAndWhitespaceRemainsInvalid() throws {
        let files = [try attachment()]
        #expect(try draft(files).postContent.isEmpty)
        #expect(throws: (any Error).self) { try draft(files, content: " \n ") }
        #expect(throws: (any Error).self) { try NewPost(content: "", visibility: .public) }
        let composer = PostComposer()
        composer.setUploadLimits(mediaTestLimits)
        composer.add(files[0])
        #expect(composer.hasDraft && composer.canSubmit)
        composer.content = " \n"; #expect(!composer.canSubmit)
        composer.content = ""; composer.isImporting = true; #expect(!composer.canSubmit)
        composer.isImporting = false
        composer.removeAttachment(id: files[0].id)
        #expect(!composer.hasDraft && !composer.canSubmit)
    }

    @Test func composerReordersFilesAndSendsAltText() throws {
        let a = try attachment("a"); let b = try attachment("b")
        let composer = PostComposer(); composer.setUploadLimits(mediaTestLimits); composer.add(a); composer.add(b)
        composer.moveAttachment(id: b.id, offset: -1)
        composer.setAltText(id: b.id, text: "Descrizione")
        #expect(composer.attachments.map(\.id) == [b.id, a.id])
        #expect(composer.attachments[0].altText == "Descrizione")
        composer.setAltText(id: b.id, text: String(repeating: "x", count: 1001))
        #expect(!composer.canSubmit)
        composer.reset()
        #expect(composer.attachments.isEmpty && !composer.hasDraft)
    }

    @Test func uploadUsesMultipartAnd202RemainsAcceptedWithoutPublication() async throws {
        let (key, api, credentials) = try setup()
        let files = [try attachment(mime: "video/mp4")]
        let result = try await api.createPost(draft(files), files: files, limits: mediaTestLimits, credentials: credentials)
        #expect(result.wasDeferred && result.post == nil && result.monitorID == publicationID)
        #expect(result.deferredPublication?.status == .pending)
        let call = MediaBackend.shared.state(key).calls.first!
        #expect(call.method == "POST" && call.path == "/rest/v1/posts" && call.bearer == "Bearer test-token")
        #expect(call.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        let state = PostPublications(api: api); state.register(result)
        #expect(state.jobs.count == 1 && state.pollingIDs == [publicationID])
        MediaBackend.shared.update(key) { $0.status = "processing" }
        #expect(!(await state.refresh(id: publicationID) { credentials }))
        #expect(!state.canCancel(state.jobs[0]))
        MediaBackend.shared.update(key) { $0.status = "published"; $0.postID = mediaPostID }
        #expect(await state.refresh(id: publicationID) { credentials })
        #expect(state.jobs[0].value?.postId == mediaPostID && state.pollingIDs.isEmpty)
        #expect(!(await state.refresh(id: publicationID) { credentials }))
        #expect(MediaBackend.shared.state(key).calls.filter { $0.method == "POST" }.count == 1)
    }

    @Test func acceptedResponseWithoutReadableBodyIsNeverResubmitted() async throws {
        let (key, api, credentials) = try setup()
        MediaBackend.shared.update(key) { $0.malformed = true }
        let composer = PostComposer(api: api); composer.setUploadLimits(mediaTestLimits); composer.add(try attachment(mime: "video/mp4"))
        let result = await composer.submit { credentials }
        #expect(result?.wasDeferred == true && result?.monitorID == publicationID)
        #expect(!composer.canSubmit && !composer.uncertain)
        #expect(await composer.submit { credentials } == nil)
        #expect(MediaBackend.shared.state(key).calls.count == 1)
        let monitor = PostPublications(api: api); monitor.register(result!)
        #expect(monitor.jobs.first?.value == nil)
        #expect(await monitor.refresh(id: publicationID) { credentials } == false)
        #expect(monitor.jobs.first?.value?.status == .pending)
    }

    @Test func unsafeOrMismatchedLocationsNeverBecomeCredentialDestinations() async throws {
        let (key, api, credentials) = try setup()
        let unsafe = ["https://evil.example/rest/v1/postPublication/\(publicationID)",
                      "https://example.org/rest/v1/posts/\(publicationID)",
                      "https://user:secret@example.org/rest/v1/postPublication/\(publicationID)",
                      "https://example.org/rest/v1/postPublication/\(publicationID)?extra=yes",
                      "https://example.org/rest/v1/postPublication/\(mediaPostID)"]
        for location in unsafe {
            MediaBackend.shared.update(key) { $0.location = location }
            let result = try await api.createPost(NewPost(content: "Test", visibility: .public), credentials: credentials)
            #expect(result.wasDeferred && result.monitorID == nil)
            let state = PostPublications(api: api); state.register(result)
            #expect(state.jobs.isEmpty)
        }
        #expect(MediaBackend.shared.state(key).calls.allSatisfy { $0.path == "/rest/v1/posts" })
        await #expect(throws: (any Error).self) { try await api.postPublication(id: "../posts", credentials: credentials) }
    }

    @Test func mediaErrorsAndLegacyServersPreserveFilesAndDraft() async throws {
        for status in [403, 413, 415, 422, 500] {
            let (key, api, credentials) = try setup()
            MediaBackend.shared.update(key) { $0.createStatus = status }
            let composer = PostComposer(api: api); composer.setUploadLimits(mediaTestLimits); composer.content = "Draft"; composer.add(try attachment())
            #expect(await composer.submit { credentials } == nil)
            #expect(composer.content == "Draft" && composer.attachments.count == 1)
            #expect(FileManager.default.fileExists(atPath: composer.attachments[0].file.url.path))
            #expect(composer.uncertain == (status == 500))
            if status == 403 { #expect(composer.errorMessage?.contains("Verifica il tuo indirizzo email") == true) }
            #expect(MediaBackend.shared.state(key).calls.count == 1)
        }
    }

    @Test func immediate201AndUnreadable201RemainPublishedForMedia() async throws {
        let (key, api, credentials) = try setup()
        MediaBackend.shared.update(key) { $0.createStatus = 201 }
        let files = [try attachment()]
        let result = try await api.createPost(draft(files), files: files, limits: mediaTestLimits, credentials: credentials)
        #expect(result.post?.id == mediaPostID && !result.wasDeferred)
        MediaBackend.shared.update(key) { $0.malformed = true }
        let second = try await api.createPost(draft(files), files: files, limits: mediaTestLimits, credentials: credentials)
        #expect(second.post == nil && !second.wasDeferred)
    }

    @Test func monitorReadErrorsStopPollingAndCancellation409RequiresReconciliation() async throws {
        let (key, api, credentials) = try setup()
        let result = try await api.createPost(NewPost(content: "Test", visibility: .public), credentials: credentials)
        let monitor = PostPublications(api: api); monitor.register(result)
        MediaBackend.shared.update(key) { $0.getStatus = 429 }
        await monitor.refresh(id: publicationID) { credentials }
        #expect(monitor.pollingIDs.isEmpty && monitor.errors[publicationID] != nil)
        #expect(!monitor.canCancel(monitor.jobs[0]))
        MediaBackend.shared.update(key) { $0.getStatus = 200; $0.cancelStatus = 409 }
        await monitor.refresh(id: publicationID) { credentials }
        #expect(monitor.canCancel(monitor.jobs[0]))
        await monitor.cancel(id: publicationID) { credentials }
        #expect(monitor.jobs.count == 1 && monitor.requiresReload.contains(publicationID))
        let count = MediaBackend.shared.state(key).calls.count
        await monitor.cancel(id: publicationID) { credentials }
        #expect(MediaBackend.shared.state(key).calls.count == count)
        MediaBackend.shared.update(key) { $0.status = "processing" }
        await monitor.refresh(id: publicationID) { credentials }
        #expect(!monitor.canCancel(monitor.jobs[0]))
        MediaBackend.shared.update(key) { $0.status = "failed"; $0.cancelStatus = 204 }
        await monitor.refresh(id: publicationID) { credentials }
        await monitor.cancel(id: publicationID) { credentials }
        #expect(monitor.jobs.isEmpty)
        #expect(MediaBackend.shared.state(key).calls.allSatisfy { $0.method != "DELETE" || $0.path == "/rest/v1/postPublication/\(publicationID)" })
    }

    @Test func instancePolicyIsOptionalForBrandingButNeverUnlimitedWhenMissingOrInvalid() throws {
        var instance = try JSONSerialization.jsonObject(with: mediaFixture("instance-configured")) as! [String: Any]
        instance.removeValue(forKey: "instanceUploadLimits")
        let legacy = try JSONDecoder().decode(InstanceMetadata.self, from: JSONSerialization.data(withJSONObject: instance))
        #expect(legacy.displayName == "Example Social" && legacy.instanceUploadLimits == nil)
        let policy: [String: Any] = ["maxAttachmentsPerPost": 4, "maxAttachmentBytes": 1024,
                                    "maxVideoAttachmentBytes": NSNull(), "maxRequestBytes": NSNull()]
        instance["instanceUploadLimits"] = policy
        let valid = try JSONDecoder().decode(InstanceMetadata.self, from: JSONSerialization.data(withJSONObject: instance))
        #expect(valid.instanceUploadLimits?.maxAttachmentsPerPost == 4)
        #expect(valid.instanceUploadLimits?.allowsImages == true && valid.instanceUploadLimits?.allowsVideo == false)
        #expect(valid.instanceUploadLimits?.maxRequestBytes == nil)
        for key in policy.keys {
            var invalid = policy; invalid.removeValue(forKey: key); instance["instanceUploadLimits"] = invalid
            #expect(try JSONDecoder().decode(InstanceMetadata.self, from: JSONSerialization.data(withJSONObject: instance)).instanceUploadLimits == nil)
            invalid = policy; invalid[key] = -1; instance["instanceUploadLimits"] = invalid
            #expect(try JSONDecoder().decode(InstanceMetadata.self, from: JSONSerialization.data(withJSONObject: instance)).instanceUploadLimits == nil)
        }
    }

    @Test func exactMultipartSizeIncludesUnicodeMetadataAndFramingAndAllowsBoundaryEquality() async throws {
        let (key, api, credentials) = try setup()
        let files = [try attachment("photo", alt: "👋 descrizione \"con apici\"\n"), try attachment("video", mime: "video/mp4")]
        let value = try draft(files, content: "Ciao 👋\nTesto")
        let bytes = try MultipartPost.bodyByteCount(draft: value, files: files)
        let multipart = try MultipartPost(draft: value, files: files)
        #expect(bytes == Int64(try Data(contentsOf: multipart.url).count))
        #expect(bytes > files.reduce(0) { $0 + Int64($1.file.byteCount) })
        let exact = try InstanceUploadLimits(maxAttachmentsPerPost: 2, maxAttachmentBytes: 5, maxVideoAttachmentBytes: 5, maxRequestBytes: bytes)
        #expect(try await api.createPost(value, files: files, limits: exact, credentials: credentials).wasDeferred)
        let smaller = try InstanceUploadLimits(maxAttachmentsPerPost: 2, maxAttachmentBytes: 5, maxVideoAttachmentBytes: 5, maxRequestBytes: bytes - 1)
        await #expect(throws: (any Error).self) { try await api.createPost(value, files: files, limits: smaller, credentials: credentials) }
        #expect(MediaBackend.shared.state(key).calls.count == 1)
    }

    @Test func countAndIndividualFileChecksRejectBeforeAddingOrRequestingCredentials() async throws {
        let (key, api, _) = try setup()
        let composer = PostComposer(api: api)
        composer.setUploadLimits(try InstanceUploadLimits(maxAttachmentsPerPost: 1, maxAttachmentBytes: 5, maxVideoAttachmentBytes: nil, maxRequestBytes: nil))
        #expect(!composer.add(try attachment("123456")))
        #expect(composer.attachments.isEmpty && composer.errorMessage?.contains("supera il limite") == true)
        #expect(composer.add(try attachment("12345")))
        #expect(!composer.add(try attachment("1")))
        #expect(composer.attachments.count == 1 && composer.errorMessage?.contains("massimo 1") == true)
        composer.setUploadLimits(nil)
        #expect(composer.hasDraft && !composer.canSubmit)
        _ = await composer.submit { Issue.record("Limits rejected before credentials"); throw CancellationError() }
        #expect(MediaBackend.shared.state(key).calls.isEmpty)
    }

    @Test func disabledVideoZeroPolicyAndMissingPolicyDoNotAffectTextOnlyPosts() async throws {
        let (key, api, credentials) = try setup()
        let composer = PostComposer(api: api)
        #expect(!composer.add(try attachment()))
        #expect(!composer.hasDraft)
        composer.content = "Testo senza allegati"
        MediaBackend.shared.update(key) { $0.createStatus = 201 }
        #expect(await composer.submit { credentials } != nil)
        composer.reset()
        for limit in [Int64?.none, Int64?(0)] {
            composer.setUploadLimits(try InstanceUploadLimits(maxAttachmentsPerPost: 2, maxAttachmentBytes: 100, maxVideoAttachmentBytes: limit, maxRequestBytes: nil))
            #expect(composer.uploadLimits?.allowsVideo == false)
            #expect(!composer.add(try attachment("v", mime: "video/mp4")))
        }
        composer.setUploadLimits(try InstanceUploadLimits(maxAttachmentsPerPost: 0, maxAttachmentBytes: 100, maxVideoAttachmentBytes: 100, maxRequestBytes: nil))
        #expect(!composer.add(try attachment("a")))
        #expect(composer.attachments.isEmpty && MediaBackend.shared.state(key).calls.count == 1)
    }

    @Test func textAndAltTextCanExceedWholeRequestLimitWithoutExceedingFileBudget() async throws {
        let file = try attachment("x")
        let initial = try draft([file])
        let size = try MultipartPost.bodyByteCount(draft: initial, files: [file])
        let limits = try InstanceUploadLimits(maxAttachmentsPerPost: 4, maxAttachmentBytes: 100, maxVideoAttachmentBytes: 100, maxRequestBytes: size + 5)
        let composer = PostComposer(); composer.setUploadLimits(limits)
        #expect(composer.add(file) && composer.canSubmit)
        composer.content = String(repeating: "👋", count: 10)
        #expect(!composer.canSubmit && composer.preflightError?.contains("testo e struttura") == true)
        composer.content = ""
        composer.setAltText(id: file.id, text: String(repeating: "x", count: 50))
        #expect(!composer.canSubmit && composer.requestByteCount! > size + 5)
        composer.setAltText(id: file.id, text: "")
        #expect(composer.canSubmit)
        let impossible = try InstanceUploadLimits(maxAttachmentsPerPost: 4, maxAttachmentBytes: 100, maxVideoAttachmentBytes: nil, maxRequestBytes: 2)
        let other = PostComposer(); other.setUploadLimits(impossible)
        #expect(!other.add(file) && other.attachments.isEmpty)
    }

    @Test func freshPolicyShrinkOrRemovalPreventsUploadAndPreservesDraft() async throws {
        for updated in [try InstanceUploadLimits(maxAttachmentsPerPost: 0, maxAttachmentBytes: 100, maxVideoAttachmentBytes: nil, maxRequestBytes: nil), nil] {
            let (key, api, _) = try setup()
            let composer = PostComposer(api: api); composer.setUploadLimits(mediaTestLimits)
            composer.add(try attachment())
            composer.content = "Bozza da conservare"
            var refreshed = false
            _ = await composer.submit(refreshLimits: { refreshed = true; return updated }, credentials: {
                Issue.record("Must not upload after policy changed"); throw CancellationError()
            })
            #expect(refreshed && composer.content == "Bozza da conservare" && composer.attachments.count == 1)
            #expect(!composer.uncertain && composer.errorMessage != nil && !composer.canSubmit)
            #expect(MediaBackend.shared.state(key).calls.isEmpty)
        }
    }

    @Test func missingPolicyAndChangedTemporaryFileCannotBypassTransportPreflight() async throws {
        let (key, api, credentials) = try setup()
        let files = [try attachment("small")]
        let value = try draft(files)
        await #expect(throws: (any Error).self) { try await api.createPost(value, files: files, credentials: credentials) }
        try Data("file changed after import".utf8).write(to: files[0].file.url)
        await #expect(throws: (any Error).self) { try await api.createPost(value, files: files, limits: mediaTestLimits, credentials: credentials) }
        #expect(MediaBackend.shared.state(key).calls.isEmpty)
    }

    @Test func failureToRefreshLimitsNeverUploadsOrMarksOutcomeUncertain() async throws {
        let (key, api, _) = try setup()
        let composer = PostComposer(api: api); composer.setUploadLimits(mediaTestLimits); composer.add(try attachment())
        _ = await composer.submit(refreshLimits: { throw OpenBookError.http(503, "Unavailable") }, credentials: {
            Issue.record("No upload credentials after failed preflight"); throw CancellationError()
        })
        #expect(composer.hasDraft && !composer.uncertain && composer.errorMessage != nil)
        #expect(MediaBackend.shared.state(key).calls.isEmpty)
    }

    @Test func unknownStatusAnd404AreNotSuccessAndSessionResetDropsOldReads() async throws {
        let (key, api, credentials) = try setup()
        let result = try await api.createPost(NewPost(content: "Test", visibility: .public), credentials: credentials)
        let monitor = PostPublications(api: api); monitor.register(result)
        MediaBackend.shared.update(key) { $0.status = "futureState" }
        await monitor.refresh(id: publicationID) { credentials }
        #expect(monitor.pollingIDs.isEmpty && !monitor.canCancel(monitor.jobs[0]))
        MediaBackend.shared.update(key) { $0.getStatus = 404 }
        #expect(!(await monitor.refresh(id: publicationID) { credentials }))
        #expect(monitor.jobs.count == 1 && monitor.errors[publicationID] != nil)
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await monitor.refresh(id: publicationID) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        let count = MediaBackend.shared.state(key).calls.count
        monitor.reset(); release?.resume(returning: credentials)
        _ = await task.value
        #expect(monitor.jobs.isEmpty && monitor.pending.isEmpty)
        #expect(MediaBackend.shared.state(key).calls.count == count)
    }
}
