import EiscueAgentKit
import Foundation

/// Local inspection only. Exported reports must keep using RunReport's metadata allowlist.
struct RunToolDetails {
    struct Frame: Equatable, Sendable {
        let id: UUID
        let width: Int
        let height: Int
    }

    struct Point: Equatable, Sendable {
        let x: Double
        let y: Double
    }

    enum Marker: Equatable, Sendable {
        case tap(Point)
        case swipe(from: Point, to: Point)

        var points: [Point] {
            switch self {
            case .tap(let point): [point]
            case .swipe(let from, let to): [from, to]
            }
        }

        func fits(_ frame: Frame) -> Bool {
            points.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x < Double(frame.width) && $0.y < Double(frame.height) }
        }
    }

    let activity: ToolActivity
    let sourceActivity: ToolActivity?
    let sourceFrame: Frame?
    let marker: Marker?

    var isAction: Bool { DeviceToolSpec(rawValue: activity.name)?.mayHaveSideEffects == true }
    var hasOutputImage: Bool { DeviceToolSpec(rawValue: activity.name)?.returnsImage == true && !activity.isRunning && !activity.isError }
    var outputFrame: Frame? { Self.frame(in: activity) }
    var imageMarker: Marker? {
        guard let marker, let sourceFrame, marker.fits(sourceFrame) else { return nil }
        return marker
    }

    init(activity: ToolActivity, activities: [ToolActivity]) {
        self.activity = activity
        let arguments = try? JSONDecoder().decode(AgentJSONValue.self, from: Data(activity.arguments.utf8))
        marker = Self.marker(name: activity.name, arguments: arguments)
        // Journal order is authoritative. Never use an action's returned (after)
        // screen or a later screenshot to illustrate where its input was sent.
        if let index = activities.firstIndex(where: { $0.id == activity.id }),
           let raw = arguments?["frameId"]?.stringValue, let frameID = UUID(uuidString: raw),
           let source = activities[..<index].last(where: { Self.frame(in: $0)?.id == frameID }) {
            sourceActivity = source
            sourceFrame = Self.frame(in: source)
        } else {
            sourceActivity = nil
            sourceFrame = nil
        }
    }

    static func frame(in activity: ToolActivity) -> Frame? {
        guard DeviceToolSpec(rawValue: activity.name)?.returnsImage == true, !activity.isRunning, !activity.isError,
              let expression = try? NSRegularExpression(pattern: #"(?:^| )frameId=([0-9a-fA-F-]{36}); width=([0-9]{1,6}); height=([0-9]{1,6});"#),
              let match = expression.firstMatch(in: activity.output, range: NSRange(activity.output.startIndex..., in: activity.output)),
              let idRange = Range(match.range(at: 1), in: activity.output),
              let widthRange = Range(match.range(at: 2), in: activity.output),
              let heightRange = Range(match.range(at: 3), in: activity.output),
              let id = UUID(uuidString: String(activity.output[idRange])),
              let width = Int(activity.output[widthRange]), let height = Int(activity.output[heightRange]),
              width > 0, height > 0 else { return nil }
        return Frame(id: id, width: width, height: height)
    }

    private static func marker(name: String, arguments: AgentJSONValue?) -> Marker? {
        func point(_ x: String, _ y: String) -> Point? {
            guard let x = arguments?[x]?.doubleValue, let y = arguments?[y]?.doubleValue,
                  x.isFinite, y.isFinite else { return nil }
            return Point(x: x, y: y)
        }
        switch DeviceToolSpec(rawValue: name)?.marker {
        case .tap:
            guard let point = point("x", "y") else { return nil }
            return .tap(point)
        case .swipe:
            guard let from = point("fromX", "fromY"), let to = point("toX", "toY") else { return nil }
            return .swipe(from: from, to: to)
        case .some(.none), nil: return nil
        }
    }
}
