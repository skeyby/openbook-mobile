import SwiftUI
import OpenBookCore

struct MarkdownPostView: View {
    private let document: PostMarkdown
    private let emojis: [String: URL]?

    init(_ source: String, baseURL: URL? = nil, emojis: [String: URL]? = nil) {
        document = PostMarkdown(source, baseURL: baseURL)
        self.emojis = emojis
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.blocks) { block in
                HStack(alignment: .top, spacing: 8) {
                    if block.isQuote {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3)
                    }
                    if let marker = block.listMarker {
                        Text(marker).monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                            .accessibilityHidden(true)
                    } else if block.listDepth > 0 {
                        Color.clear.frame(width: 18).accessibilityHidden(true)
                    }
                    blockContent(block)
                }
                .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 18)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            PostMarkdown.allows(url) ? .systemAction(url) : .discarded
        })
    }

    @ViewBuilder
    private func blockContent(_ block: PostMarkdown.Block) -> some View {
        switch block.kind {
        case .rule: Divider().padding(.vertical, 4)
        case .code:
            ScrollView(.horizontal) {
                Text(String(block.text.characters))
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .heading(let level):
            CustomEmojiText(styled(block.text), emojis: emojis,
                            textStyle: level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .bold)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            CustomEmojiText(styled(block.text), emojis: emojis)
        }
    }

    private func styled(_ input: AttributedString) -> AttributedString {
        var text = input
        for run in input.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(.body, design: .monospaced)
            text[run.range].backgroundColor = .secondary.opacity(0.08)
        }
        return text
    }
}
