import Foundation
import Testing
@testable import OpenBookCore

private let requesterIDs = (1...3).map { "01900000-0000-7000-8000-00000000000\($0)" }
private final class RequestBackend: @unchecked Sendable {
    static let shared = RequestBackend()
    struct State {
        var ids = requesterIDs
        var reads = 0
        var writes: [String] = []
        var valid = true
        var failure: Int?
        var mutationCode = 204
        var repeatPage = false
        var emptyWithLink = false
    }
    private let lock = NSLock()
    private var states: [String: State] = [:]
    func update(_ key: String, _ edit: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }; var value = states[key] ?? State(); edit(&value); states[key] = value
    }
    func state(_ key: String) -> State { lock.lock(); defer { lock.unlock() }; return states[key] ?? State() }
    func response(_ request: URLRequest) -> (Int, Data, [String: String]) {
        let key = request.value(forHTTPHeaderField: "X-Test-Session")!
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, body.isEmpty {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                body.append(contentsOf: bytes.prefix(n))
            }
        }
        let url = request.url!
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var code = 200; var data = Data(); var headers: [String: String] = [:]
        update(key) { state in
            state.valid = state.valid && url.host == "example.org" && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
            if request.httpMethod == "GET" {
                state.reads += 1
                state.valid = state.valid && url.path == "/rest/v1/me/follow-requests" && query["sort"] == "personId" && query["direction"] == "asc" && query["limit"] == "20" && query["cursor"] == nil && query["page"] == nil && body.isEmpty
            } else {
                state.writes.append(request.httpMethod!)
                state.valid = state.valid && url.path.hasPrefix("/rest/v1/me/follow-requests/") && query.isEmpty
                if request.httpMethod == "PATCH" {
                    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
                    state.valid = state.valid && json == ["followStatus": "accepted"] && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
                } else { state.valid = state.valid && request.httpMethod == "DELETE" && body.isEmpty }
            }
            if let failure = state.failure { code = failure; data = Data(#"{"detail":"Richiesta non disponibile."}"#.utf8); return }
            if request.httpMethod != "GET" {
                code = state.mutationCode
                if code == 204 { state.ids.removeAll { $0 == url.lastPathComponent } }
                return
            }
            let remaining = state.repeatPage ? state.ids : state.ids.filter { $0 > (query["after"] ?? "") }
            let page = state.emptyWithLink ? [] : Array(remaining.prefix(2))
            let references: [[String: Any]] = page.map { id in
                ["personId": id, "personUsername": "example", "personDomain": "example.org", "personName": "Example \(id.suffix(1))"]
            }
            data = try! JSONSerialization.data(withJSONObject: references)
            if remaining.count > 2 || state.repeatPage || state.emptyWithLink {
                // Person collections reconstruct the next request locally, never forwarding Bearer here.
                headers["Link"] = "<https://untrusted.example/anything>; rel=\"next\""
            }
        }
        return (code, data, headers)
    }
}
private final class RequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data, headers) = RequestBackend.shared.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct IncomingFollowRequestsTests {
    private func setup() throws -> (String, APIClient, Credentials, IncomingFollowRequests) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestProtocol.self]; config.httpAdditionalHeaders = ["X-Test-Session": key]
        let api = APIClient(session: URLSession(configuration: config))
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        let credentials = try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token)
        return (key, api, credentials, IncomingFollowRequests(api: api))
    }

    @Test func paginatesRequestsAndKeepsCursorAfterHandlingLastRow() async throws {
        let (key, _, credentials, model) = try setup()
        await model.load(reset: true) { credentials }
        #expect(model.people.map(\.id) == Array(requesterIDs.prefix(2)))
        #expect(await model.decide(personID: requesterIDs[1], accept: true) { credentials })
        #expect(model.cursor == requesterIDs[1])
        await model.load(reset: false) { credentials }
        #expect(model.people.map(\.id) == [requesterIDs[0], requesterIDs[2]])
        #expect(!model.hasNext)
        #expect(RequestBackend.shared.state(key).valid)
    }

    @Test(arguments: [true, false]) func removesOnlyConfirmedDecisions(accept: Bool) async throws {
        let (key, _, credentials, model) = try setup()
        await model.load(reset: true) { credentials }
        #expect(await model.decide(personID: requesterIDs[0], accept: accept) { credentials })
        #expect(!model.people.contains { $0.id == requesterIDs[0] })
        #expect(RequestBackend.shared.state(key).writes == [accept ? "PATCH" : "DELETE"])
        #expect(RequestBackend.shared.state(key).valid)
    }

    @Test(arguments: [401, 403, 404, 422, 429, 503]) func failedDecisionRequiresExplicitReload(code: Int) async throws {
        let (key, _, credentials, model) = try setup()
        await model.load(reset: true) { credentials }
        RequestBackend.shared.update(key) { $0.failure = code }
        #expect(await model.decide(personID: requesterIDs[0], accept: true) { credentials } == false)
        #expect(model.requiresReload && model.errorMessage != nil)
        #expect(await model.decide(personID: requesterIDs[0], accept: true) { credentials } == false)
        #expect(RequestBackend.shared.state(key).writes.count == 1)
        if [401, 403].contains(code) { #expect(model.people.isEmpty) }
        else { #expect(model.people.count == 2) }
        RequestBackend.shared.update(key) { $0.failure = nil; $0.ids.removeFirst() }
        await model.load(reset: true) { credentials }
        #expect(!model.requiresReload)
        #expect(!model.people.contains { $0.id == requesterIDs[0] })
    }

    @Test func unexpected200IsNotASuccess() async throws {
        let (key, _, credentials, model) = try setup()
        await model.load(reset: true) { credentials }
        RequestBackend.shared.update(key) { $0.mutationCode = 200 }
        #expect(await model.decide(personID: requesterIDs[0], accept: false) { credentials } == false)
        #expect(model.people.count == 2 && model.requiresReload)
    }

    @Test func repeatsAndEmptyPagesStopPagination() async throws {
        let (key, _, credentials, model) = try setup()
        RequestBackend.shared.update(key) { $0.repeatPage = true }
        await model.load(reset: true) { credentials }
        await model.load(reset: false) { credentials }
        #expect(model.people.count == 2 && !model.hasNext)
        RequestBackend.shared.update(key) { $0.repeatPage = false; $0.emptyWithLink = true }
        await model.load(reset: true) { credentials }
        #expect(model.people.isEmpty && !model.hasNext)
    }

    @Test func readFailureKeepsPageForExplicitRetryAndAccessLossClearsIt() async throws {
        let (key, _, credentials, model) = try setup()
        await model.load(reset: true) { credentials }
        RequestBackend.shared.update(key) { $0.failure = 503 }
        await model.load(reset: false) { credentials }
        #expect(model.people.count == 2 && model.hasNext && model.errorMessage != nil)
        RequestBackend.shared.update(key) { $0.failure = nil }
        await model.load(reset: false) { credentials }
        #expect(model.people.count == 3 && model.errorMessage == nil)
        RequestBackend.shared.update(key) { $0.failure = 403 }
        await model.load(reset: true) { credentials }
        #expect(model.people.isEmpty && !model.hasNext && !model.hasLoaded)
    }

    @Test func duplicateWorkAndSessionResetCannotSendDecisions() async throws {
        let (key, _, credentials, model) = try setup()
        await model.load(reset: true) { credentials }
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await model.decide(personID: requesterIDs[0], accept: true) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        #expect(await model.decide(personID: requesterIDs[0], accept: false) { Issue.record("Duplicate write"); return credentials } == false)
        await model.load(reset: true) { Issue.record("Concurrent read"); return credentials }
        model.reset(); release?.resume(returning: credentials)
        #expect(await task.value == false)
        #expect(model.people.isEmpty && !model.isChanging)
        #expect(RequestBackend.shared.state(key).writes.isEmpty)
    }

    @Test func failedReconciliationDoesNotUnlockDecisions() async throws {
        let (key, _, credentials, model) = try setup()
        await model.load(reset: true) { credentials }
        RequestBackend.shared.update(key) { $0.failure = 503 }
        _ = await model.decide(personID: requesterIDs[0], accept: true) { credentials }
        await model.load(reset: true) { credentials }
        #expect(model.requiresReload)
        #expect(await model.decide(personID: requesterIDs[0], accept: false) { credentials } == false)
        #expect(RequestBackend.shared.state(key).writes == ["PATCH"])
    }

    @Test func refreshAllowsANewRequestFromAPreviouslyHandledPerson() async throws {
        let (key, _, credentials, model) = try setup()
        await model.load(reset: true) { credentials }
        _ = await model.decide(personID: requesterIDs[0], accept: false) { credentials }
        RequestBackend.shared.update(key) { $0.ids = requesterIDs }
        await model.load(reset: true) { credentials }
        #expect(model.people.first?.id == requesterIDs[0])
    }

    @Test func cancelledReadCannotPopulateANewSession() async throws {
        let (key, _, credentials, model) = try setup()
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await model.load(reset: true) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        model.reset(); release?.resume(returning: credentials)
        await task.value
        #expect(model.people.isEmpty && !model.hasLoaded && !model.isLoading)
        #expect(RequestBackend.shared.state(key).reads == 0)
    }

    @Test func invalidIdentifiersNeverSendBearer() async throws {
        let (key, api, credentials, _) = try setup()
        await #expect(throws: (any Error).self) { try await api.followRequests(after: "../bad", credentials: credentials) }
        await #expect(throws: (any Error).self) { try await api.decideFollowRequest(personID: "../bad", accept: true, credentials: credentials) }
        #expect(RequestBackend.shared.state(key).reads == 0)
        #expect(RequestBackend.shared.state(key).writes.isEmpty)
    }

    @Test func officialExamplesMatchWireContract() throws {
        let empty = Bundle.module.url(forResource: "follow-requests-empty", withExtension: "json", subdirectory: "Fixtures")!
        #expect(try JSONDecoder().decode([PersonReference].self, from: Data(contentsOf: empty)).isEmpty)
        let patch = Bundle.module.url(forResource: "accept-follow-request", withExtension: "json", subdirectory: "Fixtures")!
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: patch)) as? [String: String] == ["followStatus": "accepted"])
    }
}
