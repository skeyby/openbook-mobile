import Foundation
import Testing
@testable import OpenBookCore

@Suite struct MarkdownTests {
    @Test func emphasisLinksAndBareURLs() {
        let document = PostMarkdown("Ciao **mondo**, *corsivo*, ~~barrato~~ e [OpenBook](https://example.org).\n\nhttps://example.org/articolo")
        let first = document.blocks[0].text
        #expect(String(first.characters) == "Ciao mondo, corsivo, barrato e OpenBook.")
        #expect(first.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(first.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(first.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        #expect(first.runs.contains { $0.link?.absoluteString == "https://example.org" })
        #expect(document.blocks[1].text.runs.contains { $0.link?.absoluteString == "https://example.org/articolo" })
    }

    @Test func paragraphsAndPostLineBreaksRemainReadable() {
        let document = PostMarkdown("Prima riga\nSeconda riga\n\nAltro paragrafo con  \ninterruzione esplicita")
        #expect(document.blocks.count == 2)
        #expect(String(document.blocks[0].text.characters) == "Prima riga\nSeconda riga")
        #expect(String(document.blocks[1].text.characters).contains("\n"))
    }

    @Test func headingsNestedListsQuotesAndRules() {
        let document = PostMarkdown("# Titolo\n\n7. Primo\n8. Secondo\n   - Interno\n\n> Citazione\n\n---")
        #expect(document.blocks[0].kind == .heading(1))
        #expect(document.blocks[1].listMarker == "7.")
        #expect(document.blocks[2].listMarker == "8.")
        #expect(document.blocks[3].listMarker == "•")
        #expect(document.blocks[3].listDepth == 2)
        #expect(document.blocks[4].isQuote)
        #expect(document.blocks.last?.kind == .rule)
    }

    @Test func codeAndEscapesStayLiteral() {
        let document = PostMarkdown("`https://example.org` e \\*letterale\\*\n\n```swift\nlet value = \"**testo**\"\n```" )
        #expect(document.blocks[0].text.runs.allSatisfy { $0.link == nil })
        #expect(String(document.blocks[0].text.characters).contains("*letterale*"))
        #expect(document.blocks[1].kind == .code)
        #expect(String(document.blocks[1].text.characters).contains("**testo**"))
    }

    @Test func relativeLinksResolveAndUnsafeSchemesAreRemoved() {
        let document = PostMarkdown("[relativo](/article) [email](mailto:alex@example.org) [script](javascript:alert) [file](file:///etc/passwd) [credenziali](https://user:secret@example.org)", baseURL: URL(string: "https://example.org/posts/123"))
        let links = document.blocks.flatMap { $0.text.runs.compactMap(\.link) }
        #expect(links.map(\.absoluteString) == ["https://example.org/article", "mailto:alex@example.org"])
        #expect(!PostMarkdown.allows(URL(string: "it.brancatelli.openbook.mobile://oauth/callback")!))
        #expect(!PostMarkdown.allows(URL(string: "data:text/plain,test")!))
    }

    @Test func fediverseMentionsAreNotEmailLinks() {
        let document = PostMarkdown("@alex@example.org e alex@example.org")
        let links = document.blocks[0].text.runs.compactMap(\.link)
        #expect(links.map(\.absoluteString) == ["mailto:alex@example.org"])
        #expect(String(document.blocks[0].text.characters) == "@alex@example.org e alex@example.org")
    }

    @Test func markdownImagesHaveReadableLinkedAltText() {
        let document = PostMarkdown("![Descrizione immagine](https://example.org/photo.png)")
        #expect(String(document.blocks[0].text.characters) == "Descrizione immagine")
        #expect(document.blocks[0].text.runs.first?.link?.absoluteString == "https://example.org/photo.png")
        #expect(document.blocks[0].text.runs.allSatisfy { $0.imageURL == nil })
    }
}
