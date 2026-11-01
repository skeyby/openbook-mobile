import Foundation
import Testing
@testable import OpenBookCore

private let targetID = "01900000-0000-7000-8000-000000000003"
private let ownID = "01900000-0000-7000-8000-000000000001"

private final class FollowBackend: @unchecked Sendable {
    static let shared = FollowBackend()
    struct State {
        var status = "none"
        var resultingStatus = "accepted"
        var reads = 0
        var writes: [String] = []
        var failure: Int?
        var malformed = false
        var valid = true
    }
    private let lock = NSLock()
    private var sessions: [String: State] = [:]
    func update(_ key: String, _ edit: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }; var value = sessions[key] ?? State(); edit(&value); sessions[key] = value
    }
    func state(_ key: String) -> State { lock.lock(); defer { lock.unlock() }; return sessions[key] ?? State() }
    func response(_ request: URLRequest) -> (Int, Data) {
        let key = request.value(forHTTPHeaderField: "X-Test-Session")!
        var code = 200
        var data = Data()
        update(key) { state in
            state.valid = state.valid && request.url?.absoluteString == "https://example.org/rest/v1/persons/\(targetID)/follow" &&
                request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" &&
                request.httpBody == nil && request.httpBodyStream == nil && request.value(forHTTPHeaderField: "If-None-Match") == nil
            if request.httpMethod == "GET" { state.reads += 1 } else { state.writes.append(request.httpMethod!) }
            if let failure = state.failure { code = failure; data = Data(#"{"detail":"Operazione non consentita."}"#.utf8); return }
            switch request.httpMethod {
            case "GET": break
            case "PUT": code = state.status == "none" ? 201 : 200; state.status = state.resultingStatus
            case "DELETE": code = 204; state.status = "none"; return
            default: code = 405; return
            }
            data = state.malformed ? Data("invalid".utf8) : try! JSONSerialization.data(withJSONObject: ["followStatus": state.status])
        }
        return (code, data)
    }
}
private final class FollowProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = FollowBackend.shared.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor @Suite struct FollowTests {
    private func setup() throws -> (String, APIClient, Credentials) {
        let key = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FollowProtocol.self]; config.httpAdditionalHeaders = ["X-Test-Session": key]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (key, APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token))
    }

    @Test func officialStatesAndFutureValue() throws {
        for status in ["none", "pending", "accepted"] {
            let url = Bundle.module.url(forResource: "follow-\(status)", withExtension: "json", subdirectory: "Fixtures")!
            let follow = try JSONDecoder().decode(Follow.self, from: Data(contentsOf: url))
            #expect(follow.status?.rawValue == status)
        }
        #expect(try JSONDecoder().decode(Follow.self, from: Data(#"{"followStatus":"future"}"#.utf8)).status == nil)
    }

    @Test(arguments: ["pending", "accepted"]) func getPut201Put200AndDelete204(status: String) async throws {
        let (key, api, credentials) = try setup()
        #expect(try await api.follow(id: targetID, credentials: credentials).followStatus == "none")
        FollowBackend.shared.update(key) { $0.resultingStatus = status }
        #expect(try await api.setFollow(id: targetID, following: true, credentials: credentials).followStatus == status)
        #expect(try await api.setFollow(id: targetID, following: true, credentials: credentials).followStatus == status)
        #expect(try await api.setFollow(id: targetID, following: false, credentials: credentials).followStatus == "none")
        #expect(FollowBackend.shared.state(key).valid)
    }

    @Test(arguments: ["pending", "accepted"]) func toggleRemovesRequestsAsWellAsAcceptedFollows(status: String) async throws {
        let (key, api, credentials) = try setup()
        FollowBackend.shared.update(key) { $0.resultingStatus = status }
        let follows = PersonFollows(api: api)
        await follows.load(personID: targetID) { credentials }
        #expect(await follows.toggle(personID: targetID, currentPersonID: ownID) { credentials })
        #expect(follows.states[targetID]?.followStatus == status)
        #expect(await follows.toggle(personID: targetID, currentPersonID: ownID) { credentials })
        #expect(follows.states[targetID]?.followStatus == "none")
        #expect(FollowBackend.shared.state(key).writes == ["PUT", "DELETE"])
    }

    @Test(arguments: [401, 403, 404, 422, 429, 500, 503]) func failedWriteRequiresReadBeforeAnotherWrite(code: Int) async throws {
        let (key, api, credentials) = try setup()
        let follows = PersonFollows(api: api)
        await follows.load(personID: targetID) { credentials }
        FollowBackend.shared.update(key) { $0.failure = code }
        #expect(await follows.toggle(personID: targetID, currentPersonID: ownID) { credentials } == false)
        #expect(follows.states[targetID] == nil)
        #expect(follows.errors[targetID] != nil)
        #expect(await follows.toggle(personID: targetID, currentPersonID: ownID) { credentials } == false)
        FollowBackend.shared.update(key) { $0.failure = nil }
        await follows.load(personID: targetID) { credentials }
        #expect(follows.states[targetID]?.followStatus == "none")
        #expect(FollowBackend.shared.state(key).writes.count == 1)
    }

    @Test func malformedSuccessIsReconciledWithoutResendingPut() async throws {
        let (key, api, credentials) = try setup()
        let follows = PersonFollows(api: api)
        await follows.load(personID: targetID) { credentials }
        FollowBackend.shared.update(key) { $0.malformed = true; $0.resultingStatus = "pending" }
        #expect(await follows.toggle(personID: targetID, currentPersonID: ownID) { credentials } == false)
        FollowBackend.shared.update(key) { $0.malformed = false }
        await follows.load(personID: targetID) { credentials }
        #expect(follows.states[targetID]?.followStatus == "pending")
        #expect(FollowBackend.shared.state(key).writes == ["PUT"])
    }

    @Test func unknownStateAndSelfFollowCannotBeChanged() async throws {
        let (key, api, credentials) = try setup()
        FollowBackend.shared.update(key) { $0.status = "future" }
        let follows = PersonFollows(api: api)
        await follows.load(personID: targetID) { credentials }
        #expect(await follows.toggle(personID: targetID, currentPersonID: ownID) { credentials } == false)
        FollowBackend.shared.update(key) { $0.status = "none" }
        await follows.load(personID: targetID) { credentials }
        #expect(await follows.toggle(personID: targetID, currentPersonID: targetID.uppercased()) { credentials } == false)
        #expect(await follows.toggle(personID: targetID, currentPersonID: nil) { credentials } == false)
        #expect(FollowBackend.shared.state(key).writes.isEmpty)
    }

    @Test func duplicateAndDisconnectedWorkCannotSendWrites() async throws {
        let (key, api, credentials) = try setup()
        let follows = PersonFollows(api: api)
        await follows.load(personID: targetID) { credentials }
        var release: CheckedContinuation<Credentials, Never>?
        let task = Task { await follows.toggle(personID: targetID, currentPersonID: ownID) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        #expect(await follows.toggle(personID: targetID, currentPersonID: ownID) { Issue.record("Duplicate credentials"); return credentials } == false)
        follows.reset(); release?.resume(returning: credentials)
        #expect(await task.value == false)
        #expect(follows.states.isEmpty && follows.pending.isEmpty && follows.errors.isEmpty)
        #expect(FollowBackend.shared.state(key).writes.isEmpty)
    }

    @Test(arguments: [401, 403, 404, 429, 503]) func failedReadClearsPreviouslyKnownState(code: Int) async throws {
        let (key, api, credentials) = try setup()
        let follows = PersonFollows(api: api)
        FollowBackend.shared.update(key) { $0.status = "accepted" }
        await follows.load(personID: targetID) { credentials }
        #expect(follows.states[targetID]?.followStatus == "accepted")
        FollowBackend.shared.update(key) { $0.failure = code }
        await follows.load(personID: targetID) { credentials }
        #expect(follows.states[targetID] == nil)
        #expect(follows.errors[targetID] != nil)
        #expect(FollowBackend.shared.state(key).writes.isEmpty)
    }

    @Test func invalidIdentifierCannotSendBearer() async throws {
        let (key, api, credentials) = try setup()
        await #expect(throws: (any Error).self) { try await api.follow(id: "../invalid", credentials: credentials) }
        await #expect(throws: (any Error).self) { try await api.setFollow(id: "../invalid", following: true, credentials: credentials) }
        #expect(FollowBackend.shared.state(key).reads == 0)
        #expect(FollowBackend.shared.state(key).writes.isEmpty)
    }
}
