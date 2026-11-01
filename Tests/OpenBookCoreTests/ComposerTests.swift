import Foundation
import Testing
@testable import OpenBookCore

private final class CreationBackend: @unchecked Sendable {
    static let shared = CreationBackend()
    struct State {
        var requests = 0
        var valid = true
        var content: String?
        var visibility: String?
    }
    private let lock = NSLock()
    private var states: [String: State] = [:]

    func state(_ key: String) -> State {
        lock.lock(); defer { lock.unlock() }
        return states[key] ?? State()
    }
    func record(_ request: URLRequest) {
        let key = request.value(forHTTPHeaderField: "X-Test-Session")!
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        lock.lock(); defer { lock.unlock() }
        var value = states[key] ?? State()
        value.requests += 1
        value.valid = value.valid && request.url?.path == "/rest/v1/posts" && request.httpMethod == "POST"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
            && Set(body?.keys.map { $0 } ?? []) == Set(["postContent", "postVisibility"])
        value.content = body?["postContent"]
        value.visibility = body?["postVisibility"]
        states[key] = value
    }
}

private final class CreationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        CreationBackend.shared.record(request)
        let mode = request.value(forHTTPHeaderField: "X-Test-Mode") ?? "ok"
        if mode == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let status: Int
        let data: Data
        switch mode {
        case "validation": status = 422; data = Data(#"{"title":"Unprocessable Content","errors":{"postContent":["Il testo supera il limite dell’istanza."]}}"#.utf8)
        case "server": status = 500; data = Data(#"{"title":"Internal Server Error"}"#.utf8)
        case "bad201": status = 201; data = Data("not JSON".utf8)
        default:
            status = 201
            let fixture = Bundle.module.url(forResource: "created-post", withExtension: "json", subdirectory: "Fixtures")!
            data = try! Data(contentsOf: fixture)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct ComposerTests {
    private func setup(mode: String = "ok") throws -> (String, APIClient, Credentials) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CreationProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Session": key, "X-Test-Mode": mode]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (key, APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token))
    }

    @Test func rejectsEmptyDraftsWithoutRequestingCredentials() async throws {
        let (key, api, _) = try setup()
        let composer = PostComposer(api: api)
        for text in ["", " \n\t "] {
            composer.content = text
            #expect(!composer.canSubmit)
            #expect(throws: (any Error).self) { try NewPost(content: text, visibility: .public) }
            let result = await composer.submit { Issue.record("Empty post requested credentials"); throw OpenBookError.message("unexpected") }
            #expect(result == nil)
        }
        #expect(CreationBackend.shared.state(key).requests == 0)
    }

    @Test(arguments: PostVisibility.allCases) func sendsOnlyTextAndExplicitAudience(visibility: PostVisibility) async throws {
        let (key, api, credentials) = try setup()
        let text = "  **Ciao** 👋\n\n#OpenBook @alex@example.org  "
        let result = try await api.createPost(NewPost(content: text, visibility: visibility), credentials: credentials)
        #expect(result.post?.id == "01900000-0000-7000-8000-000000000002")
        let recorded = CreationBackend.shared.state(key)
        #expect(recorded.valid)
        #expect(recorded.content == text)
        #expect(recorded.visibility == visibility.rawValue)
        #expect(recorded.requests == 1)
    }

    @Test func preventsConcurrentAndRepeatedSubmissionAfterSuccess() async throws {
        let (key, api, credentials) = try setup()
        let composer = PostComposer(api: api)
        composer.content = "La mia bozza"
        var release: CheckedContinuation<Credentials, Never>?
        let first = Task { await composer.submit { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        #expect(composer.isSubmitting)
        #expect(await composer.submit { Issue.record("Duplicate requested credentials"); return credentials } == nil)
        release?.resume(returning: credentials)
        #expect(await first.value != nil)
        #expect(!composer.canSubmit)
        #expect(await composer.submit { credentials } == nil)
        #expect(CreationBackend.shared.state(key).requests == 1)
        composer.reset()
        #expect(!composer.hasDraft)
        #expect(composer.publication == nil)
    }

    @Test func validationErrorsPreserveDraftAndExplainInstanceLimit() async throws {
        let (key, api, credentials) = try setup(mode: "validation")
        let composer = PostComposer(api: api)
        composer.content = "Testo da correggere"
        composer.visibility = .followers
        #expect(await composer.submit { credentials } == nil)
        #expect(composer.content == "Testo da correggere")
        #expect(composer.visibility == .followers)
        #expect(composer.errorMessage?.contains("limite dell’istanza") == true)
        #expect(composer.canSubmit)
        #expect(!composer.uncertain)
        #expect(CreationBackend.shared.state(key).requests == 1)
    }

    @Test(arguments: ["server", "timeout"]) func uncertainOutcomeRequiresExplicitRetry(mode: String) async throws {
        let (key, api, credentials) = try setup(mode: mode)
        let composer = PostComposer(api: api)
        composer.content = "Da conservare"
        #expect(await composer.submit { credentials } == nil)
        #expect(composer.content == "Da conservare")
        #expect(composer.uncertain)
        #expect(!composer.canSubmit)
        #expect(await composer.submit { credentials } == nil)
        #expect(CreationBackend.shared.state(key).requests == 1)
        composer.allowAnotherAttempt()
        #expect(composer.canSubmit)
    }

    @Test func publication201WithInvalidRepresentationMustNotBeResent() async throws {
        let (key, api, credentials) = try setup(mode: "bad201")
        let composer = PostComposer(api: api)
        composer.content = "Pubblicato"
        let result = await composer.submit { credentials }
        #expect(result != nil)
        #expect(result?.post == nil)
        #expect(!composer.canSubmit)
        #expect(!composer.uncertain)
        #expect(composer.errorMessage == nil)
        #expect(CreationBackend.shared.state(key).requests == 1)
    }

    @Test func credentialFailurePreservesDraftWithoutSending() async throws {
        let (key, api, _) = try setup()
        let composer = PostComposer(api: api)
        composer.content = "Bozza locale"
        #expect(await composer.submit { throw OpenBookError.message("Accedi di nuovo") } == nil)
        #expect(composer.content == "Bozza locale")
        #expect(composer.canSubmit)
        #expect(!composer.uncertain)
        #expect(CreationBackend.shared.state(key).requests == 0)
    }
}
