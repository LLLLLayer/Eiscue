import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MessageSharingError: LocalizedError {
    case unavailable, empty, preparation, delivery
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "messageSharing.unavailable", table: "MessageSharing")
        case .empty: String(localized: "messageSharing.empty", table: "MessageSharing")
        case .preparation: String(localized: "messageSharing.preparation", table: "MessageSharing")
        case .delivery: String(localized: "messageSharing.delivery", table: "MessageSharing")
        }
    }
}

struct MessageShareContent: Sendable {
    let name: String
    let typeIdentifier: String
    let data: Data
}

struct MessageSharedFile: Sendable {
    let url: URL
    let typeIdentifier: String
}

/// The export owns only its unique directory, never the saved attachment. Keep
/// it alive until the native share controller finishes or dismisses.
struct MessageSharePayload: Identifiable, Sendable {
    let id: UUID
    let text: String?
    let files: [MessageSharedFile]
    let directory: URL?

    func cleanup() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor func activityItems() -> [Any] {
        var items: [Any] = text.map { [$0 as Any] } ?? []
        items += files.map { MessageSharedFileSource(file: $0) }
        return items
    }
}

enum MessageSharing {
    static let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("EiscueMessageShares", isDirectory: true)

    static func prepare(text: String, attachments: [MessageShareContent], exportRoot: URL) throws -> MessageSharePayload {
        let sharedText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard sharedText != nil || !attachments.isEmpty else { throw MessageSharingError.empty }
        guard attachments.count <= MessageAttachments.maximumCount, exportRoot.isFileURL else { throw MessageSharingError.preparation }
        let id = UUID()
        let directory = attachments.isEmpty ? nil : exportRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            var files: [MessageSharedFile] = []
            for (index, attachment) in attachments.enumerated() {
                try Task.checkCancellation()
                guard let type = UTType(attachment.typeIdentifier), !attachment.data.isEmpty,
                      attachment.data.count <= MessageAttachments.maximumSourceBytes,
                      let directory else { throw MessageSharingError.unavailable }
                // Per-item directories preserve duplicate human filenames.
                let itemDirectory = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                let fileURL = itemDirectory.appendingPathComponent(filename(attachment.name, type: type))
                try attachment.data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                files.append(MessageSharedFile(url: fileURL, typeIdentifier: type.identifier))
            }
            try Task.checkCancellation()
            return MessageSharePayload(id: id, text: sharedText, files: files, directory: directory)
        } catch {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            if error is CancellationError || error is MessageSharingError { throw error }
            throw MessageSharingError.preparation
        }
    }

    private static func filename(_ name: String, type: UTType) -> String {
        var result = MessageAttachments.safeName(name)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if result.isEmpty { result = String(localized: "attachment.file", table: "Attachments") }
        let path = URL(fileURLWithPath: result)
        if let extensionType = UTType(filenameExtension: path.pathExtension), extensionType == type { return result }
        guard let fileExtension = type.preferredFilenameExtension else { return result }
        // A normalized JPEG must not keep a .png/.heic name. Text encodings and
        // PDF imports retain their original format and matching filename.
        return path.deletingPathExtension().lastPathComponent + "." + fileExtension
    }
}

final class MessageSharedFileSource: NSObject, UIActivityItemSource {
    let file: MessageSharedFile
    init(file: MessageSharedFile) { self.file = file }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { file.url }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { file.url }
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { file.typeIdentifier }
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { file.url.lastPathComponent }
}

enum MessageShareCallbacks {
    // Activity extensions may call back off the main thread. Create the actual
    // callback outside MainActor; UIKit objects and returned items stay there.
    nonisolated static func completion(
        onCompletion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> @Sendable (UIActivity.ActivityType?, Bool, [Any]?, (any Error)?) -> Void {
        { @Sendable _, _, _, error in
            let hasError = error != nil
            Task { @MainActor in onCompletion(hasError) }
        }
    }
}

/// Installed behind the share button, giving iPad a source view in the correct
/// window. This presents Apple's controller directly, without nesting it in a
/// SwiftUI sheet or using a global/key-window presenter.
struct MessageActivityPresenter: UIViewControllerRepresentable {
    let payload: MessageSharePayload?
    let finished: (UUID, Bool) -> Void

    func makeUIViewController(context: Context) -> MessageShareHost { MessageShareHost() }
    func updateUIViewController(_ host: MessageShareHost, context: Context) {
        host.finished = finished
        host.prepare(payload)
    }
    static func dismantleUIViewController(_ host: MessageShareHost, coordinator: ()) { host.cancel() }
}

@MainActor final class MessageShareHost: UIViewController, UIAdaptivePresentationControllerDelegate {
    var finished: ((UUID, Bool) -> Void)?
    private var payload: MessageSharePayload?
    private var activityController: UIActivityViewController?
    private var presentationTask: Task<Void, Never>?
    private var isFinishing = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        queuePresentation()
    }
    func prepare(_ value: MessageSharePayload?) {
        guard let value, payload == nil else { return }
        payload = value
        queuePresentation()
    }
    private func queuePresentation() {
        guard let payload, activityController == nil, presentationTask == nil, !isFinishing else { return }
        presentationTask = Task { @MainActor [weak self] in
            // Wait for the button's window and any existing modal/menu
            // transition. A lost presenter produces a bounded error, not an
            // indefinitely disabled Share button with abandoned files.
            for _ in 0..<30 {
                guard let self, !Task.isCancelled, self.payload?.id == payload.id, !self.isFinishing else { return }
                if self.isReadyToPresent {
                    self.presentActivity(payload)
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, self.payload?.id == payload.id else { return }
                    if self.activityController?.presentingViewController == nil {
                        self.beginDismissal(hasError: true, animated: false)
                    }
                    self.presentationTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.beginDismissal(hasError: true, animated: false)
        }
    }
    private var isReadyToPresent: Bool {
        guard viewIfLoaded?.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            if controller.presentedViewController != nil || controller.isBeingPresented || controller.isBeingDismissed { return false }
            ancestor = controller.parent
        }
        return true
    }
    private func presentActivity(_ payload: MessageSharePayload) {
        let items = payload.activityItems()
        guard !items.isEmpty else { beginDismissal(hasError: true, animated: false); return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.loadViewIfNeeded()
        activity.view.accessibilityIdentifier = "messageActivityController"
        activity.completionWithItemsHandler = MessageShareCallbacks.completion { [weak self] hasError in
            self?.beginDismissal(hasError: hasError, animated: true)
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
        activity.presentationController?.delegate = self
        activityController = activity
        present(activity, animated: true)
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(hasError: false) }
    func cancel() {
        // Dismantling a conversation row may happen while a share is open.
        // Retain its files until the actual dismissal completes.
        beginDismissal(hasError: false, animated: false)
    }
    private func beginDismissal(hasError: Bool, animated: Bool) {
        guard payload != nil, !isFinishing else { return }
        isFinishing = true
        presentationTask?.cancel()
        presentationTask = nil
        guard let activity = activityController else { finish(hasError: hasError); return }
        activity.completionWithItemsHandler = nil
        if activity.isBeingDismissed, let transition = activity.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { [self] context in
               if context.isCancelled {
                   activity.dismiss(animated: animated) { [self] in finish(hasError: hasError) }
               } else { finish(hasError: hasError) }
           }) { return }
        if activity.presentingViewController != nil {
            activity.dismiss(animated: animated) { [self] in finish(hasError: hasError) }
        } else { finish(hasError: hasError) }
    }
    private func finish(hasError: Bool) {
        guard let payload else { return }
        presentationTask?.cancel()
        presentationTask = nil
        self.payload = nil
        activityController = nil
        isFinishing = false
        payload.cleanup()
        finished?(payload.id, hasError)
    }
}
