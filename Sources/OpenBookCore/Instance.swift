import Foundation

public struct Instance: Codable, Hashable, Sendable {
    public let origin: URL

    public init(_ input: String) throws {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw OpenBookError.message("Inserisci l’indirizzo dell’istanza, per esempio https://social.example.org, senza percorsi.")
        }
        let scheme = parts.scheme?.lowercased()
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw OpenBookError.message("Usa HTTPS. HTTP è consentito solo su localhost per lo sviluppo.")
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        guard let url = parts.url else { throw OpenBookError.message("Indirizzo non valido.") }
        origin = url
    }

    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url!
    }
}

public enum OpenBookError: LocalizedError, Sendable {
    case message(String)
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(let status, let text): return "\(text) (HTTP \(status))"
        }
    }
}
