import Foundation
import Observation

public enum FollowStatus: String, Sendable { case none, pending, accepted }

public struct Follow: Decodable, Sendable {
    public let followStatus: String
    public var status: FollowStatus? { FollowStatus(rawValue: followStatus) }
}

/// Outgoing relationships only; shared across profile views in the current session.
@MainActor @Observable
public final class PersonFollows {
    public private(set) var states: [String: Follow] = [:]
    public private(set) var pending: Set<String> = []
    public private(set) var errors: [String: String] = [:]
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var generation = 0

    public init(api: APIClient = APIClient()) { self.api = api }

    public func reset() {
        generation += 1
        states = [:]; pending = []; errors = [:]
    }

    public func load(personID: String, credentials: () async throws -> Credentials) async {
        let id = personID.lowercased()
        guard !pending.contains(id) else { return }
        let session = generation
        pending.insert(id); errors[id] = nil
        defer { if session == generation { pending.remove(id) } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard session == generation else { return }
            let value = try await api.follow(id: id, credentials: credentials)
            try Task.checkCancellation()
            guard session == generation else { return }
            states[id] = value
        } catch {
            guard session == generation else { return }
            states[id] = nil
            if !Task.isCancelled { errors[id] = error.localizedDescription }
        }
    }

    @discardableResult
    public func toggle(personID: String, currentPersonID: String?, credentials: () async throws -> Credentials) async -> Bool {
        let id = personID.lowercased()
        guard let currentPersonID, id != currentPersonID.lowercased(), !pending.contains(id),
              let status = states[id]?.status else { return false }
        let session = generation
        pending.insert(id); errors[id] = nil
        defer { if session == generation { pending.remove(id) } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard session == generation else { return false }
            let value = try await api.setFollow(id: id, following: status == .none, credentials: credentials)
            guard session == generation else { return false }
            states[id] = value
            return true
        } catch {
            guard session == generation else { return false }
            // Reconcile with GET before allowing another write, especially a pending remote PUT.
            states[id] = nil
            errors[id] = "\(error.localizedDescription) Aggiorna lo stato prima di riprovare."
            return false
        }
    }
}
