import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// File representation prevents PhotosPicker from allocating unbounded Data.
struct AttachmentPhoto: Transferable, Sendable {
    let data: Data
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            AttachmentPhoto(data: try MessageAttachments.boundedData(at: received.file), name: received.file.lastPathComponent)
        }
    }
}

@MainActor enum AttachmentCamera {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    static func requestAccess() async throws {
        guard isAvailable else { throw AttachmentImportError.cameraUnavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw AttachmentImportError.cameraDenied }
        default: throw AttachmentImportError.cameraDenied
        }
    }
}

struct EiscueCameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = [UTType.image.identifier]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        uiViewController.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        uiViewController.view.tintColor = .label
    }
    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void
        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture; self.onCancel = onCancel
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) } else { onCancel() }
        }
    }
}
