import Foundation

public enum PostEngine: String, CaseIterable, Identifiable, Sendable {
    case timeline, world
    public var id: String { rawValue }
    public var title: String { self == .timeline ? "Timeline" : "Mondo" }
    public var summary: String {
        self == .timeline ? "I post della tua timeline" : "Post pubblici remoti presenti nell’istanza"
    }
    public var sort: String { self == .timeline ? "postTimelineAt" : "postPublishedAt" }
}

public struct Me: Decodable, Sendable {
    public let myPerson: Person
}

public struct Post: Decodable, Identifiable, Sendable {
    public var id: String { postId }
    public let postId: String
    public let postUri: URL
    public let postAuthor: PersonReference
    public let postName: String?
    public let postContent: String
    public let postCW: Bool
    public let postCWText: String?
    public let postLanguage: String?
    public let postVisibility: String
    public let postPublishedAt: String
    public private(set) var postTimelineAt: String?
    public private(set) var postAnnounce: Announce?
    public let postEditedAt: String?
    public let postSourceUri: String?
    public let postCustomEmojis: [String: URL]?
    public let postAttachments: [Media]?
    public let postAttributes: Attributes
    public let postCounters: Counters
    public let postMyInteractions: Interactions

    public struct Announce: Decodable, Sendable {
        public let announceAuthor: PersonReference
        public let announcePublishedAt: String
    }
    public struct Attributes: Decodable, Sendable {
        public let postLocation: Location?
    }
    public struct Counters: Decodable, Sendable {
        public let postLikesCount: Int
        public let postCommentsCount: Int
        public let postAnnouncesCount: Int
    }
    public struct Interactions: Decodable, Sendable {
        public let postLiked: Bool
        public let postAnnounced: Bool
        public let postDirectAnnounced: Bool
    }
    public func isOwned(by personID: String?) -> Bool {
        guard let personID else { return false }
        return postAuthor.personId.lowercased() == personID.lowercased()
    }
    public var supportsBasicEditing: Bool {
        PostVisibility(rawValue: postVisibility) != nil && (postAttachments?.isEmpty ?? true) && postAttributes.postLocation == nil
    }
    public func preservingFeedContext(of original: Post) -> Post {
        var copy = self
        copy.postTimelineAt = original.postTimelineAt
        copy.postAnnounce = original.postAnnounce
        return copy
    }

    public var publishedDate: Date? {
        PostTimestamp.date(from: postPublishedAt)
    }
}

public struct Media: Decodable, Identifiable, Sendable {
    public var id: String { mediaId }
    public let mediaId: String
    public let mediaUrl: URL
    public let mediaPreviewUrl: URL
    public let mediaMimeType: String
    public let mediaWidth: Int?
    public let mediaHeight: Int?
    public let mediaAltText: String?
}

public struct Location: Decodable, Sendable {
    public let locationName: String?
    public let locationRegion: String?
    public let locationCountryCode: String?
    public let locationCountryName: String?
    public let locationLatitude: Double?
    public let locationLongitude: Double?
    public var displayName: String {
        [locationName, locationRegion, locationCountryName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

public struct PostsPage: Sendable {
    public let posts: [Post]
    public let nextPage: URL?
    public var hasNext: Bool { nextPage != nil }

    public init(posts: [Post], nextPage: URL?) {
        self.posts = posts
        self.nextPage = nextPage
    }
}

/// Keeps server ordering, without rebuilding the engine-specific pagination boundary.
public struct PostTimeline: Sendable {
    public private(set) var posts: [Post] = []
    public private(set) var nextPage: URL?
    public private(set) var hasLoaded = false
    public var hasNext: Bool { nextPage != nil }
    private var seenPages: Set<URL> = []

    public init() { }

    public mutating func apply(_ page: PostsPage, replacing: Bool) {
        if replacing { posts = []; seenPages = [] }
        var seen = Set(posts.map(\.id))
        posts.append(contentsOf: page.posts.filter { seen.insert($0.id).inserted })
        if !page.posts.isEmpty, let next = page.nextPage, seenPages.insert(next).inserted {
            nextPage = next
        } else { nextPage = nil }
        hasLoaded = true
    }

    public mutating func clear() { self = PostTimeline() }
}
