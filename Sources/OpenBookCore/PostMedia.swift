import Foundation

/// Effective server/runtime policy. A missing policy must not be treated as unlimited.
public struct InstanceUploadLimits: Decodable, Equatable, Sendable {
    public let maxAttachmentsPerPost: Int
    public let maxAttachmentBytes: Int64
    public let maxVideoAttachmentBytes: Int64?
    public let maxRequestBytes: Int64?
    public var allowsImages: Bool { maxAttachmentsPerPost > 0 && maxAttachmentBytes > 0 }
    public var allowsVideo: Bool { maxAttachmentsPerPost > 0 && (maxVideoAttachmentBytes ?? 0) > 0 }
    public var allowsMedia: Bool { allowsImages || allowsVideo }

    public init(maxAttachmentsPerPost: Int, maxAttachmentBytes: Int64, maxVideoAttachmentBytes: Int64?, maxRequestBytes: Int64?) throws {
        guard maxAttachmentsPerPost >= 0, maxAttachmentBytes >= 0,
              maxVideoAttachmentBytes.map({ $0 >= 0 }) ?? true,
              maxRequestBytes.map({ $0 >= 1 }) ?? true else { throw OpenBookError.message("Limiti di caricamento non validi.") }
        self.maxAttachmentsPerPost = maxAttachmentsPerPost
        self.maxAttachmentBytes = maxAttachmentBytes
        self.maxVideoAttachmentBytes = maxVideoAttachmentBytes
        self.maxRequestBytes = maxRequestBytes
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case maxAttachmentsPerPost, maxAttachmentBytes, maxVideoAttachmentBytes, maxRequestBytes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard CodingKeys.allCases.allSatisfy({ values.contains($0) }) else {
            throw OpenBookError.message("Limiti di caricamento incompleti.")
        }
        try self.init(maxAttachmentsPerPost: values.decode(Int.self, forKey: .maxAttachmentsPerPost),
                      maxAttachmentBytes: values.decode(Int64.self, forKey: .maxAttachmentBytes),
                      maxVideoAttachmentBytes: values.decodeIfPresent(Int64.self, forKey: .maxVideoAttachmentBytes),
                      maxRequestBytes: values.decodeIfPresent(Int64.self, forKey: .maxRequestBytes))
    }
    public func validate(files: [DraftAttachment]) throws {
        guard files.count <= maxAttachmentsPerPost else {
            throw OpenBookError.message("L’istanza consente al massimo \(maxAttachmentsPerPost) allegati per post.")
        }
        for (index, attachment) in files.enumerated() {
            let video = attachment.file.mimeType.hasPrefix("video/")
            let maximum: Int64
            if video {
                guard let videoMaximum = maxVideoAttachmentBytes else {
                    throw OpenBookError.message("Questa istanza non permette di caricare video.")
                }
                maximum = videoMaximum
            } else { maximum = maxAttachmentBytes }
            guard Int64(attachment.file.byteCount) <= maximum else {
                throw OpenBookError.message("L’allegato \(index + 1) supera il limite di \(Self.describe(maximum)) (\(maximum) byte) per \(video ? "video" : "file").")
            }
        }
    }
    public func validate(requestBytes: Int64) throws {
        if let maximum = maxRequestBytes, requestBytes > maximum {
            throw OpenBookError.message("L’invio completo richiede \(Self.describe(requestBytes)) (\(requestBytes) byte) e supera il limite di \(Self.describe(maximum)) (\(maximum) byte), inclusi testo e struttura degli allegati.")
        }
    }
    public static func describe(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) }
}

/// Owns one temporary copy. ARC removes it when neither the draft nor an upload uses it.
public final class DraftMediaFile: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    private let directory: URL

    public init(copying source: URL, mimeType: String) throws {
        guard source.isFileURL, mimeType.range(of: #"\A(image|video|audio)/[A-Za-z0-9!#$&^_.+\-]+\z"#, options: .regularExpression) != nil else {
            throw OpenBookError.message("Formato del file non supportato.")
        }
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0 else { throw OpenBookError.message("Il file selezionato è vuoto o non disponibile.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openbook-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let ext = source.pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12)
        let name = "media" + (ext.isEmpty ? "" : ".\(ext)")
        let destination = folder.appendingPathComponent(name)
        var copiedSize = size
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            guard let actual = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, actual > 0 else {
                throw OpenBookError.message("Impossibile verificare la dimensione del file selezionato.")
            }
            copiedSize = actual
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var privateFolder = folder; try privateFolder.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            #endif
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
        directory = folder; url = destination; filename = name; self.mimeType = mimeType; byteCount = copiedSize
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

public struct DraftAttachment: Identifiable, Sendable {
    public var id: UUID { file.id }
    public let file: DraftMediaFile
    public var altText: String
    public init(file: DraftMediaFile, altText: String = "") { self.file = file; self.altText = altText }
}

public struct NewPostAttachment: Encodable, Sendable {
    public let filePart: String
    public let mediaAltText: String?
    public init(filePart: String, altText: String? = nil) throws {
        guard filePart != "post", filePart.range(of: #"\A[A-Za-z][A-Za-z0-9]{0,63}\z"#, options: .regularExpression) != nil,
              (altText?.unicodeScalars.count ?? 0) <= 1000 else {
            throw OpenBookError.message("Il riferimento del file o la descrizione alternativa non è valido (massimo 1000 caratteri).")
        }
        self.filePart = filePart; mediaAltText = altText
    }
}

/// Disk-backed multipart body: binary files are copied in bounded chunks, never concatenated in RAM.
public final class MultipartPost: Sendable {
    public let url: URL
    public let boundary: String
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    private let directory: URL

    public init(draft: NewPost, files: [DraftAttachment]) throws {
        let metadata = try Self.metadata(draft: draft, files: files)
        boundary = "OpenBook\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("openbook-upload-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("body.multipart")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #endif
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            func write(_ string: String) throws { try output.write(contentsOf: Data(string.utf8)) }
            try write(Self.postHeader(boundary))
            try output.write(contentsOf: JSONEncoder().encode(draft))
            try write("\r\n")
            for (meta, attachment) in zip(metadata, files) {
                try Task.checkCancellation()
                try write(Self.fileHeader(meta, file: attachment.file, boundary: boundary))
                let input = try FileHandle(forReadingFrom: attachment.file.url)
                var bytesCopied = 0
                do {
                    while true {
                        let copied = try autoreleasepool {
                            try Task.checkCancellation()
                            guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else { return false }
                            guard chunk.count <= attachment.file.byteCount - bytesCopied else {
                                throw OpenBookError.message("Un allegato è cambiato durante la preparazione. Selezionalo nuovamente prima di inviare.")
                            }
                            try output.write(contentsOf: chunk)
                            bytesCopied += chunk.count
                            return true
                        }
                        if !copied { break }
                    }
                    guard bytesCopied == attachment.file.byteCount else {
                        throw OpenBookError.message("Un allegato è cambiato durante la preparazione. Selezionalo nuovamente prima di inviare.")
                    }
                    try input.close()
                } catch { try? input.close(); throw error }
                try write("\r\n")
            }
            try write("--\(boundary)--\r\n")
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    /// Exact wire length: boundary is always OpenBook plus 32 ASCII characters.
    public static func bodyByteCount(draft: NewPost, files: [DraftAttachment]) throws -> Int64 {
        let metadata = try self.metadata(draft: draft, files: files)
        let boundary = "OpenBook" + String(repeating: "0", count: 32)
        var count: Int64 = 0
        func add(_ bytes: Int64) throws {
            let sum = count.addingReportingOverflow(bytes)
            guard !sum.overflow else { throw OpenBookError.message("L’invio è troppo grande.") }
            count = sum.partialValue
        }
        try add(Int64(postHeader(boundary).utf8.count))
        try add(Int64(JSONEncoder().encode(draft).count))
        try add(2)
        for (meta, attachment) in zip(metadata, files) {
            try add(Int64(fileHeader(meta, file: attachment.file, boundary: boundary).utf8.count))
            try add(Int64(attachment.file.byteCount)); try add(2)
        }
        try add(Int64("--\(boundary)--\r\n".utf8.count))
        return count
    }
    private static func metadata(draft: NewPost, files: [DraftAttachment]) throws -> [NewPostAttachment] {
        guard let metadata = draft.postAttachments, !files.isEmpty, metadata.count == files.count,
              Set(metadata.map(\.filePart)).count == metadata.count else {
            throw OpenBookError.message("Ogni allegato deve corrispondere a un file distinto.")
        }
        return metadata
    }
    private static func postHeader(_ boundary: String) -> String {
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"post\"\r\nContent-Type: application/json\r\n\r\n"
    }
    private static func fileHeader(_ metadata: NewPostAttachment, file: DraftMediaFile, boundary: String) -> String {
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(metadata.filePart)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n"
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
