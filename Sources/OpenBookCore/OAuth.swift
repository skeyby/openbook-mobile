import CryptoKit
import Foundation
import Security

public enum OAuth {
    public static let callbackScheme = "it.brancatelli.openbook.mobile"
    public static let redirectURI = "it.brancatelli.openbook.mobile://oauth/callback"

    public static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OpenBookError.message("Impossibile generare i dati di sicurezza per l’accesso.")
        }
        return base64URL(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func authorizationURL(instance: Instance, clientID: String, verifier: String, state: String) -> URL {
        instance.url("/oauth/authorize", query: [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: "api"),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256")
        ])
    }

    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard callback.scheme == callbackScheme, callback.host == "oauth", callback.path == "/callback",
              callback.user == nil, callback.password == nil, callback.port == nil, callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw OpenBookError.message("Risposta di accesso non valida. Riprova a collegare l’istanza.")
        }
        if items.contains(where: { $0.name == "error" }) {
            throw OpenBookError.message("Accesso non autorizzato.")
        }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OpenBookError.message("Il server non ha restituito il codice di accesso.")
        }
        return code
    }

    public static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}
