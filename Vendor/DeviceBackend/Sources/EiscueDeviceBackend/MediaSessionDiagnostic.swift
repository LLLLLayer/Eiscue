// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import CoreFoundation
import Foundation

/// Only the fixed numeric/boolean summary may leave the native worker. Unknown
/// peer fields and opaque negotiation data never enter the diagnostic artifact.
struct NCMMediaSessionDiagnostic {
    private static let booleans: Set<String> = ["querySucceeded", "queryTimedOut", "mediaHealthy", "scanComplete", "truncated"]
    private static let shapes: Set<String> = ["rootIsDictionary", "serverInfoPresent", "serverInfoIsDictionary", "sessionsPresent", "sessionsIsArray"]
    private static let counts: Set<String> = ["sessionCount", "sessionUUIDMatchCount", "callUUIDMatchCount", "streamConfigCount", "localSSRCFieldCount", "remoteSSRCFieldCount", "streamPairMatchCount", "correlatedSessionMatchCount", "clientSessionPairMatchCount"]
    private static let nullable = shapes.union(counts).union(["opaqueDataPresent", "failureStage", "failureCause"])
    private static let fields = booleans.union(nullable).union(["version", "visitedNodeCount", "visitedByteCount"])
    private let summary: [String: Any]

    init(data: Data) throws {
        guard data.count <= 8192,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Self.fields,
              Self.integer(object["version"], maximum: 1) == 1 else { throw NativeBackendError.malformedEvent }
        for key in Self.booleans {
            guard Self.boolean(object[key]) != nil else { throw NativeBackendError.malformedEvent }
        }
        for key in Self.shapes.union(["opaqueDataPresent"]) {
            guard object[key] is NSNull || Self.boolean(object[key]) != nil else { throw NativeBackendError.malformedEvent }
        }
        for key in Self.counts {
            guard object[key] is NSNull || Self.integer(object[key], maximum: 4096) != nil else { throw NativeBackendError.malformedEvent }
        }
        guard let nodes = Self.integer(object["visitedNodeCount"], maximum: 4096),
              let bytes = Self.integer(object["visitedByteCount"], maximum: 1_048_576) else { throw NativeBackendError.malformedEvent }
        if Self.boolean(object["querySucceeded"]) == true {
            guard object["failureStage"] is NSNull, object["failureCause"] is NSNull,
                  Self.boolean(object["queryTimedOut"]) == false,
                  Self.shapes.allSatisfy({ Self.boolean(object[$0]) != nil }),
                  Self.boolean(object["scanComplete"]) != Self.boolean(object["truncated"]) else { throw NativeBackendError.malformedEvent }
            if Self.boolean(object["truncated"]) == true {
                guard Self.counts.union(["opaqueDataPresent"]).allSatisfy({ object[$0] is NSNull }) else { throw NativeBackendError.malformedEvent }
            } else {
                guard nodes > 0, Self.boolean(object["opaqueDataPresent"]) != nil,
                      Self.counts.subtracting(["sessionCount"]).allSatisfy({ Self.integer(object[$0], maximum: 4096) != nil }) else { throw NativeBackendError.malformedEvent }
            }
        } else {
            guard let stage = Self.integer(object["failureStage"], maximum: 1000), stage > 0,
                  let cause = Self.integer(object["failureCause"], maximum: 7), cause > 0,
                  Self.boolean(object["queryTimedOut"]) == (cause == 2),
                  Self.nullable.subtracting(["failureStage", "failureCause"]).allSatisfy({ object[$0] is NSNull }),
                  Self.boolean(object["scanComplete"]) == false,
                  Self.boolean(object["truncated"]) == false, nodes == 0, bytes == 0 else { throw NativeBackendError.malformedEvent }
        }
        summary = object
    }

    func record(startedAt: TimeInterval, elapsedSeconds: TimeInterval) throws -> Data {
        guard startedAt.isFinite, elapsedSeconds.isFinite, elapsedSeconds >= 0 else { throw NativeBackendError.malformedEvent }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "startedAt": startedAt,
            "elapsedSeconds": elapsedSeconds, "formatValid": true, "refused": false, "summary": summary], options: [.sortedKeys])
    }

    static func isRefusal(stage: UInt32, cause: UInt32) -> Bool { stage == 10 && [UInt32(5), 6].contains(cause) }
    static func issueRecord(startedAt: TimeInterval, elapsedSeconds: TimeInterval,
                            refusal: (stage: UInt32, cause: UInt32)? = nil) throws -> Data {
        guard startedAt.isFinite, elapsedSeconds.isFinite, elapsedSeconds >= 0,
              refusal.map({ isRefusal(stage: $0.stage, cause: $0.cause) }) ?? true else { throw NativeBackendError.malformedEvent }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "startedAt": startedAt,
            "elapsedSeconds": elapsedSeconds, "formatValid": false, "refused": refusal != nil,
            "refusalStage": refusal.map { $0.stage as Any } ?? NSNull(),
            "refusalCause": refusal.map { $0.cause as Any } ?? NSNull(), "summary": NSNull()], options: [.sortedKeys])
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func integer(_ value: Any?, maximum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(maximum), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
}
#endif
