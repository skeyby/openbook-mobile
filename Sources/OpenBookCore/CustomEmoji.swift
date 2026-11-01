import Foundation

public enum CustomEmoji {
    public enum Part: Hashable, Sendable {
        case text(String)
        case image(shortcode: String, url: URL)
    }

    public enum RichPart: Hashable, Sendable {
        case text(AttributedString)
        case image(placeholder: AttributedString, url: URL)
    }

    /// Enrich already-parsed Markdown without flattening its attributes. Code and links
    /// stay literal, including linked Markdown image alt text: no new implicit image load.
    public static func parts(in text: AttributedString, emojis: [String: URL]?) -> [RichPart] {
        var result: [RichPart] = []
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true || run.link != nil {
                result.append(.text(AttributedString(text[run.range])))
                continue
            }
            for part in parts(in: String(text[run.range].characters), emojis: emojis) {
                switch part {
                case .text(let value): result.append(.text(AttributedString(value, attributes: run.attributes)))
                case .image(let code, let url):
                    result.append(.image(placeholder: AttributedString(code, attributes: run.attributes), url: url))
                }
            }
        }
        return result
    }

    public static func imageURLs(in parts: [RichPart], limit: Int = 32) -> [URL] {
        let images: [Part] = parts.compactMap {
            if case .image(let placeholder, let url) = $0 {
                return .image(shortcode: String(placeholder.characters), url: url)
            }
            return nil
        }
        return imageURLs(in: images, limit: limit)
    }

    /// Only exact, case-sensitive shortcodes present in the supplied map are images.
    public static func parts(in text: String, emojis: [String: URL]?) -> [Part] {
        guard !text.isEmpty else { return [] }
        var urls: [String: URL] = [:]
        for (name, url) in emojis ?? [:] {
            guard !name.isEmpty, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { continue }
            let code = name.hasPrefix(":") && name.hasSuffix(":") ? name : ":\(name):"
            if urls[code] == nil || name == code { urls[code] = url }
        }
        guard !urls.isEmpty else { return [.text(text)] }
        var result: [Part] = []
        var literalStart = text.startIndex
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let start = text[searchStart...].firstIndex(of: ":") {
            let afterStart = text.index(after: start)
            guard afterStart < text.endIndex, let end = text[afterStart...].firstIndex(of: ":") else { break }
            let afterEnd = text.index(after: end)
            let code = String(text[start..<afterEnd])
            if let url = urls[code] {
                if literalStart < start { result.append(.text(String(text[literalStart..<start]))) }
                result.append(.image(shortcode: code, url: url))
                literalStart = afterEnd
                searchStart = afterEnd
            } else {
                // Reconsider the closing colon: it may start a known code after an unknown one.
                searchStart = afterStart
            }
        }
        if literalStart < text.endIndex { result.append(.text(String(text[literalStart...]))) }
        return result
    }

    /// Preserve text order, deduplicate downloads and bound the work for untrusted profiles.
    public static func imageURLs(in parts: [Part], limit: Int = 32) -> [URL] {
        var seen: Set<URL> = []
        var result: [URL] = []
        for case .image(_, let url) in parts where result.count < max(0, limit) {
            if seen.insert(url).inserted { result.append(url) }
        }
        return result
    }
}
