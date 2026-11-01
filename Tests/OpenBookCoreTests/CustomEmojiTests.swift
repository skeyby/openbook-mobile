import Foundation
import Testing
@testable import OpenBookCore

@Suite struct CustomEmojiTests {
    private let wave = URL(string: "https://example.org/emoji/wave.png")!
    private let flag = URL(string: "https://example.org/emoji/flag.gif")!

    @Test func profileNameRendersOnlyItsDeclaredCodes() {
        let parts = CustomEmoji.parts(in: "Jamie :h2dlaser: :h2c:", emojis: [":h2dlaser:": wave, ":h2c:": flag])
        #expect(parts == [.text("Jamie "), .image(shortcode: ":h2dlaser:", url: wave), .text(" "), .image(shortcode: ":h2c:", url: flag)])
        #expect(CustomEmoji.parts(in: "Jamie :unknown:", emojis: [":wave:": wave]) == [.text("Jamie :unknown:")])
    }

    @Test func preservesUnicodeNewlinesAndAdjacentCodes() {
        let parts = CustomEmoji.parts(in: "Ciao 👋\n:wave::旗:!", emojis: ["wave": wave, ":旗:": flag])
        #expect(parts == [.text("Ciao 👋\n"), .image(shortcode: ":wave:", url: wave), .image(shortcode: ":旗:", url: flag), .text("!")])
    }

    @Test func unknownCodesAndURLColonsDoNotConsumeTheNextEmoji() {
        let parts = CustomEmoji.parts(in: "https://example.org :unknown: :wave:", emojis: [":wave:": wave])
        #expect(parts == [.text("https://example.org :unknown: "), .image(shortcode: ":wave:", url: wave)])
        #expect(CustomEmoji.parts(in: ":Wave:", emojis: [":wave:": wave]) == [.text(":Wave:")])
    }

    @Test func rejectsNonWebURLsAndEmbeddedCredentials() {
        for raw in ["file:///tmp/emoji.png", "javascript:alert(1)", "data:image/png;base64,abc", "https://user:secret@example.org/icon.png", "https://user@example.org/icon.png"] {
            let url = URL(string: raw)!
            #expect(CustomEmoji.parts(in: ":bad:", emojis: [":bad:": url]) == [.text(":bad:")])
        }
    }

    @Test func requestsOnlyReferencedUniqueURLsWithinBudget() {
        let parts = CustomEmoji.parts(in: ":wave::wave::flag:", emojis: [":wave:": wave, ":flag:": flag, ":unused:": URL(string: "https://other.example/unused.png")!])
        #expect(CustomEmoji.imageURLs(in: parts) == [wave, flag])
        #expect(CustomEmoji.imageURLs(in: parts, limit: 1) == [wave])
        #expect(CustomEmoji.imageURLs(in: parts, limit: 0).isEmpty)
        #expect(CustomEmoji.imageURLs(in: parts, limit: -1).isEmpty)
    }

    @Test func explicitColonKeysTakePrecedenceOverBareAliases() {
        #expect(CustomEmoji.parts(in: ":wave:", emojis: ["wave": flag, ":wave:": wave]) == [.image(shortcode: ":wave:", url: wave)])
    }

    @Test func absentMapsAndIncompleteCodesKeepLiteralText() {
        #expect(CustomEmoji.parts(in: "", emojis: nil).isEmpty)
        for text in ["Name :wave:", "Name :wave", "Name ::", "Name plain text"] {
            #expect(CustomEmoji.parts(in: text, emojis: nil) == [.text(text)])
            #expect(CustomEmoji.parts(in: text, emojis: [:]) == [.text(text)])
        }
        #expect(CustomEmoji.parts(in: ":wave", emojis: [":wave:": wave]) == [.text(":wave")])
    }

    @Test func readsTheMapFromThePersonAttributes() throws {
        let file = Bundle.module.url(forResource: "person", withExtension: "json", subdirectory: "Fixtures")!
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var attributes = json["personAttributes"] as! [String: Any]
        attributes["personCustomEmojis"] = [":wave:": wave.absoluteString]
        json["personAttributes"] = attributes
        var profile = json["personProfile"] as! [String: Any]
        profile["personName"] = "Example :wave:"
        json["personProfile"] = profile
        let person = try JSONDecoder().decode(Person.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(CustomEmoji.parts(in: person.personProfile.personName, emojis: person.personAttributes.personCustomEmojis) == [.text("Example "), .image(shortcode: ":wave:", url: wave)])
    }

    @Test func richTextPreservesMarkdownAttributesAndLiteralFallback() {
        let document = PostMarkdown("**Bold :wave:** *Italic :wave:* ~~Strike :wave:~~\n:unknown:")
        let parts = CustomEmoji.parts(in: document.blocks[0].text, emojis: ["wave": wave])
        let placeholders = parts.compactMap { part -> AttributedString? in
            if case .image(let placeholder, _) = part { return placeholder }
            return nil
        }
        #expect(placeholders.count == 3)
        #expect(placeholders[0].runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(placeholders[1].runs.first?.inlinePresentationIntent?.contains(.emphasized) == true)
        #expect(placeholders[2].runs.first?.inlinePresentationIntent?.contains(.strikethrough) == true)
        var reconstructed = AttributedString()
        for part in parts {
            switch part {
            case .text(let text): reconstructed.append(text)
            case .image(let placeholder, _): reconstructed.append(placeholder)
            }
        }
        #expect(reconstructed == document.blocks[0].text)
        #expect(CustomEmoji.imageURLs(in: parts) == [wave])
    }

    @Test func inlineCodeAndLinksDoNotTriggerEmojiDownloads() {
        let document = PostMarkdown("`:wave:` [:wave:](https://example.org) ![:wave:](https://example.org/photo.png)")
        let source = document.blocks[0].text
        let parts = CustomEmoji.parts(in: source, emojis: [":wave:": wave])
        #expect(CustomEmoji.imageURLs(in: parts).isEmpty)
        var reconstructed = AttributedString()
        for case .text(let text) in parts { reconstructed.append(text) }
        #expect(reconstructed == source)
        #expect(reconstructed.runs.compactMap(\.link).count == 2)
    }

    @Test func richTextKeepsUnknownCodesAndDoesNotJoinAcrossFormattingBoundaries() {
        let document = PostMarkdown(":wa**ve**: :unknown: :wave:")
        let parts = CustomEmoji.parts(in: document.blocks[0].text, emojis: [":wave:": wave])
        #expect(parts.filter { if case .image = $0 { return true }; return false }.count == 1)
        #expect(CustomEmoji.imageURLs(in: parts, limit: 0).isEmpty)
        #expect(CustomEmoji.imageURLs(in: parts, limit: 1) == [wave])
        #expect(CustomEmoji.parts(in: AttributedString(":wave:"), emojis: nil) == [.text(AttributedString(":wave:"))])
    }
}
