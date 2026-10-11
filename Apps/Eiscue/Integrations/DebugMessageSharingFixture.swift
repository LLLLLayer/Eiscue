#if DEBUG
import EiscueAgentKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Opt-in simulator UI fixture. Imports through the real private attachment
/// store and uses the production row/share presenter, with no model requests.
struct MessageSharingFixtureView: View {
    @Environment(AppModel.self) private var model
    @State private var fileMessage: AgentMessage?
    @State private var photoMessage: AgentMessage?
    @State private var error: String?
    @State private var sharedFilename = ""
    @State private var sharedBytes = Data()
    @State private var showsSavedFilePicker = false
    @State private var savedFileResult: DebugSavedShareResult?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 30) {
                    if let fileMessage {
                        ChatMessageRow(message: fileMessage)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("fixtureFileShareRow")
                    }
                    if let photoMessage {
                        ChatMessageRow(message: photoMessage)
                            .accessibilityElement(children: .contain).accessibilityIdentifier("fixturePhotoShareRow")
                    }
                    if fileMessage != nil {
                        VStack(spacing: 8) {
                            Text(sharedFilename).font(.caption.monospaced())
                                .accessibilityIdentifier("fixtureSharedFilename")
                            Text(String(sharedBytes.count)).font(.caption)
                                .accessibilityIdentifier("fixtureSharedByteCount")
                            Button("Verify saved file") {
                                savedFileResult = nil
                                showsSavedFilePicker = true
                            }.accessibilityIdentifier("verifySavedShareButton")
                            if let savedFileResult {
                                Text(savedFileResult.description)
                                    .accessibilityIdentifier("fixtureSavedFileVerification")
                                    .accessibilityValue(savedFileResult.accessibilityValue)
                            }
                        }
                    }
                    if let error { Text(error).accessibilityIdentifier("fixtureShareError") }
                }.padding(24).frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }.navigationTitle("Message sharing fixture")
        }
        .sheet(isPresented: $showsSavedFilePicker) {
            DebugSavedSharePicker(expectedName: sharedFilename, expectedBytes: sharedBytes) { result in
                savedFileResult = result
                showsSavedFilePicker = false
            }
        }
        .task {
            guard fileMessage == nil else { return }
            do {
                let nonce = UUID().uuidString
                sharedFilename = "Shared notes-" + nonce + ".txt"
                sharedBytes = Data(("Actual shared document bytes\n" + nonce + "\n").utf8)
                let file = try await model.messageAttachments.importData(sharedBytes, name: sharedFilename, type: .plainText)
                let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 80)).image { context in
                    UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
                }
                guard let data = image.pngData() else { throw MessageSharingError.preparation }
                let photo = try await model.messageAttachments.importData(data, name: "Ice photo.png", type: .png)
                fileMessage = AgentMessage(role: .user, text: "", attachments: [file])
                photoMessage = AgentMessage(role: .user, text: "", attachments: [photo])
            } catch { self.error = error.localizedDescription }
        }
    }
}

private enum DebugSavedShareResult {
    case verified(name: String, bytes: Int)
    case failed
    case cancelled

    var description: String {
        switch self {
        case .verified: "Saved file bytes verified"
        case .failed: "Saved file name or bytes do not match"
        case .cancelled: "Saved file verification cancelled"
        }
    }
    var accessibilityValue: String {
        switch self {
        case .verified(let name, let bytes): "verified|\(name)|\(bytes)"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }
}

/// Read-back comes only from a fresh public document picker grant. The fixture
/// never writes a save destination or treats the original share export as the
/// result. A unique expected name is checked before any file content is read.
private struct DebugSavedSharePicker: UIViewControllerRepresentable {
    let expectedName: String
    let expectedBytes: Data
    let finished: @MainActor (DebugSavedShareResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(expectedName: expectedName, expectedBytes: expectedBytes, finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        picker.loadViewIfNeeded()
        picker.view.accessibilityIdentifier = "fixtureSavedDocumentPicker"
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let expectedName: String
        private let expectedBytes: Data
        private let finished: @MainActor (DebugSavedShareResult) -> Void
        init(expectedName: String, expectedBytes: Data, finished: @escaping @MainActor (DebugSavedShareResult) -> Void) {
            self.expectedName = expectedName
            self.expectedBytes = expectedBytes
            self.finished = finished
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard urls.count == 1, let url = urls.first, url.isFileURL,
                  url.lastPathComponent == expectedName,
                  !url.standardizedFileURL.path.hasPrefix(MessageSharing.exportRoot.standardizedFileURL.path + "/") else {
                finished(.failed); return
            }
            // The fixture file is small; reject mismatched sizes before reading
            // and never inspect another file selected accidentally by a user.
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard size == expectedBytes.count else { finished(.failed); return }
                let data = try MessageAttachments.boundedData(at: url)
                guard data == expectedBytes else { finished(.failed); return }
                finished(.verified(name: url.lastPathComponent, bytes: data.count))
            } catch { finished(.failed) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished(.cancelled) }
    }
}
#endif
