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
    @ObservationIgnored private let decode: ToolImagePreviewDecoder.Decode
    private(set) var imageCount = 0
    private(set) var byteCount = 0

    init(maximumImageCount: Int = 24, maximumByteCount: Int = 48 * 1_024 * 1_024,
         decode: @escaping ToolImagePreviewDecoder.Decode = ToolImagePreviewDecoder.decode) {
        self.maximumImageCount = max(0, maximumImageCount)
        self.maximumByteCount = max(0, maximumByteCount)
        self.decode = decode
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

    func finishLoading(_ completion: AgentToolCompletion?, activityID: String, token: UUID) async {
        guard let load = loadStates[activityID], load.token == token, load.state == .loading else { return }
        guard let completion, let conversationID = load.conversationID,
              !completion.result.isError, Self.returnsDeviceImage(completion.call.name),
              maximumImageCount > 0, maximumByteCount > 0 else {
            loadStates[activityID]?.state = .unavailable
            return
        }
        let decode = decode
        let content = completion.result.content
        let countLimit = min(4, maximumImageCount)
        let byteLimit = maximumByteCount
        let task = Task.detached(priority: .utility) { decode(content, countLimit, byteLimit) }
        let decoded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // Removal, cancellation or a newer result invalidates this work while ImageIO runs.
        // A preview never grants device-action authority.
        guard loadStates[activityID]?.token == token, loadStates[activityID]?.state == .loading else { return }
        guard !Task.isCancelled else { cancelLoading(activityID: activityID, token: token); return }
        guard !decoded.isEmpty else { loadStates[activityID]?.state = .unavailable; return }
        let cost = decoded.reduce(0) { $0 + $1.byteCount }
        while imageCount + decoded.count > maximumImageCount || byteCount + cost > maximumByteCount {
            guard let oldest = insertionOrder.first else { loadStates[activityID]?.state = .unavailable; return }
            remove(activityID: oldest)
        }
        // UIKit construction and observable publication stay on the main actor.
        let previews = decoded.map {
            ToolImagePreview(id: "\(activityID):image:\($0.index)", image: UIImage(cgImage: $0.image))
        }
        entries[activityID] = Entry(conversationID: conversationID, previews: previews, byteCount: cost)
        loadStates[activityID]?.state = .available
        insertionOrder.append(activityID)
        imageCount += previews.count; byteCount += cost
    }

    func cancelLoading(activityID: String, token: UUID) {
        guard loadStates[activityID]?.token == token else { return }
        loadStates.removeValue(forKey: activityID)
    }

    func record(_ completion: AgentToolCompletion, activityID: String, conversationID: UUID) async {
        remove(activityID: activityID)
        let token = UUID()
        loadStates[activityID] = LoadState(conversationID: conversationID, token: token, state: .loading)
        await finishLoading(completion, activityID: activityID, token: token)
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
        DeviceToolSpec(rawValue: name)?.returnsImage == true
    }
}

/// ImageIO creates immutable CGImages here; neither mutable pixel buffers nor UIKit
/// objects cross the task boundary. The store owns all UIImage creation and display state.
struct DecodedToolImagePreview: @unchecked Sendable {
    let index: Int
    let image: CGImage
    var byteCount: Int { image.bytesPerRow * image.height }
}

enum ToolImagePreviewDecoder {
    typealias Decode = @Sendable ([AgentToolContent], Int, Int) -> [DecodedToolImagePreview]

    static func decode(_ content: [AgentToolContent], _ maximumImageCount: Int,
                       _ maximumByteCount: Int) -> [DecodedToolImagePreview] {
        var previews: [DecodedToolImagePreview] = []
        var cost = 0
        for (index, item) in content.enumerated() {
            guard !Task.isCancelled, previews.count < maximumImageCount else { break }
            guard case .image(let data, let mimeType) = item,
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
            previews.append(DecodedToolImagePreview(index: index, image: image))
            cost += imageCost
        }
        return previews
    }
}
