import Foundation

/// The original ReplayKit orientation. JPEG pixels are already rotated/mirrored
/// into display order; callers must not apply this orientation a second time.
public enum ScreenBroadcastOrientation: UInt32, Codable, Sendable, CaseIterable {
    case up = 1, upMirrored = 2, down = 3, downMirrored = 4
    case leftMirrored = 5, right = 6, rightMirrored = 7, left = 8
}

public enum ScreenBroadcastPhase: String, Codable, Sendable {
    case idle, starting, active, paused, ended, stale, unavailable
}

public struct ScreenBroadcastState: Sendable, Equatable {
    public let phase: ScreenBroadcastPhase
    public let sessionID: UUID?
    public let updatedAt: Date?
    public let frameID: UUID?
    public let orientation: ScreenBroadcastOrientation?
    public let width: Int?
    public let height: Int?
    public var isActive: Bool { phase == .active }
}

public enum ScreenBroadcastError: Error, Sendable {
    case unavailable, inactive, staleFrame, invalidFrame, sessionChanged
}

/// A single, bounded frame exchanged with the broadcast extension. The extension
/// compiles this file directly so it does not link the device-control backend.
public struct ScreenBroadcastFrame: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let frameID: UUID
    public let capturedAt: Date
    public let capturedUptime: TimeInterval
    public let orientation: ScreenBroadcastOrientation
    public let width: Int
    public let height: Int
    public let jpegData: Data
}

/// The stored frame and the latest time it was known to be the current screen.
/// ReplayKit delivers no buffers while the display is unchanged, so a live
/// extension heartbeat can confirm an older frame instead of letting it expire.
public struct ScreenBroadcastReading: Sendable, Equatable {
    public let frame: ScreenBroadcastFrame
    public let confirmedAt: Date
    public let confirmedUptime: TimeInterval
}

/// Shared, local-only latest-frame storage. Only the ReplayKit extension writes
/// sessions/frames. The host can read them and request a session-specific stop.
/// Every state transition replaces one atomic record, so a paused/ended session
/// cannot expose the previous frame. No image history is retained.
public struct ScreenBroadcastStore: Sendable {
    public static let defaultAppGroupIdentifier = "group.org.eiscue.app"
    public static let broadcastExtensionBundleIdentifier = "org.eiscue.app.broadcast"
    public static var configuredAppGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "EiscueScreenBroadcastAppGroup") as? String ?? defaultAppGroupIdentifier
    }
    public static let maximumFrameBytes = 1_500_000
    public static let maximumFrameAge: TimeInterval = 3
    public static let maximumPixelDimension = 1600

    private let directory: URL
    private var recordURL: URL { directory.appendingPathComponent("latest.plist") }
    private var stopURL: URL { directory.appendingPathComponent("stop.plist") }
    private var heartbeatURL: URL { directory.appendingPathComponent("heartbeat.plist") }

    public init(appGroupIdentifier: String = configuredAppGroupIdentifier) throws {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw ScreenBroadcastError.unavailable
        }
        self.init(containerURL: container)
    }

    /// Use an isolated directory when embedding the Kit or validating the store.
    public init(containerURL: URL) {
        directory = containerURL.appendingPathComponent("ScreenBroadcast", isDirectory: true)
    }

    public func state() -> ScreenBroadcastState {
        do {
            guard FileManager.default.fileExists(atPath: recordURL.path) else {
                return state(phase: .idle)
            }
            let record = try readRecord()
            let currentPhase: ScreenBroadcastPhase
            if try stopRequested(sessionID: record.sessionID) {
                currentPhase = .ended
            } else if record.phase == .active {
                // A live heartbeat proves the extension is still sharing even
                // when an unchanged screen produces no new frame.
                currentPhase = isFresh(record.frame, maximumAge: Self.maximumFrameAge) || liveHeartbeat(for: record) != nil
                    ? .active : .stale
            } else if record.phase == .starting && !freshUptime(record.updatedUptime, maximumAge: 10) {
                currentPhase = .stale
            } else {
                currentPhase = record.phase
            }
            return state(phase: currentPhase, record: record)
        } catch {
            // This also fails closed while protected files cannot be opened.
            return state(phase: .unavailable)
        }
    }

    public func readFrame(maximumAge: TimeInterval = maximumFrameAge) throws -> ScreenBroadcastFrame {
        let record = try readRecord()
        guard record.phase == .active, !(try stopRequested(sessionID: record.sessionID)) else {
            throw ScreenBroadcastError.inactive
        }
        guard let frame = record.frame, frame.sessionID == record.sessionID else {
            throw ScreenBroadcastError.sessionChanged
        }
        guard isFresh(frame, maximumAge: min(maximumAge, Self.maximumFrameAge)) else {
            throw ScreenBroadcastError.staleFrame
        }
        try validate(frame)
        return frame
    }

    /// The stored frame while it is still the current screen: either recently
    /// published, or confirmed by a heartbeat that names this frame and reports
    /// no newer buffer waiting to be published.
    public func readCurrentFrame() throws -> ScreenBroadcastReading {
        let record = try readRecord()
        guard record.phase == .active, !(try stopRequested(sessionID: record.sessionID)) else {
            throw ScreenBroadcastError.inactive
        }
        guard let frame = record.frame, frame.sessionID == record.sessionID else {
            throw ScreenBroadcastError.sessionChanged
        }
        try validate(frame)
        var reading = isFresh(frame, maximumAge: Self.maximumFrameAge)
            ? ScreenBroadcastReading(frame: frame, confirmedAt: frame.capturedAt, confirmedUptime: frame.capturedUptime) : nil
        if let heartbeat = liveHeartbeat(for: record), heartbeat.frameID == frame.frameID, !heartbeat.newerFramePending,
           heartbeat.uptime > reading?.confirmedUptime ?? -.infinity {
            reading = ScreenBroadcastReading(frame: frame, confirmedAt: heartbeat.date, confirmedUptime: heartbeat.uptime)
        }
        guard let reading else { throw ScreenBroadcastError.staleFrame }
        return reading
    }

    /// Stops reads immediately. The extension checks this signal even when no
    /// video arrives, then asks ReplayKit to end the system broadcast.
    public func requestStop() throws {
        let record = try readRecord()
        try write(StopRequest(sessionID: record.sessionID), to: stopURL)
    }

    @discardableResult
    public func beginSession() throws -> UUID {
        let sessionID = UUID()
        try write(Record(sessionID: sessionID, phase: .starting), to: recordURL)
        // Any stop left by an older session is deliberately harmless.
        return sessionID
    }

    @discardableResult
    public func publish(jpegData: Data, width: Int, height: Int,
                        orientation: ScreenBroadcastOrientation, sessionID: UUID) throws -> UUID {
        let current = try matchingRecord(sessionID)
        guard current.phase == .starting || current.phase == .active,
              !(try stopRequested(sessionID: sessionID)) else { throw ScreenBroadcastError.inactive }
        // Repeated buffers can contain identical screen pixels. Preserve only
        // the immediately preceding identity; A -> B -> A must not revive A.
        let previous = current.phase == .active ? current.frame : nil
        let isUnchanged = previous?.sessionID == sessionID && previous?.width == width
            && previous?.height == height && previous?.orientation == orientation && previous?.jpegData == jpegData
        let frame = ScreenBroadcastFrame(sessionID: sessionID, frameID: isUnchanged ? previous!.frameID : UUID(), capturedAt: Date(),
            capturedUptime: ProcessInfo.processInfo.systemUptime, orientation: orientation,
            width: width, height: height, jpegData: jpegData)
        try validate(frame)
        try write(Record(sessionID: sessionID, phase: .active, frame: frame), to: recordURL)
        return frame.frameID
    }

    /// Written by the extension on its own timer, independent of video delivery.
    /// The host ignores heartbeats from other sessions or for other frames, so
    /// this small write never needs to reread the frame record.
    public func heartbeat(sessionID: UUID, frameID: UUID?, newerFramePending: Bool) throws {
        try write(Heartbeat(sessionID: sessionID, frameID: frameID, newerFramePending: newerFramePending), to: heartbeatURL)
    }

    public func setPaused(_ paused: Bool, sessionID: UUID) throws {
        _ = try matchingRecord(sessionID)
        try write(Record(sessionID: sessionID, phase: paused ? .paused : .starting), to: recordURL)
    }

    public func finishSession(sessionID: UUID) throws {
        _ = try matchingRecord(sessionID)
        try write(Record(sessionID: sessionID, phase: .ended), to: recordURL)
    }

    public func stopRequested(sessionID: UUID) throws -> Bool {
        guard FileManager.default.fileExists(atPath: stopURL.path) else { return false }
        return try read(StopRequest.self, from: stopURL, maximumBytes: 4096).sessionID == sessionID
    }

    private struct Record: Codable {
        var schemaVersion = 1
        let sessionID: UUID
        let phase: ScreenBroadcastPhase
        var updatedAt = Date()
        var updatedUptime = ProcessInfo.processInfo.systemUptime
        var frame: ScreenBroadcastFrame?
    }

    private struct StopRequest: Codable { let sessionID: UUID }

    private struct Heartbeat: Codable {
        var schemaVersion = 1
        let sessionID: UUID
        let frameID: UUID?
        let newerFramePending: Bool
        var date = Date()
        var uptime = ProcessInfo.processInfo.systemUptime
    }

    /// A missing, unreadable, old, or other-session heartbeat confirms nothing.
    private func liveHeartbeat(for record: Record) -> Heartbeat? {
        guard record.phase == .active, FileManager.default.fileExists(atPath: heartbeatURL.path),
              let heartbeat = try? read(Heartbeat.self, from: heartbeatURL, maximumBytes: 4096),
              heartbeat.schemaVersion == 1, heartbeat.sessionID == record.sessionID,
              freshUptime(heartbeat.uptime, maximumAge: Self.maximumFrameAge),
              Date().timeIntervalSince(heartbeat.date) >= -1,
              Date().timeIntervalSince(heartbeat.date) <= Self.maximumFrameAge else { return nil }
        return heartbeat
    }

    private func matchingRecord(_ sessionID: UUID) throws -> Record {
        let record = try readRecord()
        guard record.sessionID == sessionID else { throw ScreenBroadcastError.sessionChanged }
        return record
    }

    private func readRecord() throws -> Record {
        let record = try read(Record.self, from: recordURL, maximumBytes: Self.maximumFrameBytes + 16_384)
        guard record.schemaVersion == 1,
              [.starting, .active, .paused, .ended].contains(record.phase) else {
            throw ScreenBroadcastError.invalidFrame
        }
        if let frame = record.frame {
            guard record.phase == .active, frame.sessionID == record.sessionID else {
                throw ScreenBroadcastError.sessionChanged
            }
            try validate(frame)
        } else if record.phase == .active {
            throw ScreenBroadcastError.invalidFrame
        }
        return record
    }

    private func isFresh(_ frame: ScreenBroadcastFrame?, maximumAge: TimeInterval) -> Bool {
        guard let frame, maximumAge.isFinite, maximumAge > 0 else { return false }
        return freshUptime(frame.capturedUptime, maximumAge: maximumAge)
            && Date().timeIntervalSince(frame.capturedAt) >= -1
            && Date().timeIntervalSince(frame.capturedAt) <= maximumAge
    }

    private func freshUptime(_ uptime: TimeInterval, maximumAge: TimeInterval) -> Bool {
        let age = ProcessInfo.processInfo.systemUptime - uptime
        return age.isFinite && age >= 0 && age <= maximumAge
    }

    private func validate(_ frame: ScreenBroadcastFrame) throws {
        guard frame.width > 1, frame.height > 1,
              frame.width <= Self.maximumPixelDimension, frame.height <= Self.maximumPixelDimension,
              frame.jpegData.count >= 4, frame.jpegData.count <= Self.maximumFrameBytes,
              frame.jpegData.prefix(2) == Data([0xff, 0xd8]),
              frame.jpegData.suffix(2) == Data([0xff, 0xd9]) else {
            throw ScreenBroadcastError.invalidFrame
        }
    }

    private func state(phase: ScreenBroadcastPhase, record: Record? = nil) -> ScreenBroadcastState {
        ScreenBroadcastState(phase: phase, sessionID: record?.sessionID, updatedAt: record?.updatedAt,
            frameID: record?.frame?.frameID, orientation: record?.frame?.orientation,
            width: record?.frame?.width, height: record?.frame?.height)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL, maximumBytes: Int) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw ScreenBroadcastError.invalidFrame
        }
        // Do not memory-map or hold open protected files across device locking.
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw ScreenBroadcastError.invalidFrame }
        return try PropertyListDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceURL = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try resourceURL.setResourceValues(resources)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        #if os(iOS)
        // Reopening a frame fails when the device is locked. ReplayKit can still
        // replace/delete its latest file while shutting down a paused broadcast.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
