import Foundation

/// A compact, non-sensitive summary for an optional board display. The host
/// supplies the language and confirmed action count; no task text is transferred.
public struct BluetoothCompanionStatus: Sendable, Equatable {
    public enum Phase: UInt8, Sendable, CaseIterable {
        case idle, needsScreenSharing, needsCalibration, ready, thinking, observing, acting, waiting, completed, failed, stopped

    }
    public enum Language: UInt8, Sendable { case english, simplifiedChinese }

    public let phase: Phase
    public let language: Language
    public let completedActions: UInt16

    public init(phase: Phase, language: Language, completedActions: UInt16 = 0) {
        self.phase = phase; self.language = language; self.completedActions = completedActions
    }

    var packet: Data {
        Data([1, phase.rawValue, language.rawValue, 0, UInt8(truncatingIfNeeded: completedActions),
              UInt8(completedActions >> 8), 0, 0, 0, 0, 0, 0])
    }
}

/// The generation is local to a board. Repeated read/notification deliveries of
/// the same latched stop produce one callback; the latch still rejects input.
public struct BluetoothHardwareStopEvent: Sendable, Equatable {
    public let boardID: UUID
    public let generation: UInt16
}

struct BluetoothCompanionStopState {
    private(set) var isKnown = false
    private(set) var isLatched = false
    private var lastEvent: BluetoothHardwareStopEvent?

    mutating func beginConnection() { isKnown = false }

    mutating func receive(_ data: Data, boardID: UUID) throws -> BluetoothHardwareStopEvent? {
        let bytes = [UInt8](data)
        guard bytes.count == 4, bytes[0] == 1, bytes[1] <= 1 else { throw BluetoothBoardError.malformedReply }
        // Unlock requires a new connection. A late initial read or an unlock
        // notification just before disconnect must not authorize old input.
        if isKnown, isLatched, bytes[1] == 0 { return nil }
        isKnown = true; isLatched = bytes[1] == 1
        guard isLatched else { lastEvent = nil; return nil }
        let event = BluetoothHardwareStopEvent(boardID: boardID, generation: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
        guard event != lastEvent else { return nil }
        lastEvent = event
        return event
    }
}

/// One latest value and one in-flight write. Status traffic never enters the HID
/// command queue, and a stuck ATT write is disabled instead of being replayed.
struct BluetoothCompanionUpdateQueue {
    private var latest: BluetoothCompanionStatus?
    private var sent: BluetoothCompanionStatus?
    private var sentAt: TimeInterval = -.infinity
    private(set) var isWriting = false

    mutating func update(_ status: BluetoothCompanionStatus) { latest = status }

    mutating func takePacket(now: TimeInterval, inputBusy: Bool) -> Data? {
        guard !inputBusy, !isWriting, now.isFinite, let latest,
              now - sentAt >= 0.25,
              latest != sent || now - sentAt >= 5 else { return nil }
        sent = latest; sentAt = now; isWriting = true
        return latest.packet
    }

    mutating func acknowledge() { isWriting = false }
    mutating func reset() { self = Self() }
}

/// AB9 reads recover a missed notification independently of HID commands. Each
/// deadline belongs to one read; a retired connection cannot time out a new one.
struct BluetoothCompanionStopPolling {
    struct Read: Sendable, Equatable {
        let id = UUID()
        let startedAt: TimeInterval
    }
    private(set) var pending: Read?
    private var nextReadAt: TimeInterval = -.infinity

    mutating func begin(now: TimeInterval, inputBusy: Bool) -> Read? {
        guard !inputBusy, pending == nil, now.isFinite, now >= nextReadAt else { return nil }
        let read = Read(startedAt: now)
        pending = read; nextReadAt = now + 1
        return read
    }

    // CoreBluetooth delivers read replies and notifications through the same
    // callback. Either valid sample confirms the stop state; latches only clear
    // across connections, so a late sample cannot undo a newer stop.
    mutating func received() { pending = nil }
    func isExpired(_ read: Read, now: TimeInterval) -> Bool {
        pending == read && now - read.startedAt >= 5
    }
    mutating func reset() { self = Self() }
}
