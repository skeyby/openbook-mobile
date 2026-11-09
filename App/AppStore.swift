import AuthenticationServices
import Combine
import Foundation
import OpenBookCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var credentials: Credentials?
    @Published private(set) var isConnecting = false
    @Published private(set) var requiresReauthentication = false
    @Published var errorMessage: String?
    let api = APIClient()
    let likes = PostLikes()
    let announces = PostAnnounces()
    let management = PostManagement()
    let comments = CommentManagement()
    let publications = PostPublications()
    let follows = PersonFollows()
    let incomingFollowRequests = IncomingFollowRequests()
    @Published private(set) var currentPersonID: String?
    @Published private(set) var identityError: String?
    @Published private(set) var instanceMetadata: InstanceMetadata?
    @Published private(set) var instanceMetadataError: String?
    private var instanceMetadataRevision = 0
    private var isLoadingInstance = false
    private var sessionGeneration = 0
    var sessionRevision: Int { sessionGeneration }
    private let keychain = KeychainStore()
    private let browser = BrowserAuthentication()
    private let renewal = CredentialRenewal()

    init() {
        do { credentials = try keychain.load() }
        catch { errorMessage = error.localizedDescription }
    }

    func connect(to input: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let instance = try Instance(input)
            let key = "oauth.client.\(instance.origin.absoluteString)"
            let clientID: String
            if let stored = UserDefaults.standard.string(forKey: key) { clientID = stored }
            else {
                clientID = try await api.register(instance: instance).client_id
                guard !clientID.isEmpty else { throw OpenBookError.message("Registrazione client non valida.") }
                UserDefaults.standard.set(clientID, forKey: key)
            }
            let verifier = try OAuth.randomValue()
            let state = try OAuth.randomValue()
            let callback = try await browser.authenticate(url: OAuth.authorizationURL(instance: instance, clientID: clientID, verifier: verifier, state: state))
            let code = try OAuth.authorizationCode(from: callback, expectedState: state)
            let token = try await api.token(instance: instance, fields: [
                "grant_type": "authorization_code", "client_id": clientID, "redirect_uri": OAuth.redirectURI,
                "code": code, "code_verifier": verifier
            ])
            let credentials = try Credentials(instance: instance, clientID: clientID, token: token)
            try keychain.save(credentials)
            renewal.reset()
            requiresReauthentication = false
            likes.reset()
            announces.reset()
            management.reset()
            comments.reset()
            publications.reset()
            follows.reset()
            incomingFollowRequests.reset()
            sessionGeneration += 1
            instanceMetadata = nil
            instanceMetadataError = nil
            isLoadingInstance = false
            currentPersonID = nil
            identityError = nil
            self.credentials = credentials
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closing the browser is a normal cancellation.
        } catch { errorMessage = error.localizedDescription }
    }

    func disconnect() {
        do {
            try keychain.clear()
            renewal.reset()
            requiresReauthentication = false
            likes.reset()
            announces.reset()
            management.reset()
            comments.reset()
            publications.reset()
            follows.reset()
            incomingFollowRequests.reset()
            sessionGeneration += 1
            instanceMetadata = nil
            instanceMetadataError = nil
            isLoadingInstance = false
            currentPersonID = nil
            identityError = nil
            credentials = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func loadInstanceMetadata() async {
        guard !isLoadingInstance else { return }
        isLoadingInstance = true
        let generation = sessionGeneration
        defer { if generation == sessionGeneration { isLoadingInstance = false } }
        do { _ = try await fetchInstanceMetadata() }
        catch { /* The shared reader records current-session errors. */ }
    }

    func refreshUploadLimits() async throws -> InstanceUploadLimits? {
        do { return try await fetchInstanceMetadata().instanceUploadLimits }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw OpenBookError.message("Impossibile aggiornare i limiti degli allegati. Nessun file è stato inviato. \(error.localizedDescription)")
        }
    }

    /// A slower branding read must not replace a newer upload-policy response.
    private func fetchInstanceMetadata() async throws -> InstanceMetadata {
        let session = sessionGeneration
        instanceMetadataRevision += 1
        let revision = instanceMetadataRevision
        do {
            let auth = try await authorizedCredentials()
            try Task.checkCancellation()
            guard session == sessionGeneration, revision == instanceMetadataRevision else { throw CancellationError() }
            let metadata = try await api.instanceMetadata(credentials: auth)
            try Task.checkCancellation()
            guard session == sessionGeneration, revision == instanceMetadataRevision else { throw CancellationError() }
            instanceMetadata = metadata
            instanceMetadataError = nil
            return metadata
        } catch {
            if session == sessionGeneration, revision == instanceMetadataRevision, !Task.isCancelled,
               !(error is CancellationError) { instanceMetadataError = error.localizedDescription }
            throw error
        }
    }

    func loadCurrentPerson() async {
        guard currentPersonID == nil else { return }
        let generation = sessionGeneration
        do {
            let credentials = try await authorizedCredentials()
            let person = try await api.me(credentials: credentials).myPerson
            try Task.checkCancellation()
            guard generation == sessionGeneration else { return }
            currentPersonID = person.id
            identityError = nil
        } catch {
            if generation == sessionGeneration { identityError = error.localizedDescription }
        }
    }

    func authorizedCredentials() async throws -> Credentials {
        guard let current = credentials else { throw OpenBookError.message("Collega prima un’istanza.") }
        return try await renewal.authorized(current: current, refresh: { current in
            guard let refreshToken = current.refreshToken else { throw OAuthTokenError.reauthenticationRequired }
            let token = try await self.api.token(instance: current.instance, fields: [
                "grant_type": "refresh_token", "client_id": current.clientID, "refresh_token": refreshToken
            ])
            return try Credentials(instance: current.instance, clientID: current.clientID, token: token,
                                   previousRefreshToken: current.refreshToken)
        }, save: { renewed in
            try self.keychain.save(renewed)
            self.credentials = renewed
        }, invalidate: { reason in
            self.requiresReauthentication = true
            try self.keychain.clear()
            if case .invalidClient = reason {
                UserDefaults.standard.removeObject(forKey: "oauth.client.\(current.instance.origin.absoluteString)")
            }
        })
    }
}
