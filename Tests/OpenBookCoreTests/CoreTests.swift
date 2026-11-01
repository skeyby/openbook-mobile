import Foundation
import Testing
@testable import OpenBookCore

@Suite struct ContractTests {
    @Test func instanceValidation() throws {
        #expect(try Instance(" https://SOCIAL.example.org/ ").origin.absoluteString == "https://social.example.org")
        #expect(throws: (any Error).self) { try Instance("http://social.example.org") }
        #expect(throws: (any Error).self) { try Instance("https://user:secret@example.org") }
        #expect(throws: (any Error).self) { try Instance("https://example.org/rest/v1") }
        #expect(throws: (any Error).self) { try Instance("https://example.org?token=secret") }
        #expect(try Instance("http://localhost:8000").url("/oauth/token").absoluteString == "http://localhost:8000/oauth/token")
    }

    @Test func pkceRFC7636Vector() throws {
        #expect(OAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = try OAuth.randomValue()
        #expect(random.count == 43)
        #expect(random != (try OAuth.randomValue()))
        #expect(!random.contains("="))
    }

    @Test func callbackValidation() throws {
        let callback = URL(string: "it.brancatelli.openbook.mobile://oauth/callback?code=abc&state=expected")!
        #expect(try OAuth.authorizationCode(from: callback, expectedState: "expected") == "abc")
        #expect(throws: (any Error).self) { try OAuth.authorizationCode(from: callback, expectedState: "wrong") }
        for invalid in [
            "org.openbook.mobile://oauth/callback?code=abc&state=expected",
            "it.brancatelli.openbook.mobile://other/callback?code=abc&state=expected",
            "it.brancatelli.openbook.mobile://oauth/callback?code=abc&state=expected&state=other",
            "it.brancatelli.openbook.mobile://oauth/callback?code=abc&code=def&state=expected",
            "it.brancatelli.openbook.mobile://oauth/callback?error=access_denied&state=expected"
        ] {
            #expect(throws: (any Error).self) { try OAuth.authorizationCode(from: URL(string: invalid)!, expectedState: "expected") }
        }
    }

    @Test func authorizationParametersAndFormEncoding() throws {
        let url = OAuth.authorizationURL(instance: try Instance("https://example.org"), clientID: "client+id", verifier: "verifier", state: "state")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(url.path == "/oauth/authorize")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.first { $0.name == "client_id" }?.value == "client+id")
        #expect(String(data: OAuth.form(["code": "a+b&c =/?"]), encoding: .utf8) == "code=a%2Bb%26c%20%3D%2F%3F")
    }

    @Test func officialProfileExampleAndOptionalFields() throws {
        let fixture = Bundle.module.url(forResource: "person", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: fixture)
        let person = try JSONDecoder().decode(Person.self, from: data)
        #expect(person.personFollowersCount == nil)
        #expect(person.personFollowingCount == 12)
        #expect(person.personProfile.personName == "Alex Example")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["personType"] = "futureType"
        object["personFollowersCount"] = 0
        object["personFollowingCount"] = nil
        object["personProfile"] = ["personName": "Minimal"]
        let minimal = try JSONDecoder().decode(Person.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(minimal.personProfile.personSummary == nil)
        #expect(minimal.personFollowersCount == 0)
        #expect(minimal.personFollowingCount == nil)
        #expect(minimal.personType == "futureType")
    }

    @Test func tokenRotationKeepsPreviousRefreshToken() throws {
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"new","token_type":"Bearer","expires_in":3600}"#.utf8))
        let credentials = try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token, previousRefreshToken: "old-refresh")
        #expect(credentials.refreshToken == "old-refresh")
        #expect(credentials.expiresAt > Date().addingTimeInterval(3500))
        let saved = try JSONDecoder().decode(Credentials.self, from: JSONEncoder().encode(credentials))
        #expect(saved.accessToken == "new")
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = "{}"
        if url.path == "/oauth/register" {
            let json = (try? JSONSerialization.jsonObject(with: requestBody())) as? [String: Any]
            if request.httpMethod != "POST" || json?["token_endpoint_auth_method"] as? String != "none" || json?["redirect_uris"] as? [String] != [OAuth.redirectURI] { status = 400 }
            body = #"{"client_id":"registered"}"#
        } else if url.path == "/oauth/token" {
            if request.httpMethod != "POST" || request.value(forHTTPHeaderField: "Content-Type") != "application/x-www-form-urlencoded" { status = 400 }
            body = #"{"access_token":"new","token_type":"Bearer","expires_in":3600}"#
        } else if request.value(forHTTPHeaderField: "Authorization") != "Bearer test-token" {
            status = 401
        } else if url.path == "/rest/v1/me" {
            let fixture = Bundle.module.url(forResource: "person", withExtension: "json", subdirectory: "Fixtures")!
            let person = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixture))
            body = String(data: try! JSONSerialization.data(withJSONObject: ["myPerson": person]), encoding: .utf8)!
        } else if url.path == "/rest/v1/posts" {
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let isTimeline = query["engine"] == "timeline"
            if url.host != "example.org" || !["world", "timeline"].contains(query["engine"] ?? "") || query["limit"] != "20" || query["sort"] != (isTimeline ? "postTimelineAt" : "postPublishedAt") || query["direction"] != "desc" { status = 400 }
            if let _ = query["after"], isTimeline && query["afterAt"] != "2026-10-27T10:00:00.123456+02:00" { status = 400 }
            if !isTimeline && query["afterAt"] != nil { status = 400 }
            let after = query["after"]
            if after == PostFixtures.id(422) {
                status = 422
                body = #"{"detail":"Il post di riferimento non è più disponibile."}"#
            } else {
                let lastID = query["after"] == nil ? 2 : 3
                let boundary = isTimeline ? "&afterAt=2026-10-27T10%3A00%3A00.123456%2B02%3A00" : ""
                headers["Link"] = "<https://example.org/rest/v1/posts?engine=\(query["engine"]!)&sort=\(query["sort"]!)&direction=desc&limit=20&after=\(PostFixtures.id(lastID))\(boundary)>; rel=\"next\""
                let posts: [[String: Any]]
                if after == nil { posts = [PostFixtures.object(1), PostFixtures.object(2)] }
                else if after == PostFixtures.id(2) { posts = [PostFixtures.object(2), PostFixtures.object(3)] }
                else if after == PostFixtures.id(3) { posts = [] }
                else { posts = []; status = 400 }
                body = String(data: try! JSONSerialization.data(withJSONObject: posts), encoding: .utf8)!
            }
        } else if url.path.hasSuffix("/followers") {
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if query["limit"] != "20" || query["sort"] != "personId" || query["direction"] != "asc" { status = 400 }
            if query["after"] == nil {
                headers["Link"] = #"<https://untrusted.example/should-not-be-followed>; rel="next""#
                body = #"[{"personId":"01900000-0000-7000-8000-000000000001","personUsername":"alex","personDomain":"example.org","personName":"Alex"}]"#
            } else if query["after"] != "01900000-0000-7000-8000-000000000001" { status = 400 }
            else { body = "[]" }
        } else if url.path.hasSuffix("000000000401") {
            status = 401
            body = #"{"title":"Unauthorized","status":401}"#
        } else if url.path.hasSuffix("000000000429") {
            status = 429
            body = #"{"title":"Too Many Requests","detail":"Attendi prima di riprovare."}"#
        } else { body = "invalid JSON" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    override func stopLoading() { }
}

@Suite struct NetworkTests {
    private func setup() throws -> (APIClient, Credentials) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token))
    }

    @Test func registrationAndExchangeUseRootEndpoints() async throws {
        let (api, credentials) = try setup()
        #expect(try await api.register(instance: credentials.instance).client_id == "registered")
        #expect(try await api.token(instance: credentials.instance, fields: ["grant_type": "refresh_token"]).access_token == "new")
    }

    @Test func authenticatedPaginationUsesCursorAtOriginalInstance() async throws {
        let (api, credentials) = try setup()
        let page = try await api.people(id: "01900000-0000-7000-8000-000000000000", relationship: .followers, after: nil, credentials: credentials)
        #expect(page.people.count == 1)
        #expect(page.hasNext)
        let last = try await api.people(id: "01900000-0000-7000-8000-000000000000", relationship: .followers, after: page.people.last?.id, credentials: credentials)
        #expect(last.people.isEmpty)
        #expect(!last.hasNext)
    }

    @Test func httpProblemsPreserveStatus() async throws {
        let (api, credentials) = try setup()
        for status in [401, 429] {
            do {
                _ = try await api.person(id: "01900000-0000-7000-8000-000000000\(status)", credentials: credentials)
                Issue.record("Expected HTTP error")
            } catch OpenBookError.http(let received, let message) {
                #expect(received == status)
                #expect(!message.isEmpty)
            }
        }
    }

    @Test func rejectsMalformedPayloadAndInvalidIdentifier() async throws {
        let (api, credentials) = try setup()
        await #expect(throws: (any Error).self) {
            try await api.person(id: "01900000-0000-7000-8000-000000000000", credentials: credentials)
        }
        await #expect(throws: (any Error).self) {
            try await api.person(id: "../oauth/token", credentials: credentials)
        }
    }
}

// Synthetic pages exercise overlapping entries, cursor errors and empty pages.
private enum PostFixtures {
    static func id(_ number: Int) -> String { String(format: "01900000-0000-7000-8000-%012d", number) }
    static func object(_ number: Int) -> [String: Any] {
        [
            "postId": id(number), "postUri": "https://example.org/posts/\(number)",
            "postAuthor": ["personId": id(99), "personUsername": "alex", "personDomain": "example.org", "personName": "Alex"],
            "postContent": "Post \(number)\nSeconda riga", "postCW": false, "postVisibility": "public",
            "postPublishedAt": "2026-10-26T10:00:00.123Z", "postAttributes": ["postLocation": NSNull()],
            "postCounters": ["postLikesCount": 0, "postCommentsCount": 1, "postAnnouncesCount": 2],
            "postMyInteractions": ["postLiked": false, "postAnnounced": true, "postDirectAnnounced": false]
        ]
    }
    static func post(_ number: Int) throws -> Post {
        try JSONDecoder().decode(Post.self, from: JSONSerialization.data(withJSONObject: object(number)))
    }
}

@Suite struct TimelineTests {
    private func setup() throws -> (APIClient, Credentials) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let token = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8))
        return (APIClient(session: URLSession(configuration: config)), try Credentials(instance: Instance("https://example.org"), clientID: "client", token: token))
    }

    @Test func currentPersonComesFromMe() async throws {
        let (api, credentials) = try setup()
        let me = try await api.me(credentials: credentials)
        #expect(me.myPerson.personId == "2f8c1653-5b14-4f82-a5b9-921e50fa4267")
        #expect(me.myPerson.personProfile.personName == "Alex Example")
    }

    @Test func worldPaginationPreservesOrderAndStopsOnEmptyPage() async throws {
        let (api, credentials) = try setup()
        var timeline = PostTimeline()
        let first = try await api.posts(engine: .world, credentials: credentials)
        timeline.apply(first, replacing: true)
        #expect(timeline.posts.map(\.id) == [PostFixtures.id(1), PostFixtures.id(2)])
        #expect(timeline.hasNext)
        let second = try await api.posts(engine: .world, nextPage: timeline.nextPage, credentials: credentials)
        timeline.apply(second, replacing: false)
        #expect(timeline.posts.map(\.id) == [PostFixtures.id(1), PostFixtures.id(2), PostFixtures.id(3)])
        #expect(timeline.nextPage?.query?.contains(PostFixtures.id(3)) == true)
        let last = try await api.posts(engine: .world, nextPage: timeline.nextPage, credentials: credentials)
        #expect(!last.hasNext)
        timeline.apply(last, replacing: false)
        #expect(!timeline.hasNext)
        #expect(timeline.posts.count == 3)
    }

    @Test func repeatedCursorStopsAndRefreshReplacesFeed() throws {
        let post = try PostFixtures.post(1)
        var timeline = PostTimeline()
        timeline.apply(PostsPage(posts: [post, post], nextPage: URL(string: "https://example.org/next")!), replacing: true)
        #expect(timeline.posts.count == 1)
        timeline.apply(PostsPage(posts: [post], nextPage: URL(string: "https://example.org/next")!), replacing: false)
        #expect(!timeline.hasNext)
        timeline.apply(PostsPage(posts: [try PostFixtures.post(2)], nextPage: nil), replacing: true)
        #expect(timeline.posts.map(\.id) == [PostFixtures.id(2)])
        #expect(timeline.hasLoaded)
        timeline.clear()
        #expect(timeline.posts.isEmpty)
        #expect(!timeline.hasLoaded)
        #expect(timeline.nextPage == nil)
    }

    @Test func unavailableCursorIsAnHTTPError() async throws {
        let (api, credentials) = try setup()
        do {
            _ = try await api.posts(engine: .world, nextPage: URL(string: "https://example.org/rest/v1/posts?engine=world&sort=postPublishedAt&direction=desc&limit=20&after=\(PostFixtures.id(422))"), credentials: credentials)
            Issue.record("Expected HTTP 422")
        } catch OpenBookError.http(let status, _) { #expect(status == 422) }
        await #expect(throws: (any Error).self) {
            try await api.posts(nextPage: URL(string: "https://untrusted.example/rest/v1/posts?after=invalid"), credentials: credentials)
        }
    }

    @Test func defaultTimelineFollowsCompositeBoundaryExactly() async throws {
        let (api, credentials) = try setup()
        let first = try await api.posts(credentials: credentials)
        let next = try #require(first.nextPage)
        let items = URLComponents(url: next, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "engine" }?.value == "timeline")
        #expect(items.first { $0.name == "afterAt" }?.value == "2026-10-27T10:00:00.123456+02:00")
        let second = try await api.posts(nextPage: next, credentials: credentials)
        #expect(second.posts.map(\.id) == [PostFixtures.id(2), PostFixtures.id(3)])
    }

    @Test func rejectsOtherOriginsAndEnginesBeforeFollowingNextPage() async throws {
        let (api, credentials) = try setup()
        for url in [
            "https://untrusted.example/rest/v1/posts?engine=timeline&after=\(PostFixtures.id(2))&afterAt=2026-10-27T10:00:00Z",
            "https://example.org/rest/v1/posts?engine=world&after=\(PostFixtures.id(2))",
            "https://example.org/rest/v1/posts?engine=timeline&after=\(PostFixtures.id(2))",
            "https://example.org/rest/v1/posts?engine=timeline&engine=world&after=\(PostFixtures.id(2))&afterAt=2026-10-27T10:00:00Z"
        ] {
            await #expect(throws: (any Error).self) {
                try await api.posts(nextPage: URL(string: url), credentials: credentials)
            }
        }
    }

    @Test func officialWorldAndTimelineExamplesDecodeAnnounceContext() throws {
        for engine in PostEngine.allCases {
            let fixture = Bundle.module.url(forResource: "posts-\(engine.rawValue)", withExtension: "json", subdirectory: "Fixtures")!
            let posts = try JSONDecoder().decode([Post].self, from: Data(contentsOf: fixture))
            let post = try #require(posts.first)
            if engine == .timeline {
                #expect(post.postTimelineAt == "2026-10-26T10:00:00Z")
                #expect(post.postAnnounce?.announceAuthor.personName == "Sam Example")
                #expect(post.postAnnounce?.announceAuthor.personId != post.postAuthor.personId)
            } else {
                #expect(post.postTimelineAt == nil)
                #expect(post.postAnnounce == nil)
            }
        }
    }

    @Test func postContentWarningsMediaLocationAndOptionalFields() throws {
        let minimal = try PostFixtures.post(1)
        #expect(minimal.postAttachments == nil)
        #expect(minimal.postAttributes.postLocation == nil)
        #expect(minimal.postCounters.postLikesCount == 0)
        #expect(minimal.publishedDate != nil)
        #expect(minimal.postAuthor.personId == PostFixtures.id(99))
        var object = PostFixtures.object(2)
        object["postContent"] = ""
        object["postCW"] = true
        object["postCWText"] = "Avviso"
        object["postAttachments"] = [[
            "mediaId": PostFixtures.id(20), "mediaUrl": "https://example.org/image.png",
            "mediaPreviewUrl": "https://example.org/thumb.png", "mediaMimeType": "image/png",
            "mediaWidth": NSNull(), "mediaHeight": NSNull(), "mediaAltText": "Descrizione"
        ]]
        object["postAttributes"] = ["postLocation": [
            "locationName": "Helsinki", "locationRegion": NSNull(), "locationCountryCode": "FI",
            "locationCountryName": "Finlandia", "locationLatitude": 60.17, "locationLongitude": 24.94
        ]]
        let full = try JSONDecoder().decode(Post.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(full.postCW)
        #expect(full.postContent.isEmpty)
        #expect(full.postAttachments?.first?.mediaAltText == "Descrizione")
        #expect(full.postAttributes.postLocation?.displayName == "Helsinki, Finlandia")
    }
}
