#if os(iOS)
import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO
import AVKit
import OpenBookCore

private struct PickedPostMedia: Transferable, Sendable {
    let file: DraftMediaFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in try receive(received.file) }
        FileRepresentation(importedContentType: .movie) { received in try receive(received.file) }
    }
    nonisolated private static func receive(_ url: URL) throws -> Self {
        let imageType = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        guard let type = imageType ?? UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie), let mime = type.preferredMIMEType else {
            throw OpenBookError.message("Non è possibile riconoscere il formato della foto o del video.")
        }
        return Self(file: try DraftMediaFile(copying: url, mimeType: mime))
    }
}

struct PostMediaPickerView: View {
    @EnvironmentObject private var store: AppStore
    @Bindable var composer: PostComposer
    @State private var selection: [PhotosPickerItem] = []
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?
    @State private var preview: DraftMediaFile?

    private var remaining: Int { max(0, (composer.uploadLimits?.maxAttachmentsPerPost ?? 0) - composer.attachments.count) }
    private var filter: PHPickerFilter {
        guard let limits = composer.uploadLimits else { return .images }
        if !limits.allowsVideo { return .images }
        if !limits.allowsImages { return .videos }
        return .any(of: [.images, .videos])
    }
    private var pickerTitle: String {
        guard let limits = composer.uploadLimits else { return "Aggiungi allegati" }
        return limits.allowsVideo ? (limits.allowsImages ? "Aggiungi foto o video" : "Aggiungi video") : "Aggiungi foto"
    }
    var body: some View {
        let title = pickerTitle
        VStack(alignment: .leading, spacing: 12) {
            if let limits = composer.uploadLimits, limits.allowsMedia {
                PhotosPicker(selection: $selection, maxSelectionCount: max(1, remaining), selectionBehavior: .ordered,
                             matching: filter, preferredItemEncoding: .compatible) {
                    Label(title, systemImage: "photo.on.rectangle.angled")
                }.disabled(composer.isBusy || composer.uncertain || composer.publication != nil || remaining == 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Allegati: \(composer.attachments.count)/\(limits.maxAttachmentsPerPost). Foto: massimo \(InstanceUploadLimits.describe(limits.maxAttachmentBytes)) per file.")
                    if let videoBytes = limits.maxVideoAttachmentBytes {
                        Text("Video: massimo \(InstanceUploadLimits.describe(videoBytes)) per file.")
                    } else { Text("Video non supportati dall’istanza.") }
                    if let bytes = composer.requestByteCount {
                        Text("Invio completo: \(InstanceUploadLimits.describe(bytes))\(limits.maxRequestBytes.map { " di \(InstanceUploadLimits.describe($0))" } ?? " (senza limite complessivo dichiarato)").")
                    } else if let maximum = limits.maxRequestBytes {
                        Text("Invio completo: massimo \(InstanceUploadLimits.describe(maximum)), inclusi testo e struttura degli allegati.")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                Text(store.instanceMetadataError == nil ? "Questa istanza non supporta il caricamento di allegati." : "Non è possibile verificare i limiti degli allegati. Riprova prima di aggiungere file.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Aggiorna limiti allegati") { Task { await store.loadInstanceMetadata() } }
                .font(.caption).disabled(composer.isBusy)
            if composer.isImporting {
                HStack {
                    ProgressView("Preparazione allegati…")
                    Button("Interrompi") { importTask?.cancel() }
                }
            }
            if let importError { Text(importError).font(.footnote).foregroundStyle(.red) }
            ForEach(Array(composer.attachments.enumerated()), id: \.element.id) { index, attachment in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { preview = attachment.file } label: {
                            DraftMediaThumbnail(file: attachment.file)
                                .frame(width: 64, height: 64).clipped()
                        }.buttonStyle(.plain).accessibilityLabel("Anteprima allegato \(index + 1)")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(attachment.file.mimeType.hasPrefix("video/") ? "Video" : "Foto")").font(.subheadline.bold())
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.file.byteCount), countStyle: .file)).font(.caption)
                        }
                        Spacer()
                        Button("Rimuovi", systemImage: "trash") { composer.removeAttachment(id: attachment.id) }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    TextField("Descrizione alternativa (facoltativa)", text: Binding(
                        get: { composer.attachments.first { $0.id == attachment.id }?.altText ?? "" },
                        set: { composer.setAltText(id: attachment.id, text: $0) }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Descrizione alternativa allegato \(index + 1)")
                    if attachment.altText.unicodeScalars.count > 1000 {
                        Text("La descrizione può contenere al massimo 1000 caratteri.").font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Sposta prima", systemImage: "arrow.up") { composer.moveAttachment(id: attachment.id, offset: -1) }.disabled(index == 0)
                        Button("Sposta dopo", systemImage: "arrow.down") { composer.moveAttachment(id: attachment.id, offset: 1) }.disabled(index == composer.attachments.count - 1)
                    }.font(.caption).buttonStyle(.borderless)
                }
                .padding(12).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .disabled(composer.isBusy || composer.uncertain)
            }
            Text("Formati, numero, dimensioni e durata consentiti dipendono dall’istanza. I video vengono elaborati prima della pubblicazione.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty, !composer.isBusy else { return }
            composer.isImporting = true; importError = nil
            importTask = Task {
                defer { composer.isImporting = false; selection = []; importTask = nil }
                for item in items {
                    do {
                        try Task.checkCancellation()
                        guard remaining > 0 else {
                            importError = "È stato raggiunto il numero massimo di allegati consentito dall’istanza."
                            break
                        }
                        guard let picked = try await item.loadTransferable(type: PickedPostMedia.self) else {
                            throw OpenBookError.message("Impossibile importare un allegato dalla libreria.")
                        }
                        try Task.checkCancellation()
                        if !composer.add(DraftAttachment(file: picked.file)) {
                            importError = composer.errorMessage
                        }
                    } catch {
                        if !Task.isCancelled { importError = error.localizedDescription }
                    }
                    if Task.isCancelled { break }
                }
            }
        }
        .onDisappear { importTask?.cancel() }
        .sheet(item: $preview) { DraftMediaPreview(file: $0) }
    }
}

private struct DraftMediaThumbnail: View {
    let file: DraftMediaFile
    var maxPixels = 160
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: file.mimeType.hasPrefix("video/") ? "play.rectangle.fill" : "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }.task(id: file.id) {
            if file.mimeType.hasPrefix("image/"), let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels
                ] as CFDictionary)
            }
        }
    }
}

private struct DraftMediaPreview: View {
    let file: DraftMediaFile
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    init(file: DraftMediaFile) {
        self.file = file
        _player = State(initialValue: file.mimeType.hasPrefix("video/") ? AVPlayer(url: file.url) : AVPlayer())
    }
    var body: some View {
        NavigationStack {
            Group {
                if file.mimeType.hasPrefix("video/") { VideoPlayer(player: player) }
                else { DraftMediaThumbnail(file: file, maxPixels: 2048) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Anteprima allegato")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Chiudi") { dismiss() } } }
        }.onDisappear { player.pause() }
    }
}
#endif
