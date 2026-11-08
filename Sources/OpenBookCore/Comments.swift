import Foundation

public struct Comment: Decodable, Identifiable, Sendable {
    public var id: String { commentId }
    public let commentId: String
    public let commentUri: URL
    public let commentPostId: String
    public let commentParentId: String?
    public let commentAuthor: PersonReference
    public let commentContent: String
    public let commentPublishedAt: String
    public let commentEditedAt: String?
    public let commentLanguage: String?
    public let commentCustomEmojis: [String: URL]?
    public let commentAttachments: [Media]?
    public let commentCounters: Counters
    public let commentMyInteractions: Interactions

    public struct Counters: Decodable, Sendable {
        public let commentLikesCount: Int
        public let commentRepliesCount: Int
    }
    public struct Interactions: Decodable, Sendable { public let commentLiked: Bool }
    public func isOwned(by personID: String?) -> Bool {
        guard let personID else { return false }
        return commentAuthor.personId.lowercased() == personID.lowercased()
    }
    public var publishedDate: Date? { PostTimestamp.date(from: commentPublishedAt) }
}

public struct NewComment: Encodable, Sendable {
    public let commentContent: String
    public let commentParentId: String?
    public init(content: String, parentID: String? = nil) throws {
        try Self.validate(content)
        if let parentID, UUID(uuidString: parentID) == nil { throw OpenBookError.message("Identificativo del commento padre non valido.") }
        commentContent = content
        commentParentId = parentID?.lowercased()
    }
    static func validate(_ content: String) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenBookError.message("Scrivi il testo del commento.")
        }
    }
}

public struct PatchComment: Encodable, Sendable {
    public let commentContent: String
    public init(content: String) throws { try NewComment.validate(content); commentContent = content }
}

public struct CommentsPage: Sendable {
    public let comments: [Comment]
    public let nextPage: URL?
}

public struct CommentCreation: Sendable {
    /// 201 is a success even when the representation is unreadable. Never invite a replay.
    public let comment: Comment?
}

public enum CommentCreationError: LocalizedError, Sendable {
    case uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .uncertain(let detail):
            "Pubblicazione non confermata. Il commento potrebbe essere già stato creato: controlla i commenti prima di riprovare. \(detail)"
        }
    }
}

/// A presentation projection over loaded pages; it never changes API cursors.
/// Roots and siblings keep server order. Missing parents and cycles cannot hide replies.
public enum CommentThread {
    public struct Row: Identifiable, Sendable {
        public var id: String { comment.id.lowercased() }
        public let comment: Comment
        public let depth: Int
        public let parentUnavailable: Bool
    }

    public static func rows(in comments: [Comment]) -> [Row] {
        var nodes: [String: Comment] = [:]
        var order: [String] = []
        for comment in comments {
            let id = comment.id.lowercased()
            if nodes[id] == nil { nodes[id] = comment; order.append(id) }
        }
        var children: [String: [String]] = [:]
        var roots: [(String, Int, Bool)] = []
        for id in order {
            guard let comment = nodes[id] else { continue }
            if let parent = comment.commentParentId?.lowercased() {
                if parent != id && nodes[parent] != nil { children[parent, default: []].append(id) }
                else { roots.append((id, 1, true)) }
            } else { roots.append((id, 0, false)) }
        }
        var result: [Row] = []
        var visited: Set<String> = []
        func appendThread(_ root: (String, Int, Bool)) {
            var stack = [root]
            while let (id, depth, unavailable) = stack.popLast() {
                guard visited.insert(id).inserted, let comment = nodes[id] else { continue }
                result.append(Row(comment: comment, depth: depth, parentUnavailable: unavailable))
                for child in (children[id] ?? []).reversed() { stack.append((child, depth + 1, false)) }
            }
        }
        for root in roots { appendThread(root) }
        // Malformed cyclic components have no root; break them deterministically.
        for id in order where !visited.contains(id) { appendThread((id, 1, true)) }
        return result
    }
}
