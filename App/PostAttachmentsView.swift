import SwiftUI
import OpenBookCore

/// Posts and comments share the same image viewer and inline video player.
struct PostAttachmentsView: View {
    let attachments: [Media]
    @Binding var selection: PostImageSelection?
    var body: some View {
        ForEach(attachments) { media in
            if media.mediaMimeType.hasPrefix("image/"),
               let imageURL = safeImageURL(media.mediaUrl) ?? safeImageURL(media.mediaPreviewUrl) {
                Button {
                    selection = PostImageSelection(id: media.id, url: imageURL,
                                                     description: media.mediaAltText ?? "Immagine allegata")
                } label: {
                    if let preview = safeImageURL(media.mediaPreviewUrl) {
                        AsyncImage(url: preview) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFit()
                            case .failure: Label("Apri immagine", systemImage: "photo")
                            default: ProgressView().frame(height: 100)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Label("Apri immagine", systemImage: "photo")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Apri immagine: \(media.mediaAltText ?? "Immagine allegata")")
                .accessibilityHint("Apre l’immagine a tutto schermo")
            } else if media.mediaMimeType.hasPrefix("video/"), let url = safeImageURL(media.mediaUrl) {
                PostVideoView(media: media, url: url).id(media.id + url.absoluteString)
            } else if let url = safeImageURL(media.mediaUrl) {
                Link(destination: url) {
                    Label(media.mediaAltText ?? "Apri allegato", systemImage: media.mediaMimeType.hasPrefix("video/") ? "video" : "paperclip")
                }
            }
        }
    }
}
