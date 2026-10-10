import Foundation
import Testing
@testable import EiscueDeviceKit

@Suite @MainActor struct MediaReleaseTests {
    @Test func remoteStopPrecedesTransportClose() async {
        let state = ReleaseFixture()
        let confirmed = await BoundedMediaRelease.run(timeout: .seconds(1), stop: {
            state.events.append("stop")
            try await Task.sleep(for: .milliseconds(10))
            state.events.append("ack")
        }, close: { state.events.append("close") })
        #expect(confirmed)
        #expect(state.events == ["stop", "ack", "close"])
    }

    @Test func timeoutClosesTransportWithoutWaitingForUncooperativeStop() async {
        let state = ReleaseFixture()
        let started = ContinuousClock.now
        let confirmed = await BoundedMediaRelease.run(timeout: .milliseconds(25), stop: {
            state.events.append("stop")
            await withCheckedContinuation { state.waiter = $0 }
            state.events.append("late-ack")
        }, close: {
            state.events.append("close")
            state.waiter?.resume(); state.waiter = nil
        })
        #expect(!confirmed)
        #expect(started.duration(to: .now) < .seconds(1))
        await Task.yield()
        #expect(state.events.filter { $0 == "close" }.count == 1)
        #expect(state.events.first == "stop")
    }

    @Test func failedStopIsUnconfirmedAndStillCloses() async {
        let state = ReleaseFixture()
        let confirmed = await BoundedMediaRelease.run(stop: {
            throw DeviceControlError.connection("fixture failure")
        }, close: { state.events.append("close") })
        #expect(!confirmed)
        #expect(state.events == ["close"])
    }

    @Test func callerCancellationDoesNotSkipCleanup() async {
        let state = ReleaseFixture()
        let task = Task { @MainActor in
            await BoundedMediaRelease.run(timeout: .seconds(1), stop: {
                state.events.append("stop")
                try await Task.sleep(for: .milliseconds(20))
                state.events.append("ack")
            }, close: { state.events.append("close") })
        }
        task.cancel()
        #expect(await task.value)
        #expect(state.events == ["stop", "ack", "close"])
    }

    @Test func lateOldCleanupCannotCloseAnotherSession() async {
        let old = ReleaseFixture(), new = ReleaseFixture()
        let confirmed = await BoundedMediaRelease.run(timeout: .milliseconds(10), stop: {
            await withCheckedContinuation { old.waiter = $0 }
        }, close: { old.events.append("close"); old.waiter?.resume(); old.waiter = nil })
        new.events.append("ready")
        await Task.yield()
        #expect(!confirmed)
        #expect(old.events == ["close"])
        #expect(new.events == ["ready"])
    }
}

@MainActor private final class ReleaseFixture {
    var events: [String] = []
    var waiter: CheckedContinuation<Void, Never>?
}
