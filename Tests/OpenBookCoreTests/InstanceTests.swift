import Foundation
import Testing
@testable import OpenBookCore

private final class InstanceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid = request.httpMethod == "GET" && request.url?.absoluteString == "https://example.org/rest/v1/instance" &&
            request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" &&
            request.value(forHTTPHeaderField: "If-None-Match") == nil && request.httpBody == nil
        let status = valid ? Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "200")! : 400
        let fixture = Bundle.module.url(forResource: "instance-configured", withExtension: "json", subdirectory: "Fixtures")!
        let data = status == 200 ? try! Data(contentsOf: fixture) : Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"instance-test\""])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@Suite struct InstanceTests {
    private func setup(status: Int = 200) throws -> (APIClient, Credentials) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstanceProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Status": String(status)]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token))
    }

    @Test func authenticatedInstanceUsesConfiguredOrigin() async throws {
        let (api, credentials) = try setup()
        let metadata = try await api.instanceMetadata(credentials: credentials)
        #expect(metadata.displayName == "Example Social")
        // The metadata's canonical URL may differ from the origin used for authentication.
        #expect(metadata.instanceUrl.host == "social.example")
        #expect(credentials.instance.origin.host == "example.org")
    }

    @Test func officialExamplesAndBlankNameFallback() throws {
        for name in ["configured", "withoutIcon"] {
            let url = Bundle.module.url(forResource: "instance-\(name)", withExtension: "json", subdirectory: "Fixtures")!
            let metadata = try JSONDecoder().decode(InstanceMetadata.self, from: Data(contentsOf: url))
            #expect(metadata.instanceName == "Example Social")
            #expect((metadata.instanceIcon == nil) == (name == "withoutIcon"))
            if name == "withoutIcon" { #expect(metadata.instanceDescription.isEmpty) }
        }
        let empty = Data(#"{"instanceName":"  \n ","instanceDomain":"example.org","instanceUrl":"https://example.org","instanceDescription":"","futureField":true}"#.utf8)
        #expect(try JSONDecoder().decode(InstanceMetadata.self, from: empty).displayName == nil)
    }

    @Test(arguments: [401, 403, 404, 429, 500, 503, 304])
    func errorsAreNotMetadata(status: Int) async throws {
        let (api, credentials) = try setup(status: status)
        do {
            _ = try await api.instanceMetadata(credentials: credentials)
            Issue.record("Una risposta senza metadati non deve essere accettata.")
        } catch OpenBookError.http(let code, _) {
            #expect(code == status)
        }
    }
}
