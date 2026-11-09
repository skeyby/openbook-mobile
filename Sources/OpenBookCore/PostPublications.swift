import Foundation
import Observation

public struct PostPublication: Decodable, Sendable {
    public enum Status: String, Sendable { case pending, processing, failed, published }
    public let postPublicationId: String
    public let postPublicationStatus: String
    public let postId: String?
    public var status: Status? { Status(rawValue: postPublicationStatus) }
}

/// Accepted submissions live on the server. This store only monitors them within the session.
@MainActor @Observable
public final class PostPublications {
    public struct Job: Identifiable, Sendable {
        public let id: String
        public var value: PostPublication?
    }
    public private(set) var jobs: [Job] = []
    public private(set) var pending: Set<String> = []
    public private(set) var errors: [String: String] = [:]
    public private(set) var requiresReload: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let api: APIClient
    public init(api: APIClient = APIClient()) { self.api = api }
    public func reset() { generation += 1; jobs = []; pending = []; errors = [:]; requiresReload = [] }
    public func register(_ creation: PostCreation) {
        guard creation.wasDeferred, let id = creation.monitorID, !jobs.contains(where: { $0.id == id }) else { return }
        jobs.append(Job(id: id, value: creation.deferredPublication))
    }
    public var pollingIDs: [String] {
        jobs.filter { errors[$0.id] == nil && ($0.value == nil || $0.value?.status == .pending || $0.value?.status == .processing) }.map(\.id)
    }
    public func canCancel(_ job: Job) -> Bool {
        !pending.contains(job.id) && !requiresReload.contains(job.id) && (job.value?.status == .pending || job.value?.status == .failed)
    }
    @discardableResult
    public func refresh(id: String, credentials: () async throws -> Credentials) async -> Bool {
        guard !pending.contains(id), jobs.contains(where: { $0.id == id }) else { return false }
        let session = generation
        pending.insert(id)
        defer { if session == generation { pending.remove(id) } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard session == generation else { return false }
            let value = try await api.postPublication(id: id, credentials: credentials)
            try Task.checkCancellation()
            guard session == generation, let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
            let justPublished = value.status == .published && jobs[index].value?.status != .published
            jobs[index].value = value; errors[id] = nil; requiresReload.remove(id)
            return justPublished
        } catch {
            guard session == generation, !Task.isCancelled else { return false }
            errors[id] = "\(error.localizedDescription) Puoi aggiornare lo stato senza inviare di nuovo il post."
            requiresReload.insert(id)
            return false
        }
    }
    public func cancel(id: String, credentials: () async throws -> Credentials) async {
        guard let job = jobs.first(where: { $0.id == id }), canCancel(job) else { return }
        let session = generation
        pending.insert(id)
        defer { if session == generation { pending.remove(id) } }
        do {
            let credentials = try await credentials()
            try Task.checkCancellation()
            guard session == generation else { return }
            try await api.cancelPostPublication(id: id, credentials: credentials)
            guard session == generation else { return }
            jobs.removeAll { $0.id == id }; errors[id] = nil; requiresReload.remove(id)
        } catch {
            guard session == generation else { return }
            errors[id] = "Annullamento non confermato. \(error.localizedDescription) Aggiorna lo stato prima di riprovare."
            requiresReload.insert(id)
        }
    }
    public func dismiss(id: String) {
        guard !pending.contains(id), let job = jobs.first(where: { $0.id == id }), job.value?.status == .published || errors[id] != nil else { return }
        jobs.removeAll { $0.id == id }; errors[id] = nil; requiresReload.remove(id)
    }
}
