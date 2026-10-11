import CEiscueAutomation
import Foundation
import Testing
@testable import PhoneAgentNCM

@Suite struct XCTestSessionGuardsTests {
    @Test func authorizationMustAffirmTheExactOwnedProcessAndSession() throws {
        let uuid = UUID()
        func receipt(_ authorized: Any, processID: Int32 = 42, sessionID: UUID? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["authorized": authorized, "processID": processID,
                                                       "sessionIdentifier": (sessionID ?? uuid).uuidString])
        }
        try NCMXCTestAuthorization.validate(receipt(true), sessionID: uuid, processID: 42)
        for value: Any in [false, 1, "true", NSNull()] {
            #expect(throws: NativeBackendError.malformedEvent) {
                try NCMXCTestAuthorization.validate(receipt(value), sessionID: uuid, processID: 42)
            }
        }
        #expect(throws: NativeBackendError.malformedEvent) {
            try NCMXCTestAuthorization.validate(receipt(true, processID: 43), sessionID: uuid, processID: 42)
        }
        #expect(throws: NativeBackendError.malformedEvent) {
            try NCMXCTestAuthorization.validate(receipt(true, sessionID: UUID()), sessionID: uuid, processID: 42)
        }
        #expect(throws: NativeBackendError.malformedEvent) {
            try NCMXCTestAuthorization.validate(Data("{\"authorized\":true}".utf8), sessionID: uuid, processID: 42)
        }
    }

    @Test func pendingGeometryAndInvalidSystemValuesCannotGrantReadiness() throws {
        var state = validState()
        for phase in [EISCUE_AUTOMATION_PREPARING, EISCUE_AUTOMATION_QUERYING, EISCUE_AUTOMATION_DELIVERING,
                      EISCUE_AUTOMATION_FAILED, EISCUE_AUTOMATION_STOPPED] {
            state.phase = UInt32(phase)
            #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
        }
        state = validState(); state.scale = .nan
        #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
        state = validState(); state.bounds_width = .infinity
        #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
        state = validState(); state.orientation = 0
        #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
        state = validState(); state.revision = 0
        #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
    }

    @Test func pixelsMustMatchSystemScaleBoundsAndInterfaceOrientation() throws {
        let portrait = try NCMXCTestScreenState(validState())
        _ = try NCMXCTestLayout(width: 1179, height: 2556, screen: portrait)
        #expect(throws: NativeBackendError.coordinateSpaceChanged) {
            try NCMXCTestLayout(width: 1080, height: 1920, screen: portrait)
        }
        #expect(throws: NativeBackendError.coordinateSpaceChanged) {
            try NCMXCTestLayout(width: 2556, height: 1179, screen: portrait)
        }
        var state = validState(); state.orientation = 3; state.revision += 1
        let landscape = try NCMXCTestScreenState(state)
        _ = try NCMXCTestLayout(width: 2556, height: 1179, screen: landscape)
        #expect(throws: NativeBackendError.coordinateSpaceChanged) {
            try NCMXCTestLayout(width: 1179, height: 2556, screen: landscape)
        }
    }

    @Test func returningToTheSameSizeDoesNotReuseTheFormerGeometry() throws {
        var tracker = NCMXCTestGeometryTracker()
        let state = validState()
        let layout = try NCMXCTestLayout(width: 1179, height: 2556, screen: NCMXCTestScreenState(state))
        let original = tracker.update(lease: 1, layout: layout)
        #expect(tracker.update(lease: 1, layout: layout) == original)
        var rotated = state; rotated.orientation = 2; rotated.revision += 1
        let rotatedLayout = try NCMXCTestLayout(width: 1179, height: 2556, screen: NCMXCTestScreenState(rotated))
        #expect(tracker.update(lease: 1, layout: rotatedLayout).id != original.id)
        #expect(tracker.update(lease: 1, layout: layout).id != original.id)
        #expect(tracker.update(lease: 2, layout: layout).id != original.id)
        tracker.reset()
        #expect(tracker.current == nil)
        #expect(tracker.update(lease: 1, layout: layout).id != original.id)
    }

    private func validState() -> eiscue_automation_state {
        var state = eiscue_automation_state()
        state.phase = UInt32(EISCUE_AUTOMATION_READY); state.revision = 1; state.display_id = 1
        state.orientation = 1; state.scale = 3; state.bounds_width = 393; state.bounds_height = 852
        return state
    }
}
