import SwiftUI
import ImageIO
import OpenBookCore

/// One native Text paragraph preserves wrapping, baseline, selection and Dynamic Type.
struct CustomEmojiText: View {
    let text: AttributedString
    let emojis: [String: URL]?
    let textStyle: Font.TextStyle
    let weight: Font.Weight
    @ScaledMetric private var imageSide: CGFloat
    @State private var images: [URL: CGImage] = [:]

    init(_ text: String, emojis: [String: URL]?, textStyle: Font.TextStyle = .body, weight: Font.Weight = .regular) {
        self.init(AttributedString(text), emojis: emojis, textStyle: textStyle, weight: weight)
    }

    init(_ text: AttributedString, emojis: [String: URL]?, textStyle: Font.TextStyle = .body, weight: Font.Weight = .regular) {
        self.text = text; self.emojis = emojis; self.textStyle = textStyle; self.weight = weight
        let points: CGFloat
        switch textStyle {
        case .largeTitle: points = 34
        case .title: points = 28
        case .title2: points = 22
        case .title3: points = 20
        case .callout: points = 16
        case .subheadline: points = 15
        case .footnote: points = 13
        case .caption: points = 12
        case .caption2: points = 11
        default: points = 17
        }
        _imageSide = ScaledMetric(wrappedValue: points, relativeTo: textStyle)
    }

    var body: some View {
        let parts = CustomEmoji.parts(in: text, emojis: emojis)
        rendered(parts)
            .font(.system(textStyle, weight: weight))
            .task(id: parts) { await loadImages(for: parts) }
    }

    private func rendered(_ parts: [CustomEmoji.RichPart]) -> Text {
        parts.reduce(Text("")) { result, part in
            let fragment: Text
            switch part {
            case .text(let value): fragment = Text(value)
            case .image(let placeholder, let url):
                if let image = images[url] {
                    let scale = CGFloat(max(image.width, image.height)) / imageSide
                    fragment = Text(Image(image, scale: scale, label: Text(String(placeholder.characters))))
                        .baselineOffset(-imageSide * 0.15)
                        .strikethrough(placeholder.runs.first?.inlinePresentationIntent?.contains(.strikethrough) == true)
                } else { fragment = Text(placeholder) }
            }
            return Text("\(result)\(fragment)")
        }
    }

    private func loadImages(for parts: [CustomEmoji.RichPart]) async {
        let urls = CustomEmoji.imageURLs(in: parts)
        images = images.filter { urls.contains($0.key) }
        var pending = urls.filter { images[$0] == nil }.makeIterator()
        // Public media only; decoded thumbnails live with this view, with no custom disk cache.
        await withTaskGroup(of: (URL, Data?).self) { group in
            for _ in 0..<min(4, urls.count) {
                if let url = pending.next() { group.addTask { (url, await Self.download(url)) } }
            }
            for await (url, data) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                    kCGImageSourceShouldCacheImmediately: true
                   ] as CFDictionary) {
                    images[url] = image
                }
                if let url = pending.next() { group.addTask { (url, await Self.download(url)) } }
            }
        }
    }

    // Use Apple's default HTTP cache policies without cookies, credentials or API headers.
    nonisolated private static let mediaSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    nonisolated private static func download(_ url: URL) async -> Data? {
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await mediaSession.bytes(for: request)
            defer { if Task.isCancelled { bytes.task.cancel() } }
            let limit = 2 * 1024 * 1024
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  response.expectedContentLength <= limit else { bytes.task.cancel(); return nil }
            var data = Data()
            for try await byte in bytes {
                guard !Task.isCancelled, data.count < limit else { bytes.task.cancel(); return nil }
                data.append(byte)
            }
            return data
        } catch { return nil }
    }
}
