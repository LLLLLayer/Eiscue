import EiscueAgentKit
import ImageIO
import Observation
import UIKit

struct ToolImagePreview: Identifiable {
    let id: String
    let image: UIImage
}

enum ToolImagePreviewState: Equatable { case idle, loading, available, unavailable }

/// Decoded previews are memory-only. Evicted images can be loaded again from the
/// existing runtime history; this cache creates no extra screenshot files or report data.
@MainActor @Observable
final class ToolImagePreviewStore {
    private struct Entry {
        let conversationID: UUID
        let previews: [ToolImagePreview]
        let byteCount: Int
    }
    private struct LoadState {
        let conversationID: UUID?
        let token: UUID
        var state: ToolImagePreviewState
    }

    private var entries: [String: Entry] = [:]
    private var loadStates: [String: LoadState] = [:]
    @ObservationIgnored private var insertionOrder: [String] = []
    @ObservationIgnored private let maximumImageCount: Int
    @ObservationIgnored private let maximumByteCount: Int
    private(set) var imageCount = 0
    private(set) var byteCount = 0

    init(maximumImageCount: Int = 24, maximumByteCount: Int = 48 * 1_024 * 1_024) {
        self.maximumImageCount = max(0, maximumImageCount)
        self.maximumByteCount = max(0, maximumByteCount)
    }

    func previews(for activityID: String) -> [ToolImagePreview] {
        entries[activityID]?.previews ?? []
    }

    func state(for activityID: String) -> ToolImagePreviewState {
        if entries[activityID] != nil { return .available }
        return loadStates[activityID]?.state ?? .idle
    }

    func beginLoading(activityID: String, conversationID: UUID) -> UUID? {
        guard state(for: activityID) == .idle else { return nil }
        let token = UUID()
        loadStates[activityID] = LoadState(conversationID: conversationID, token: token, state: .loading)
        return token
    }

    func markUnavailable(activityID: String, conversationID: UUID? = nil) {
        guard entries[activityID] == nil else { return }
        loadStates[activityID] = LoadState(conversationID: conversationID, token: UUID(), state: .unavailable)
    }

    func finishLoading(_ completion: AgentToolCompletion?, activityID: String, token: UUID) {
        guard let load = loadStates[activityID], load.token == token else { return }
        if let completion, let conversationID = load.conversationID { record(completion, activityID: activityID, conversationID: conversationID) }
        else { loadStates[activityID]?.state = .unavailable }
    }

    func cancelLoading(activityID: String, token: UUID) {
        guard loadStates[activityID]?.token == token else { return }
        loadStates.removeValue(forKey: activityID)
    }

    func record(_ completion: AgentToolCompletion, activityID: String, conversationID: UUID) {
        remove(activityID: activityID)
        loadStates[activityID] = LoadState(conversationID: conversationID, token: UUID(), state: .unavailable)
        guard !completion.result.isError, Self.returnsDeviceImage(completion.call.name),
              maximumImageCount > 0, maximumByteCount > 0 else { return }
        var previews: [ToolImagePreview] = []
        var cost = 0
        for (index, content) in completion.result.content.enumerated() {
            guard previews.count < min(4, maximumImageCount),
                  case .image(let data, let mimeType) = content,
                  ["image/png", "image/jpeg"].contains(mimeType),
                  data.count <= 16 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_600,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            let imageCost = image.bytesPerRow * image.height
            guard imageCost <= maximumByteCount - cost else { continue }
            previews.append(ToolImagePreview(id: "\(activityID):image:\(index)", image: UIImage(cgImage: image)))
            cost += imageCost
        }
        guard !previews.isEmpty else { return }
        while imageCount + previews.count > maximumImageCount || byteCount + cost > maximumByteCount {
            guard let oldest = insertionOrder.first else { return }
            remove(activityID: oldest)
        }
        entries[activityID] = Entry(conversationID: conversationID, previews: previews, byteCount: cost)
        insertionOrder.append(activityID)
        imageCount += previews.count; byteCount += cost
    }

    func remove(conversationID: UUID) {
        for activityID in loadStates.keys.filter({ loadStates[$0]?.conversationID == conversationID }) {
            loadStates.removeValue(forKey: activityID)
        }
        for activityID in insertionOrder where entries[activityID]?.conversationID == conversationID {
            remove(activityID: activityID)
        }
    }

    func removeAll() {
        entries.removeAll(); loadStates.removeAll(); insertionOrder.removeAll(); imageCount = 0; byteCount = 0
    }

    private func remove(activityID: String) {
        loadStates.removeValue(forKey: activityID)
        guard let entry = entries.removeValue(forKey: activityID) else { return }
        insertionOrder.removeAll { $0 == activityID }
        imageCount -= entry.previews.count; byteCount -= entry.byteCount
    }

    static func returnsDeviceImage(_ name: String) -> Bool {
        switch name {
        case "device_screenshot", "device_tap", "device_swipe", "device_type_text",
             "device_launch_app", "device_home", "device_press_key": true
        default: false
        }
    }
}
