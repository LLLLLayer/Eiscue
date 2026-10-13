import Foundation
import Testing
@testable import EiscueDeviceKit

@Suite("Board companion protocol")
struct BluetoothCompanionTests {
    @Test func statusUsesTheFixedVersionedPacketWithoutText() {
        let status = BluetoothCompanionStatus(phase: .acting, language: .simplifiedChinese, completedActions: 0x1234)
        #expect([UInt8](status.packet) == [1, 6, 1, 0, 0x34, 0x12, 0, 0, 0, 0, 0, 0])
        #expect(BluetoothCompanionStatus.Phase.allCases.map(\.rawValue) == Array(UInt8(0)...10))
    }

    @Test func updatesCoalesceRespectCommandsAndHeartbeatWhileIdle() throws {
        var queue = BluetoothCompanionUpdateQueue()
        let ready = BluetoothCompanionStatus(phase: .ready, language: .english)
        let thinking = BluetoothCompanionStatus(phase: .thinking, language: .english)
        let acting = BluetoothCompanionStatus(phase: .acting, language: .english, completedActions: 2)
        queue.update(ready)
        #expect(queue.takePacket(now: 10, inputBusy: true) == nil)
        #expect(queue.takePacket(now: 10, inputBusy: false) == ready.packet)
        queue.update(thinking); queue.update(acting)
        #expect(queue.takePacket(now: 11, inputBusy: false) == nil)
        queue.acknowledge()
        #expect(queue.takePacket(now: 10.1, inputBusy: false) == nil)
        #expect(queue.takePacket(now: 10.25, inputBusy: false) == acting.packet)
        queue.acknowledge(); queue.update(ready)
        #expect(queue.takePacket(now: 11, inputBusy: false) == ready.packet)
        queue.acknowledge()
        #expect(queue.takePacket(now: 15.99, inputBusy: false) == nil)
        #expect(queue.takePacket(now: 16, inputBusy: false) == ready.packet)
        queue.reset()
        #expect(!queue.isWriting)
        #expect(queue.takePacket(now: 30, inputBusy: false) == nil)
    }

    @Test func stopIsLatchedAndDeduplicatedAcrossReconnectUntilAnExplicitClear() throws {
        let board = UUID()
        var state = BluetoothCompanionStopState()
        #expect(!state.isKnown)
        let received = try state.receive(Data([1, 1, 0x34, 0x12]), boardID: board)
        let event = try #require(received)
        #expect(event.boardID == board && event.generation == 0x1234)
        #expect(state.isKnown && state.isLatched)
        #expect(try state.receive(Data([1, 1, 0x34, 0x12]), boardID: board) == nil)
        state.beginConnection()
        #expect(!state.isKnown && state.isLatched)
        #expect(try state.receive(Data([1, 1, 0x34, 0x12]), boardID: board) == nil)
        #expect(try state.receive(Data([1, 0, 0x34, 0x12]), boardID: board) == nil)
        #expect(state.isLatched)
        state.beginConnection()
        #expect(try state.receive(Data([1, 0, 0x34, 0x12]), boardID: board) == nil)
        #expect(state.isKnown && !state.isLatched)
        #expect(try state.receive(Data([1, 1, 0x35, 0x12]), boardID: board)?.generation == 0x1235)
        #expect(try state.receive(Data([1, 1, 0x35, 0x12]), boardID: UUID()) != nil)
    }

    @Test func malformedStopCannotClearAnExistingLatch() throws {
        let board = UUID()
        var state = BluetoothCompanionStopState()
        _ = try state.receive(Data([1, 1, 1, 0]), boardID: board)
        for bytes: [UInt8] in [[1, 0, 1], [2, 0, 1, 0], [1, 2, 1, 0], [1, 0, 1, 0, 0]] {
            #expect(throws: BluetoothBoardError.malformedReply) { try state.receive(Data(bytes), boardID: board) }
            #expect(state.isLatched)
        }
    }

    @Test func pollingRecoversAMissedStopNotificationWithoutDuplicatingTheEvent() throws {
        let board = UUID()
        var state = BluetoothCompanionStopState(), polling = BluetoothCompanionStopPolling()
        #expect(polling.begin(now: 0, inputBusy: false) != nil)
        #expect(try state.receive(Data([1, 0, 0, 0]), boardID: board) == nil)
        polling.received()
        // The board stops without a notification. The next idle ATT read still
        // retrieves its latch, using the same decoder and callback event.
        #expect(polling.begin(now: 0.99, inputBusy: false) == nil)
        #expect(polling.begin(now: 1, inputBusy: true) == nil)
        #expect(polling.begin(now: 1.25, inputBusy: false) != nil)
        #expect(polling.begin(now: 2.25, inputBusy: false) == nil)
        let recovered = try state.receive(Data([1, 1, 1, 0]), boardID: board)
        polling.received()
        let event = try #require(recovered)
        #expect(event.boardID == board && event.generation == 1 && state.isLatched)
        #expect(try state.receive(Data([1, 1, 1, 0]), boardID: board) == nil)
    }

    @Test func stopReadDeadlineIsBoundedAndRetiredCallbacksCannotCloseANewConnection() throws {
        var polling = BluetoothCompanionStopPolling()
        let initial = polling.begin(now: 10, inputBusy: false)
        let first = try #require(initial)
        #expect(!polling.isExpired(first, now: 14.99))
        #expect(polling.isExpired(first, now: 15))
        polling.reset()
        let reconnected = polling.begin(now: 20, inputBusy: false)
        let second = try #require(reconnected)
        #expect(!polling.isExpired(first, now: 25))
        #expect(polling.isExpired(second, now: 25))
        polling.received()
        #expect(!polling.isExpired(second, now: 30))
    }
}
