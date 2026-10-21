import XCTest

/// Exposes the system surface for the separate, bounded Eiscue-card inspector.
/// It neither reads other notifications nor treats a gesture as acceptance.
final class SystemTaskPresentationUITests: XCTestCase {
    @MainActor
    func testExposeNotificationCenterForEiscueTask() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the explicitly selected physical test phone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_SYSTEM_TASK_TEST"] == "1",
              environment["EISCUE_SYSTEM_TASK_ACTION"] == "reveal" else {
            throw XCTSkip("Opt in to the separate system-surface gesture.")
        }
        #endif
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard [.runningBackground, .runningBackgroundSuspended].contains(app.state),
              springboard.alerts.count == 0 else {
            XCTFail("Keep Eiscue in the background and resolve system dialogs separately.")
            return
        }
        let frame = springboard.frame
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 200, frame.height > 400 else {
            XCTFail("The observed system display geometry is unavailable.")
            return
        }
        let startedAt = Date().timeIntervalSince1970
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let top = origin.withOffset(CGVector(dx: frame.width * 0.25, dy: 2))
        let end = origin.withOffset(CGVector(dx: frame.width * 0.25, dy: frame.height * 0.8))
        top.press(forDuration: 0.1, thenDragTo: end)
        let metadata = "helper=revealNotificationCenter\nstartedAt=\(startedAt)\nfinishedAt=\(Date().timeIntervalSince1970)\ngestureAttempts=1\nunrelatedContentRead=false\nimageAttached=false\nappAcceptanceVerified=false"
        let attachment = XCTAttachment(string: metadata)
        attachment.name = "System task surface gesture — metadata"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue([.runningBackground, .runningBackgroundSuspended].contains(app.state))
    }

    @MainActor
    func testInspectOnlyEiscueTerminalNotification() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the explicitly selected physical test phone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_SYSTEM_TASK_TEST"] == "1",
              environment["EISCUE_SYSTEM_TASK_ACTION"] == "inspectNotification" else {
            throw XCTSkip("Opt in to the fixed Eiscue terminal-notification inspection.")
        }
        #endif
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard [.runningBackground, .runningBackgroundSuspended].contains(app.state),
              springboard.alerts.count == 0 else {
            XCTFail("Keep Eiscue backgrounded with the system surface already visible.")
            return
        }
        let titles = ["Eiscue task update", "Eiscue 任务进展"]
        let statuses = [
            "Task complete. Open Eiscue to view the result.",
            "Task interrupted. Open Eiscue to view its progress.",
            "Task failed. Open Eiscue to see what happened.",
            "Task paused. Open Eiscue to review and continue.",
            "任务已完成。打开 Eiscue 查看结果。", "任务已中断。打开 Eiscue 查看进展。",
            "任务运行失败。打开 Eiscue 查看原因。", "任务已暂停。打开 Eiscue 查看进展并继续。"
        ]
        let titleQuery = springboard.staticTexts.matching(NSPredicate(format: "label IN %@", titles))
        let statusQuery = springboard.staticTexts.matching(NSPredicate(format: "label IN %@", statuses))
        let titleCount = titleQuery.count, statusCount = statusQuery.count
        let visibleTitles = titleCount <= 8 ? titleQuery.allElementsBoundByIndex.filter(\.isHittable).count : 0
        let visibleStatuses = statusCount <= 8 ? statusQuery.allElementsBoundByIndex.filter(\.isHittable).count : 0
        let metadata = "helper=inspectEiscueTerminalNotification\nobservedAt=\(Date().timeIntervalSince1970)\nknownTitleCount=\(titleCount)\nvisibleKnownTitleCount=\(visibleTitles)\nknownStatusCount=\(statusCount)\nvisibleKnownStatusCount=\(visibleStatuses)\nrunIDCorrelationAvailable=false\nimageAttached=false\nunrelatedContentRead=false"
        let attachment = XCTAttachment(string: metadata)
        attachment.name = "Eiscue terminal notification — metadata"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Exact notification identifiers must be correlated independently in
        // the App report; these fixed UI labels contain no run identifier.
        XCTAssertEqual(visibleTitles, 1)
        XCTAssertGreaterThanOrEqual(visibleStatuses, 1)
    }
}
