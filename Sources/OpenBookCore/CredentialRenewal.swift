import Foundation

/// Controlled errors only: never retain an OAuth error_description or raw response.
public enum OAuthTokenError: Error, LocalizedError, Sendable {
    case invalidGrant, invalidClient, unauthorizedClient, authenticationRejected, reauthenticationRequired

    public var errorDescription: String? {
        "Sessione scaduta o non più valida. Scollega l’istanza e accedi nuovamente."
    }
}

/// Serializes refresh and prevents terminal failures or stale tasks from reusing a session.
@MainActor
public final class CredentialRenewal {
    public private(set) var requiresReauthentication = false
    private var generation = 0
    private var active: (id: UUID, task: Task<Credentials, Error>)?

    public init() { }

    public func reset() {
        generation += 1
        active?.task.cancel()
        active = nil
        requiresReauthentication = false
    }

    public func authorized(current: Credentials, now: Date = Date(),
                           refresh: @escaping @MainActor (Credentials) async throws -> Credentials,
                           save: @escaping @MainActor (Credentials) throws -> Void,
                           invalidate: @escaping @MainActor (OAuthTokenError) throws -> Void) async throws -> Credentials {
        guard !requiresReauthentication else { throw OAuthTokenError.reauthenticationRequired }
        if current.expiresAt > now.addingTimeInterval(60) { return current }
        if let active { return try await active.task.value }
        guard current.refreshToken != nil else {
            requiresReauthentication = true
            try invalidate(.reauthenticationRequired)
            throw OAuthTokenError.reauthenticationRequired
        }
        let session = generation
        let id = UUID()
        let task = Task {
            do {
                let renewed = try await refresh(current)
                try Task.checkCancellation()
                guard session == self.generation else { throw CancellationError() }
                try save(renewed)
                return renewed
            } catch {
                guard session == self.generation else { throw CancellationError() }
                if let reason = error as? OAuthTokenError {
                    // Latch before storage work, even if Keychain removal itself fails.
                    self.requiresReauthentication = true
                    try invalidate(reason)
                }
                throw error
            }
        }
        active = (id, task)
        defer { if active?.id == id { active = nil } }
        return try await task.value
    }
}
