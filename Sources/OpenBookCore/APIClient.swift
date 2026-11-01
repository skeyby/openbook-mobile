import Foundation

// Credential-bearing calls never follow redirects to another destination.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct APIClient: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func register(instance: Instance) async throws -> Registration {
        var request = URLRequest(url: instance.url("/oauth/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "OpenBook Mobile", "redirect_uris": [OAuth.redirectURI],
            "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"], "scope": "api"
        ])
        return try await decode(request).0
    }

    public func token(instance: Instance, fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: instance.url("/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuth.form(fields)
        return try await decode(request, tokenExchange: true).0
    }

    public func instanceMetadata(credentials: Credentials) async throws -> InstanceMetadata {
        // No stored representation or conditional header: request a fresh 200 response.
        try await decode(authorizedRequest(path: "/rest/v1/instance", credentials: credentials)).0
    }

    public func me(credentials: Credentials) async throws -> Me {
        try await decode(authorizedRequest(path: "/rest/v1/me", credentials: credentials)).0
    }

    public func posts(engine: PostEngine = .timeline, nextPage: URL? = nil, credentials: Credentials) async throws -> PostsPage {
        try await posts(source: .feed(engine), nextPage: nextPage, credentials: credentials)
    }

    public func posts(source: PostSource, nextPage: URL? = nil, credentials: Credentials) async throws -> PostsPage {
        try source.validate()
        var request: URLRequest
        if let nextPage {
            try validatePostPage(nextPage, source: source, instance: credentials.instance)
            request = URLRequest(url: nextPage)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request = authorizedRequest(path: source.path, query: source.query, credentials: credentials)
        }
        let (posts, response): ([Post], HTTPURLResponse) = try await decode(request)
        var next: URL?
        if !posts.isEmpty, let header = response.value(forHTTPHeaderField: "Link") {
            let expression = try NSRegularExpression(pattern: #"<([^>]+)>([^<]*)"#)
            let ns = header as NSString
            for match in expression.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
                let parameters = ns.substring(with: match.range(at: 2))
                guard parameters.range(of: #"rel\s*=\s*(?:"next"|next)(?:\s|;|,|$)"#, options: .regularExpression) != nil else { continue }
                guard let url = URL(string: ns.substring(with: match.range(at: 1)), relativeTo: request.url)?.absoluteURL else {
                    throw OpenBookError.message("Il link della pagina successiva non è valido.")
                }
                try validatePostPage(url, source: source, instance: credentials.instance)
                next = url
                break
            }
        }
        return PostsPage(posts: posts, nextPage: next)
    }

    private func validatePostPage(_ url: URL, source: PostSource, instance: Instance) throws {
        let origin = instance.origin
        let defaultPort = origin.scheme == "https" ? 443 : 80
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        var valid = url.scheme == origin.scheme && url.host == origin.host &&
            (url.port ?? defaultPort) == (origin.port ?? defaultPort) &&
            url.user == nil && url.password == nil && url.fragment == nil && url.path == source.path &&
            Set(items.map(\.name)).count == items.count &&
            (query["sort"] ?? source.sort) == source.sort && (query["direction"] ?? "desc") == "desc" &&
            query["after"].flatMap(UUID.init(uuidString:)) != nil
        switch source {
        case .feed(let engine):
            valid = valid && (query["engine"] ?? "world") == engine.rawValue &&
                (engine == .timeline ? !(query["afterAt"] ?? "").isEmpty : query["afterAt"] == nil)
        case .mine:
            valid = valid && Set(query.keys).isSubset(of: ["after", "limit", "sort", "direction"])
        case .person:
            valid = valid && !(query["afterAt"] ?? "").isEmpty &&
                Set(query.keys).isSubset(of: ["after", "afterAt", "sort", "direction"])
        }
        guard valid else {
            throw OpenBookError.message("La pagina successiva non appartiene alla sorgente selezionata. Aggiorna il feed.")
        }
    }

    public func createPost(_ draft: NewPost, credentials: Credentials) async throws -> PostCreation {
        var request = authorizedRequest(path: "/rest/v1/posts", credentials: credentials)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(draft)
        do {
            let (data, response) = try await response(request)
            guard response.statusCode == 201 else {
                throw PostCreationError.uncertain("Risposta inattesa dal server.")
            }
            return PostCreation(post: try? JSONDecoder().decode(Post.self, from: data))
        } catch let error as OpenBookError {
            if case .http(let status, _) = error, (400..<500).contains(status) { throw error }
            throw PostCreationError.uncertain(error.localizedDescription)
        } catch let error as PostCreationError { throw error }
        catch { throw PostCreationError.uncertain(error.localizedDescription) }
    }

    public func post(id: String, credentials: Credentials) async throws -> Post {
        try await decode(postRequest(id: id, credentials: credentials)).0
    }

    public func editPost(id: String, patch: PatchPost, credentials: Credentials) async throws -> Post {
        var request = try postRequest(id: id, credentials: credentials)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(patch)
        return try await decode(request).0
    }

    public func deletePost(id: String, credentials: Credentials) async throws {
        var request = try postRequest(id: id, credentials: credentials)
        request.httpMethod = "DELETE"
        let (_, response) = try await response(request)
        guard response.statusCode == 204 else {
            throw OpenBookError.message("Risposta inattesa alla cancellazione del post. Aggiorna la timeline prima di riprovare.")
        }
    }

    public func setLike(postID: String, liked: Bool, credentials: Credentials) async throws {
        var request = try postRequest(id: postID, suffix: "/like", credentials: credentials)
        request.httpMethod = liked ? "PUT" : "DELETE"
        let (_, response) = try await response(request)
        guard liked ? [201, 204].contains(response.statusCode) : response.statusCode == 204 else {
            throw OpenBookError.message("Risposta inattesa all’aggiornamento del Mi piace.")
        }
    }

    public func setAnnounce(postID: String, announced: Bool, credentials: Credentials) async throws {
        var request = try postRequest(id: postID, suffix: "/announce", credentials: credentials)
        request.httpMethod = announced ? "PUT" : "DELETE"
        let (_, response) = try await response(request)
        guard announced ? [201, 204].contains(response.statusCode) : response.statusCode == 204 else {
            throw OpenBookError.message("Risposta inattesa all’aggiornamento del rilancio. Aggiorna il post prima di riprovare.")
        }
    }

    private func postRequest(id: String, suffix: String = "", credentials: Credentials) throws -> URLRequest {
        guard UUID(uuidString: id) != nil else { throw OpenBookError.message("Identificativo del post non valido.") }
        return authorizedRequest(path: "/rest/v1/posts/\(id)\(suffix)", credentials: credentials)
    }

    public func follow(id: String, credentials: Credentials) async throws -> Follow {
        try await decode(personRequest(id: id, suffix: "/follow", credentials: credentials)).0
    }

    public func setFollow(id: String, following: Bool, credentials: Credentials) async throws -> Follow {
        var request = try personRequest(id: id, suffix: "/follow", credentials: credentials)
        request.httpMethod = following ? "PUT" : "DELETE"
        let (data, response) = try await response(request)
        if following {
            guard [200, 201].contains(response.statusCode) else {
                throw OpenBookError.message("Risposta inattesa alla richiesta di seguito.")
            }
            let value = try JSONDecoder().decode(Follow.self, from: data)
            guard value.status == .pending || value.status == .accepted else {
                throw OpenBookError.message("Stato della richiesta di seguito non riconosciuto.")
            }
            return value
        }
        guard response.statusCode == 204 else {
            throw OpenBookError.message("Risposta inattesa all’annullamento del segui.")
        }
        return Follow(followStatus: "none")
    }

    public func person(id: String, credentials: Credentials) async throws -> Person {
        try await decode(personRequest(id: id, credentials: credentials)).0
    }

    public func people(id: String, relationship: Relationship, after: String?, credentials: Credentials) async throws -> PeoplePage {
        var request = try personRequest(id: id, suffix: "/\(relationship.rawValue)", credentials: credentials)
        var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "limit", value: "20"), .init(name: "sort", value: "personId"), .init(name: "direction", value: "asc")]
        if let after { parts.queryItems?.append(.init(name: "after", value: after)) }
        request.url = parts.url
        let (people, response): ([PersonReference], HTTPURLResponse) = try await decode(request)
        // Only use the server's pagination signal; reconstruct the cursor URL locally.
        return PeoplePage(people: people, hasNext: hasNextPage(response) && !people.isEmpty)
    }

    public func followRequests(after: String? = nil, credentials: Credentials) async throws -> PeoplePage {
        if let after, UUID(uuidString: after) == nil { throw OpenBookError.message("Cursore persona non valido.") }
        var query = [URLQueryItem(name: "limit", value: "20"), .init(name: "sort", value: "personId"), .init(name: "direction", value: "asc")]
        if let after { query.append(.init(name: "after", value: after)) }
        let (people, response): ([PersonReference], HTTPURLResponse) = try await decode(
            authorizedRequest(path: "/rest/v1/me/follow-requests", query: query, credentials: credentials))
        return PeoplePage(people: people, hasNext: hasNextPage(response) && !people.isEmpty)
    }

    public func decideFollowRequest(personID: String, accept: Bool, credentials: Credentials) async throws {
        guard UUID(uuidString: personID) != nil else { throw OpenBookError.message("Identificativo persona non valido.") }
        var request = authorizedRequest(path: "/rest/v1/me/follow-requests/\(personID.lowercased())", credentials: credentials)
        request.httpMethod = accept ? "PATCH" : "DELETE"
        if accept {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["followStatus": "accepted"])
        }
        let (_, response) = try await response(request)
        guard response.statusCode == 204 else {
            throw OpenBookError.message("Risposta inattesa alla gestione della richiesta di follow.")
        }
    }

    private func hasNextPage(_ response: HTTPURLResponse) -> Bool {
        let link = response.value(forHTTPHeaderField: "Link") ?? ""
        return link.range(of: #"rel\s*=\s*(?:"next"|next)(?:\s|;|,|$)"#, options: .regularExpression) != nil
    }

    private func authorizedRequest(path: String, query: [URLQueryItem] = [], credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: credentials.instance.url(path, query: query))
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func personRequest(id: String, suffix: String = "", credentials: Credentials) throws -> URLRequest {
        guard UUID(uuidString: id) != nil else { throw OpenBookError.message("Inserisci un identificativo persona UUID valido.") }
        return authorizedRequest(path: "/rest/v1/persons/\(id)\(suffix)", credentials: credentials)
    }

    private func decode<T: Decodable>(_ input: URLRequest, tokenExchange: Bool = false) async throws -> (T, HTTPURLResponse) {
        let (data, response) = try await response(input, tokenExchange: tokenExchange)
        do { return (try JSONDecoder().decode(T.self, from: data), response) }
        catch { throw OpenBookError.message("La risposta non corrisponde al formato API atteso. La specifica potrebbe essere cambiata.") }
    }

    private func response(_ input: URLRequest, tokenExchange: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var request = input
        request.setValue("application/json, application/problem+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw OpenBookError.message("Risposta del server non valida.") }
        guard (200..<300).contains(response.statusCode) else {
            let problem = try? JSONDecoder().decode(Problem.self, from: data)
            if tokenExchange, [400, 401].contains(response.statusCode) {
                switch problem?.error {
                case "invalid_grant": throw OAuthTokenError.invalidGrant
                case "invalid_client": throw OAuthTokenError.invalidClient
                case "unauthorized_client": throw OAuthTokenError.unauthorizedClient
                default:
                    if response.statusCode == 401 { throw OAuthTokenError.authenticationRejected }
                }
            }
            let fallback: String
            switch response.statusCode {
            case 401: fallback = "Sessione scaduta o revocata. Accedi nuovamente."
            case 403: fallback = "L’account non può accedere a questa risorsa."
            case 404: fallback = "Risorsa non trovata o non disponibile."
            case 429: fallback = "Troppe richieste. Riprova più tardi."
            case 503: fallback = "API temporaneamente non disponibili."
            case 300..<400: fallback = "Il server richiede un reindirizzamento. Controlla l’indirizzo dell’istanza."
            default: fallback = "Impossibile completare la richiesta."
            }
            // OAuth errors may contain sensitive values: show only controlled messages for them.
            let validation = response.statusCode == 422 ? problem?.errors?.sorted(by: { $0.key < $1.key }).flatMap(\.value).joined(separator: "\n") : nil
            let message = (response.statusCode == 401 || problem?.error != nil) ? fallback : (problem?.detail ?? validation.flatMap { $0.isEmpty ? nil : $0 } ?? problem?.title ?? fallback)
            throw OpenBookError.http(response.statusCode, message)
        }
        return (data, response)
    }
}

private struct Problem: Decodable {
    let title: String?
    let detail: String?
    let error: String?
    let errors: [String: [String]]?
}
