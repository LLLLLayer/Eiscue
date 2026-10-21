import XCTest

/// Attaches to one explicitly launched, isolated zero-model diagnostic. It never
/// launches the App, switches VPN, repairs a connection or retries an input.
final class NetworkRecoveryAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Recovery acceptance requires an explicitly prepared physical iPhone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_REAL_NETWORK_TEST"] == "1",
              environment["EISCUE_NETWORK_RECOVERY_TEST"] == "1",
              ["coreDevice", "xcTest"].contains(environment["EISCUE_NETWORK_BACKEND"] ?? ""),
              ["idleVPNRecovery", "externalVPNLoss"].contains(environment["EISCUE_NETWORK_RECOVERY_CASE"] ?? ""),
              UUID(uuidString: environment["EISCUE_NETWORK_RECOVERY_SESSION"] ?? "") != nil else {
            throw XCTSkip("Provide the explicit recovery opt-in, backend, case and current report session UUID.")
        }
        #endif
    }

    @MainActor
    func testInspectRecoveryPhase() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let expected = ProcessInfo.processInfo.environment["EISCUE_NETWORK_RECOVERY_PHASE"] ?? "awaiting_explicit_reconnection"
        try require(["awaiting_external_vpn_loss", "awaiting_explicit_reconnection", "finished", "cleanupIncomplete"].contains(expected),
                    "Unknown expected phase.")
        let state = try readStatus(app)
        try require(state["phase"] as? String == expected, "The current diagnostic is not at the expected boundary.")
        if expected == "awaiting_explicit_reconnection" {
            try require(state["recoveryLossObserved"] as? Bool == true,
                        "No real tunnel-disconnect callback was recorded.")
            try require(state["recoveryReady"] as? Bool == false,
                        "VPN restoration must not automatically recover device readiness.")
        }
        attach(state, name: "Network recovery boundary — fixed metadata only")
    }

    @MainActor
    func testAcknowledgeUnconfirmedMediaRelease() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let before = try XCTUnwrap(snapshot(app, allowsAlert: true),
                                   "Keep the matching diagnostic and its known App notice foreground.")
        try require(["awaiting_explicit_reconnection", "finished", "cleanupIncomplete"].contains(before["phase"] as? String ?? "")
                    && before["recoveryLossObserved"] as? Bool == true
                    && before["recoveryReady"] as? Bool == false,
                    "Only the matching stopped diagnostic's unconfirmed-release notice may be acknowledged.")
        let titles = ["Couldn't complete", "暂时无法完成"]
        let bodies = ["Couldn’t confirm that the previous screen-control session closed. Pairing, VPN and conversations are preserved.",
                      "无法确认之前的屏幕控制会话已关闭。配对、VPN 和对话已保留。"]
        let title = app.staticTexts.matching(NSPredicate(format: "label IN %@", titles))
        let body = app.staticTexts.matching(NSPredicate(format: "label IN %@", bodies))
        let buttons = app.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "好", "知道了"]))
        try require(title.count == 1 && body.count == 1 && buttons.count == 1,
                    "The exact known App notice and its unique acknowledgement must be visible.")
        let acknowledge = buttons.element(boundBy: 0)
        try require(acknowledge.isEnabled && acknowledge.isHittable,
                    "The known notice cannot be acknowledged normally.")
        attach(before, name: "Unconfirmed release before acknowledgement — metadata only")
        // This closes only the visible notice. It does not confirm release,
        // repair/reconnect, resume the run, or clear the production gate.
        acknowledge.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in body.count == 0 }, object: nil)
        try require(XCTWaiter.wait(for: [dismissed], timeout: 5) == .completed,
                    "The single acknowledgement did not dismiss the known notice.")
    }

    @MainActor
    func testVerifyReconnectedOwnedTarget() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let before = try readStatus(app)
        try require(before["phase"] as? String == "awaiting_explicit_reconnection"
                    && before["recoveryLossObserved"] as? Bool == true
                    && before["recoveryReady"] as? Bool == true,
                    "Use the ordinary explicit Repair/Connect path first; this helper never starts a connection.")
        let verify = app.buttons["networkRecoveryVerifyButton"]
        try require(verify.exists && verify.isEnabled && verify.isHittable,
                    "The explicit owned-target verification control is unavailable.")
        attach(before, name: "Network recovery before explicit verification")
        verify.tap()
        let terminal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = self.snapshot(app) else { return false }
            return ["finished", "cleanupIncomplete"].contains(value["phase"] as? String ?? "")
        }, object: nil)
        // Includes the original 125-second native cleanup bound. This is one
        // observation/input attempt; a terminal failure is never retried.
        try require(XCTWaiter.wait(for: [terminal], timeout: 240) == .completed,
                    "The bounded recovery verification/cleanup did not settle.")
        let after = try readStatus(app)
        attach(after, name: "Network recovery after explicit verification")
        try require(after["phase"] as? String == "finished" && after["state"] as? String == "passed",
                    "Recovery did not confirm all requested checks and final cleanup; inspect its metadata report.")
    }

    @MainActor
    private func readStatus(_ app: XCUIApplication) throws -> [String: Any] {
        try XCTUnwrap(snapshot(app), "Keep the matching session/backend/case diagnostic foreground without alerts; this helper does not launch it.")
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, allowsAlert: Bool = false) -> [String: Any]? {
        guard app.state == .runningForeground, allowsAlert || app.alerts.count == 0 else { return nil }
        let status = app.staticTexts["networkRunAcceptanceState"]
        guard status.exists, let value = status.value as? String,
              let decoded = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] else { return nil }
        let environment = ProcessInfo.processInfo.environment
        guard let session = (decoded["sessionID"] as? String).flatMap(UUID.init(uuidString:)),
              session == environment["EISCUE_NETWORK_RECOVERY_SESSION"].flatMap(UUID.init(uuidString:)),
              decoded["route"] as? String == "localVPN",
              decoded["backend"] as? String == environment["EISCUE_NETWORK_BACKEND"],
              decoded["acceptanceCase"] as? String == environment["EISCUE_NETWORK_RECOVERY_CASE"] else { return nil }
        return decoded
    }

    private func attach(_ metadata: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { XCTFail(message); throw CheckFailure.unmet }
    }
    private enum CheckFailure: Error { case unmet }
}
