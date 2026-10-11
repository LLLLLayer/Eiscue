import EiscueAgentKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension AppModel {
    func clearDraftMatching(_ message: AgentMessage?) {
        guard let message, draft.trimmingCharacters(in: .whitespacesAndNewlines) == message.text,
              draftAttachments == message.attachments else { return }
        draft = ""; draftAttachments = []
    }

    func addAttachmentFiles(_ urls: [URL]) async {
        guard !urls.isEmpty, !isBusy else { return }
        guard draftAttachments.count + urls.count <= MessageAttachments.maximumCount else {
            errorMessage = AttachmentImportError.count.localizedDescription; return
        }
        isImportingAttachments = true
        defer { isImportingAttachments = false }
        var imported: [AgentAttachment] = []
        do {
            for url in urls { imported.append(try await messageAttachments.importFile(url)) }
            try Task.checkCancellation()
            try AgentAttachment.validate(draftAttachments + imported, supportsImages: true)
            draftAttachments += imported
        } catch {
            for attachment in imported { await messageAttachments.remove(attachment.id) }
            if !(error is CancellationError) { errorMessage = safeError(error) }
        }
    }

    func addAttachmentPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, !isBusy else { return }
        guard draftAttachments.count + items.count <= MessageAttachments.maximumCount else {
            errorMessage = AttachmentImportError.count.localizedDescription; return
        }
        isImportingAttachments = true
        defer { isImportingAttachments = false }
        var imported: [AgentAttachment] = []
        do {
            for item in items {
                try Task.checkCancellation()
                guard let photo = try await item.loadTransferable(type: AttachmentPhoto.self) else { throw AttachmentImportError.unreadable }
                imported.append(try await messageAttachments.importData(photo.data, name: photo.name, type: .image))
            }
            try Task.checkCancellation()
            try AgentAttachment.validate(draftAttachments + imported, supportsImages: true)
            draftAttachments += imported
        } catch {
            for attachment in imported { await messageAttachments.remove(attachment.id) }
            if !(error is CancellationError) { errorMessage = safeError(error) }
        }
    }

    func addCameraImage(_ image: UIImage) async {
        guard canAddAttachments else { return }
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { errorMessage = AttachmentImportError.image.localizedDescription; return }
        isImportingAttachments = true
        defer { isImportingAttachments = false }
        do {
            // UIKit objects stay on MainActor; only bounded encoded data crosses
            // into the private attachment store's actor.
            let scale = min(1, 2048 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = normalized.jpegData(compressionQuality: 0.85) else { throw AttachmentImportError.image }
            let attachment = try await messageAttachments.importData(data,
                name: String(localized: "attachment.cameraPhoto", table: "Attachments") + ".jpg", type: .jpeg)
            if Task.isCancelled { await messageAttachments.remove(attachment.id); return }
            draftAttachments.append(attachment)
        } catch { if !(error is CancellationError) { errorMessage = safeError(error) } }
    }

    func removeDraftAttachment(id: UUID) {
        guard !isBusy else { return }
        draftAttachments.removeAll { $0.id == id }
        removeUnreferencedAttachment(id)
    }

    func discardDraftAttachments() {
        let ids = draftAttachments.map(\.id)
        draftAttachments = []
        for id in ids { removeUnreferencedAttachment(id) }
    }

    private func removeUnreferencedAttachment(_ id: UUID) {
        guard !conversations.contains(where: { $0.messages.contains(where: { $0.attachments.contains(where: { $0.id == id }) }) }) else { return }
        Task { await messageAttachments.remove(id) }
    }

    func removeStoredAttachmentsIfUnreferenced(_ ids: [UUID]) async {
        for id in Set(ids) where !draftAttachments.contains(where: { $0.id == id }) {
            guard !conversations.contains(where: { $0.messages.contains(where: { $0.attachments.contains(where: { $0.id == id }) }) }) else { continue }
            await messageAttachments.remove(id)
        }
    }
}
