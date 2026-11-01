import Foundation

/// Display metadata only: these URLs never replace the authenticated API origin.
public struct InstanceMetadata: Decodable, Sendable {
    public let instanceName: String
    public let instanceDomain: String
    public let instanceUrl: URL
    public let instanceDescription: String
    public let instanceIcon: URL?

    public var displayName: String? {
        let name = instanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

public struct Person: Decodable, Identifiable, Sendable {
    public var id: String { personId }
    public let personId: String
    public let personUri: URL
    public let personType: String
    public let personUsername: String
    public let personDomain: String
    public let personStatus: String
    public let personPublishedAt: String?
    public let personProfile: Profile
    public let personAttributes: Attributes
    public let personFollowersCount: Int?
    public let personFollowingCount: Int?
    public let personRoles: [String]?
    public var handle: String { "@\(personUsername)@\(personDomain)" }

    public struct Profile: Decodable, Sendable {
        public let personName: String
        public let personSummary: String?
        public let personAvatar: URL?
        public let personCoverImage: URL?
        public let personFields: [Field]?
    }
    public struct Field: Decodable, Sendable {
        public let label: String
        public let value: String
    }
    public struct Attributes: Decodable, Sendable {
        public let personDiscoverable: Bool
        public let personIndexable: Bool
        public let personFollowApproval: Bool
        public let personMemorial: Bool
        public let personSuspended: Bool
        public let personCustomEmojis: [String: URL]?
        public let personAlsoKnownAs: [URL]?
        public let personMovedTo: Destination?
    }
    public struct Destination: Decodable, Sendable {
        public let personId: String
        public let personUri: URL
    }
}

public struct PersonReference: Decodable, Identifiable, Sendable {
    public var id: String { personId }
    public let personId: String
    public let personUsername: String
    public let personDomain: String
    public let personName: String
    public let personAvatar: URL?
    public var handle: String { "@\(personUsername)@\(personDomain)" }
}

public struct Registration: Decodable, Sendable {
    public let client_id: String
}

public struct TokenResponse: Decodable, Sendable {
    public let access_token: String
    public let token_type: String
    public let expires_in: Int
    public let refresh_token: String?
}

public struct Credentials: Codable, Sendable {
    public let instance: Instance
    public let clientID: String
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public init(instance: Instance, clientID: String, token: TokenResponse, previousRefreshToken: String? = nil) throws {
        guard token.token_type.lowercased() == "bearer", !token.access_token.isEmpty, token.expires_in > 0 else {
            throw OpenBookError.message("Risposta OAuth non valida.")
        }
        self.instance = instance
        self.clientID = clientID
        accessToken = token.access_token
        refreshToken = token.refresh_token ?? previousRefreshToken
        expiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in))
    }
}

public enum Relationship: String, CaseIterable, Hashable, Sendable {
    case followers, following
    public var title: String { self == .followers ? "Follower" : "Seguiti" }
}

public struct PeoplePage: Sendable {
    public let people: [PersonReference]
    public let hasNext: Bool
}
