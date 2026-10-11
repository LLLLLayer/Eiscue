import EiscueAgentKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum AttachmentImportError: LocalizedError {
    case count, fileSize, unsupported, unreadable, image, emptyPDF, textSize, pageCount, cameraUnavailable, cameraDenied
    var errorDescription: String? {
        switch self {
        case .count: String(localized: "attachment.error.count", table: "Attachments")
        case .fileSize: String(localized: "attachment.error.fileSize", table: "Attachments")
        case .unsupported: String(localized: "attachment.error.unsupported", table: "Attachments")
        case .unreadable: String(localized: "attachment.error.unreadable", table: "Attachments")
        case .image: String(localized: "attachment.error.image", table: "Attachments")
        case .emptyPDF: String(localized: "attachment.error.emptyPDF", table: "Attachments")
        case .textSize: String(localized: "attachment.error.textSize", table: "Attachments")
        case .pageCount: String(localized: "attachment.error.pageCount", table: "Attachments")
        case .cameraUnavailable: String(localized: "attachment.error.cameraUnavailable", table: "Attachments")
        case .cameraDenied: String(localized: "attachment.error.cameraDenied", table: "Attachments")
        }
    }
}

/// Imports into application-private storage. Original URLs never enter messages
/// or model requests, and security-scoped access ends before returning.
actor MessageAttachments {
    static let maximumCount = 4
    static let maximumSourceBytes = 20 * 1_024 * 1_024
    static let allowedFileTypes: [UTType] = [.image, .pdf, .plainText, .json, .commaSeparatedText, .sourceCode]
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    nonisolated static func boundedData(at url: URL) throws -> Data {
        guard url.isFileURL else { throw AttachmentImportError.unreadable }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AttachmentImportError.unsupported }
        guard let size = values.fileSize, size > 0, size <= maximumSourceBytes else { throw AttachmentImportError.fileSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumSourceBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumSourceBytes else { throw AttachmentImportError.fileSize }
        guard data.count == size else { throw AttachmentImportError.unreadable }
        return data
    }

    func importFile(_ url: URL) throws -> AgentAttachment {
        try Task.checkCancellation()
        return try importData(Self.boundedData(at: url), name: url.lastPathComponent,
                              type: UTType(filenameExtension: url.pathExtension))
    }

    func importData(_ data: Data, name: String, type: UTType?) throws -> AgentAttachment {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= Self.maximumSourceBytes else { throw AttachmentImportError.fileSize }
        let safeName = Self.safeName(name)
        let attachment: AgentAttachment
        if type?.conforms(to: .image) == true {
            attachment = AgentAttachment(name: safeName, mimeType: "image/jpeg", content: .image(try Self.normalizedImage(data)))
        } else if type?.conforms(to: .pdf) == true {
            attachment = AgentAttachment(name: safeName, mimeType: "application/pdf", content: .text(try Self.pdfText(data)))
        } else if type?.conforms(to: .text) == true || type?.conforms(to: .json) == true {
            guard data.count <= 120_000 else { throw AttachmentImportError.textSize }
            let text = String(data: data, encoding: .utf8) ?? Self.decodeUTF16WithBOM(data)
            guard let text, !text.contains("\0"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AttachmentImportError.unreadable
            }
            guard text.utf8.count <= 60_000 else { throw AttachmentImportError.textSize }
            attachment = AgentAttachment(name: safeName, mimeType: type?.preferredMIMEType ?? "text/plain", content: .text(text))
        } else { throw AttachmentImportError.unsupported }
        try AgentAttachment.validate([attachment], supportsImages: true)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let url = directory.appendingPathComponent(attachment.id.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(attachment).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return attachment
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))
    }

    nonisolated static func safeName(_ value: String) -> String {
        let name = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let result = String(String.UnicodeScalarView(name)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? String(localized: "attachment.file", table: "Attachments") : String(result.prefix(120))
    }

    private static func decodeUTF16WithBOM(_ data: Data) -> String? {
        guard data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) else { return nil }
        return String(data: data, encoding: .utf16)
    }

    nonisolated static func normalizedImage(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw AttachmentImportError.image }
        for quality in [0.85, 0.65, 0.45] {
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { throw AttachmentImportError.image }
            // Re-encoding strips location/EXIF metadata from the transmitted image.
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AttachmentImportError.image }
            if encoded.length <= 2 * 1_024 * 1_024 { return encoded as Data }
        }
        throw AttachmentImportError.fileSize
    }

    nonisolated static func pdfText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw AttachmentImportError.unreadable }
        guard document.pageCount <= 100 else { throw AttachmentImportError.pageCount }
        var parts: [String] = []
        var bytes = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw AttachmentImportError.unreadable }
            guard page.numberOfCharacters <= 60_000 - bytes else { throw AttachmentImportError.textSize }
            let text = page.string ?? ""
            bytes += text.utf8.count + 2
            guard bytes <= 60_000 else { throw AttachmentImportError.textSize }
            parts.append(text)
        }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AttachmentImportError.emptyPDF }
        return text
    }
}
