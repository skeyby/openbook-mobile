import Foundation

/// Foundation parses Markdown; the app lays out its block-level presentation intents.
public struct PostMarkdown: Sendable {
    public struct Block: Identifiable, Sendable {
        public enum Kind: Equatable, Sendable {
            case paragraph, heading(Int), code, rule
        }
        public let id: Int
        public let kind: Kind
        public let text: AttributedString
        public let listDepth: Int
        public let listMarker: String?
        public let isQuote: Bool
    }

    public let blocks: [Block]

    public init(_ source: String, baseURL: URL? = nil) {
        let parsed = (try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        ), baseURL: baseURL)) ?? AttributedString(source)
        var blocks: [Block] = []
        var seenItems: Set<Int> = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            let kind: Block.Kind
            switch components.first?.kind {
            case .header(let level): kind = .heading(level)
            case .codeBlock: kind = .code
            case .thematicBreak: kind = .rule
            default: kind = .paragraph
            }
            var marker: String?
            let depth = components.filter {
                switch $0.kind { case .orderedList, .unorderedList: return true; default: return false }
            }.count
            if let index = components.firstIndex(where: {
                if case .listItem = $0.kind { return true }; return false
            }), case .listItem(let ordinal) = components[index].kind,
               seenItems.insert(components[index].identity).inserted {
                let ordered = components.dropFirst(index + 1).first?.kind == .orderedList
                marker = ordered ? "\(ordinal)." : "•"
            }
            var text = AttributedString(parsed[range])
            // Keep social-post line breaks, including CommonMark soft breaks.
            for run in Array(text.runs).reversed() where run.inlinePresentationIntent?.contains(.softBreak) == true {
                text.replaceSubrange(run.range, with: AttributedString("\n"))
            }
            for run in Array(text.runs) {
                if let link = run.link {
                    // The automatic email detector also matches the tail of @user@domain.
                    // Keep Fediverse mentions as text instead of opening a mail composer.
                    let followsAt = run.range.lowerBound != text.startIndex &&
                        text.characters[text.characters.index(before: run.range.lowerBound)] == "@"
                    if !Self.allows(link) || (link.scheme?.lowercased() == "mailto" && followsAt) {
                        text[run.range].link = nil
                    }
                }
                // Markdown images keep readable alt text and an explicit link. Attachments
                // remain the app's image presentation; parsing never fetches remote content.
                if let image = run.imageURL {
                    if kind != .code && Self.allows(image) && text[run.range].link == nil {
                        text[run.range].link = image
                    }
                    text[run.range].imageURL = nil
                }
            }
            text.presentationIntent = nil
            blocks.append(Block(id: blocks.count, kind: kind, text: text, listDepth: depth,
                                listMarker: marker, isQuote: components.contains { $0.kind == .blockQuote }))
        }
        self.blocks = blocks
    }

    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "https", "http": return url.host != nil && url.user == nil && url.password == nil
        case "mailto": return URLComponents(string: url.absoluteString)?.path.isEmpty == false
        default: return false
        }
    }
}
