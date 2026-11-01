import Foundation
import Testing
@testable import OpenBookCore

@MainActor @Suite struct CredentialRenewalTests {
    private func credentials(_ token: String = "old", refresh: Bool = true) throws -> Credentials {
        let json: [String: Any] = ["access_token": token, "token_type": "Bearer", "expires_in": 30]
            .merging(refresh ? ["refresh_token": "test-refresh"] : [:]) { a, _ in a }
        return try Credentials(instance: Instance("https://example.org"), clientID: "test-client",
                               token: JSONDecoder().decode(TokenResponse.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    @Test func tokenEndpointReturnsOnlyControlledTerminalErrors() async throws {
        for (status, code, terminal) in [(400, "invalid_grant", true), (400, "invalid_client", true),
                                         (400, "unauthorized_client", true), (401, "unknown", true),
                                         (400, "invalid_request", false), (429, "invalid_grant", false),
                                         (503, "invalid_grant", false)] {
            let routed = URLSessionConfiguration.ephemeral
            routed.protocolClasses = [RoutedTokenProtocol.self]
            routed.httpAdditionalHeaders = ["X-Test-Status": String(status), "X-Test-Error": code]
            let client = APIClient(session: URLSession(configuration: routed))
            do {
                _ = try await client.token(instance: Instance("https://example.org"), fields: ["grant_type": "refresh_token"])
                Issue.record("Expected token failure")
            } catch {
                #expect((error is OAuthTokenError) == terminal)
                #expect(!error.localizedDescription.contains("sensitive-test-description"))
            }
        }
    }

    @Test func terminalFailureIsLatchedAndStorageInvalidatedOnlyOnce() async throws {
        let renewal = CredentialRenewal()
        let current = try credentials()
        var calls = 0; var invalidations = 0
        for _ in 0..<3 {
            do {
                _ = try await renewal.authorized(current: current, refresh: { _ in
                    calls += 1; throw OAuthTokenError.invalidGrant
                }, save: { _ in Issue.record("Cannot save rejected refresh") }, invalidate: { _ in invalidations += 1 })
                Issue.record("Expected reauthentication")
            } catch { #expect(error is OAuthTokenError) }
        }
        #expect(calls == 1)
        #expect(invalidations == 1)
        #expect(renewal.requiresReauthentication)
        renewal.reset()
        let renewed = try await renewal.authorized(current: current, refresh: { _ in try credentials("new-session") },
                                                   save: { _ in }, invalidate: { _ in })
        #expect(renewed.accessToken == "new-session" && !renewal.requiresReauthentication)
    }

    @Test func transientFailuresRemainRetryableAndResetAllowsNewSession() async throws {
        let renewal = CredentialRenewal()
        let current = try credentials()
        var calls = 0; var saved: String?
        do {
            _ = try await renewal.authorized(current: current, refresh: { _ in
                calls += 1; throw OpenBookError.http(503, "Temporary")
            }, save: { _ in }, invalidate: { _ in Issue.record("Transient failure must not clear session") })
        } catch { #expect(error is OpenBookError) }
        #expect(!renewal.requiresReauthentication)
        let result = try await renewal.authorized(current: current, refresh: { _ in
            calls += 1; return try credentials("new")
        }, save: { saved = $0.accessToken }, invalidate: { _ in })
        #expect(calls == 2 && saved == "new" && result.accessToken == "new")
        renewal.reset()
        #expect(!renewal.requiresReauthentication)
    }

    @Test func missingRefreshOrFailedStorageRemovalStillBlocksFurtherRefresh() async throws {
        for hasRefresh in [false, true] {
            let renewal = CredentialRenewal()
            let current = try credentials(refresh: hasRefresh)
            var calls = 0
            for _ in 0..<2 {
                do {
                    _ = try await renewal.authorized(current: current, refresh: { _ in
                        calls += 1; throw OAuthTokenError.invalidGrant
                    }, save: { _ in }, invalidate: { _ in throw OpenBookError.message("Storage unavailable") })
                    Issue.record("Expected failure")
                } catch { }
            }
            #expect(renewal.requiresReauthentication)
            #expect(calls == (hasRefresh ? 1 : 0))
        }
    }

    @Test func concurrentCallersShareOneRefreshAndSave() async throws {
        let renewal = CredentialRenewal()
        let gate = RefreshGate()
        let current = try credentials()
        var calls = 0; var saves = 0; var firstStarted = false; var secondStarted = false
        let first = Task {
            firstStarted = true
            return try await renewal.authorized(current: current, refresh: { _ in
            calls += 1; return try await gate.wait()
        }, save: { _ in saves += 1 }, invalidate: { _ in }) }
        let second = Task {
            secondStarted = true
            return try await renewal.authorized(current: current, refresh: { _ in
                calls += 1; return try await gate.wait()
            }, save: { _ in saves += 1 }, invalidate: { _ in })
        }
        while gate.continuation == nil || !firstStarted || !secondStarted { await Task.yield() }
        gate.continuation?.resume(returning: try credentials("new"))
        #expect(try await first.value.accessToken == "new")
        #expect(try await second.value.accessToken == "new")
        #expect(calls == 1 && saves == 1)
    }

    @Test func sessionResetRejectsOldSuccessAndOldTerminalFailure() async throws {
        for fails in [false, true] {
            let renewal = CredentialRenewal()
            let gate = RefreshGate()
            let current = try credentials()
            var saves: [String] = []; var invalidations = 0
            let old = Task { try await renewal.authorized(current: current, refresh: { _ in
                try await gate.wait()
            }, save: { saves.append($0.accessToken) }, invalidate: { _ in invalidations += 1 }) }
            while gate.continuation == nil { await Task.yield() }
            renewal.reset()
            _ = try await renewal.authorized(current: current, refresh: { _ in try credentials("new-session") },
                                             save: { saves.append($0.accessToken) }, invalidate: { _ in invalidations += 1 })
            if fails { gate.continuation?.resume(throwing: OAuthTokenError.invalidGrant) }
            else { gate.continuation?.resume(returning: try credentials("stale")) }
            do { _ = try await old.value; Issue.record("Old task must not succeed") }
            catch { #expect(error is CancellationError) }
            #expect(saves == ["new-session"] && invalidations == 0)
            #expect(!renewal.requiresReauthentication)
        }
    }
}

@MainActor private final class RefreshGate {
    var continuation: CheckedContinuation<Credentials, Error>?
    func wait() async throws -> Credentials {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

private final class RoutedTokenProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "X-Test-Status")!)!
        let code = request.value(forHTTPHeaderField: "X-Test-Error")!
        let data = try! JSONSerialization.data(withJSONObject: ["error": code, "error_description": "sensitive-test-description"])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
