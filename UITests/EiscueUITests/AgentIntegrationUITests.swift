import Network
import XCTest

/// Most cases need Scripts/test-model-server.py; the mixed-round regression
/// owns its server in the UI runner so it also works on a physical iPhone.
/// The runtime is the real Pi engine; only the model endpoint is replaced.
final class AgentIntegrationUITests: XCTestCase {
    @MainActor private func launch(reset: Bool = true, timeline: Bool = false,
                                   fixtureURL: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if reset { app.launchArguments.append("--reset-state") }
        if timeline { app.launchArguments.append("--tool-timeline-fixture") }
        app.launchEnvironment["EISCUE_TEST_MODEL_URL"] = (fixtureURL ?? modelFixtureURL()).absoluteString
        app.launch()
        return app
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap(); input.typeText(text)
        app.buttons["sendMessageButton"].tap()
    }

    @MainActor func testRealRuntimeStreamsAndPersistsAcrossLaunches() throws {
        var app = launch()
        send("Plan a calm morning", in: app)
        XCTAssertTrue(app.staticTexts["Fixture response: Plan a calm morning"].waitForExistence(timeout: 20))
        waitUntilIdle(in: app)
        XCTAssertFalse(app.staticTexts["本轮已结束"].exists)
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(app.staticTexts["Fixture response: Plan a calm morning"].waitForExistence(timeout: 10))
        send("Next step", in: app)
        XCTAssertTrue(app.staticTexts["Fixture response: Next step"].waitForExistence(timeout: 20))
        openSidebar(in: app)
        app.buttons["newConversationButton"].tap()
        openSidebar(in: app)
        let row = conversationRow(titled: "Plan a calm morning", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        app.buttons["deleteConversationButton"].tap()
        app.buttons["confirmDeleteConversationsButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["还没有对话"].waitForExistence(timeout: 5))
    }

    @MainActor func testStopDoesNotAutomaticallyResumeOnLaunch() throws {
        var app = launch()
        send("slow fixture", in: app)
        XCTAssertTrue(app.buttons["stopRunButton"].waitForExistence(timeout: 15))
        app.buttons["stopRunButton"].tap()
        XCTAssertTrue(app.buttons["resumeRunButton"].waitForExistence(timeout: 10))
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(app.buttons["resumeRunButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["stopRunButton"].exists)
        app.buttons["结束任务"].tap()
        XCTAssertTrue(app.buttons["sendMessageButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
    }

    @MainActor func testAuthenticationFailureKeepsAppAndDraftUsable() throws {
        assertServiceFailureCanRecover(prompt: "unauthorized fixture", error: "Fixture authentication failed")
    }

    @MainActor func testServerFailureKeepsAppAndDraftUsable() throws {
        assertServiceFailureCanRecover(prompt: "unavailable fixture", error: "Fixture service unavailable")
    }

    @MainActor private func assertServiceFailureCanRecover(prompt: String, error: String,
                                                          file: StaticString = #filePath, line: UInt = #line) {
        let app = launch()
        send(prompt, in: app)
        let detail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", error)).firstMatch
        guard detail.waitForExistence(timeout: 20) else {
            XCTFail("Expected a visible service error without terminating the app", file: file, line: line)
            return
        }
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                            object: app.buttons["stopRunButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed, file: file, line: line)
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertNotEqual(input.value as? String, prompt, "A submitted message stays on the transcript after a service failure.", file: file, line: line)
        XCTAssertTrue(app.staticTexts[prompt].exists, file: file, line: line)
        XCTAssertFalse(app.debugDescription.contains("local-fixture-key"),
                       "A provider error must not expose the configured credential", file: file, line: line)

        // No relaunch or direct state reset: the failed app session must still
        // allow ordinary navigation and another real model request.
        openSidebar(in: app)
        let newConversation = app.buttons["newConversationButton"]
        XCTAssertTrue(newConversation.isEnabled, file: file, line: line)
        newConversation.tap()
        send("Conversation after service failure", in: app)
        XCTAssertTrue(app.staticTexts["Fixture response: Conversation after service failure"].waitForExistence(timeout: 20),
                      file: file, line: line)
        waitUntilIdle(in: app, file: file, line: line)
        XCTAssertFalse(app.staticTexts["本轮已结束"].exists, file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    }

    @MainActor func testSendClearsComposerBeforeStreamFinishes() async throws {
        let app = launch()
        let field = app.textFields["messageInput"]
        let input = field.exists ? field : app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let emptyValue = input.value as? String
        send("streaming ui fixture", in: app)
        XCTAssertTrue(app.staticTexts["streaming ui fixture"].waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, emptyValue)
        XCTAssertTrue(app.descendants(matching: .any)["assistantReplyIndicator"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Streaming response"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Streaming response arrived incrementally and is now complete."].exists,
                       "The response must be visible before its final chunk.")
        XCTAssertTrue(app.buttons["stopRunButton"].exists)
        _ = try await URLSession.shared.data(from: modelFixtureURL("/fixture/release-stream"))
        XCTAssertTrue(app.staticTexts["Streaming response arrived incrementally and is now complete."].waitForExistence(timeout: 15))
        waitUntilIdle(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["assistantReplyIndicator"].exists)
    }

    @MainActor func testRealToolActivityInterleavesAndSurvivesRelaunch() {
        var app = launch(timeline: true)
        send("timeline fixture", in: app)
        XCTAssertTrue(app.staticTexts["I will inspect the file first."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 15))
        waitUntilIdle(in: app)
        assertTimeline(in: app)
        app.terminate()
        app = launch(reset: false, timeline: true)
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 10))
        assertTimeline(in: app)
        XCTAssertFalse(app.staticTexts["本轮已结束"].exists)
    }

    @MainActor func testToolPauseRequiresExplicitContinuationAcrossRelaunch() {
        var app = launch(timeline: true)
        send("tool pause fixture", in: app)
        XCTAssertTrue(app.buttons["continuePausedRunButton"].waitForExistence(timeout: 15))
        waitUntilIdle(in: app)
        XCTAssertTrue(app.buttons["endPausedRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        XCTAssertTrue(app.staticTexts["任务暂无进展。请查看屏幕，再继续任务或补充说明。"].exists)

        app.terminate()
        app = launch(reset: false, timeline: true)
        let continueButton = app.buttons["continuePausedRunButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        let automaticStart = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                       object: app.buttons["stopRunButton"])
        automaticStart.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [automaticStart], timeout: 2), .completed,
                       "Reopening the conversation must not restart the paused task.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 1)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)

        continueButton.tap()
        let continuation = "从当前画面继续我刚才的任务。先重新查看屏幕，确认哪些步骤已经完成；如果之前的操作没有进展，请换一种方式。"
        XCTAssertTrue(app.staticTexts["Fixture response: " + continuation].waitForExistence(timeout: 20))
        waitUntilIdle(in: app)
        XCTAssertTrue(app.staticTexts[continuation].exists)
        XCTAssertFalse(app.buttons["continuePausedRunButton"].exists)
        XCTAssertFalse(app.buttons["endPausedRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 1,
                       "An explicit continuation must not replay the settled tool call.")
    }

    @MainActor func testMixedToolRoundPauseMakesNoImplicitRequestAcrossRelaunch() throws {
        #if !targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_DEVICE_TEST"] == "1" else {
            throw XCTSkip("Run explicitly with TEST_RUNNER_EISCUE_REAL_DEVICE_TEST=1.")
        }
        #endif
        continueAfterFailure = false
        let fixture = try MixedToolPauseModelFixture()
        let url = try fixture.start()
        defer { fixture.stop() }
        var app = launch(timeline: true, fixtureURL: url)
        defer { app.terminate() }
        send(MixedToolPauseModelFixture.prompt, in: app)

        XCTAssertTrue(app.buttons["continuePausedRunButton"].waitForExistence(timeout: 20))
        waitUntilIdle(in: app)
        XCTAssertTrue(app.buttons["endPausedRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        XCTAssertTrue(app.staticTexts["任务暂无进展。请查看屏幕，再继续任务或补充说明。"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 2)
        assertNoFurtherModelRequests(fixture, expected: 1)
        XCTAssertFalse(app.staticTexts[MixedToolPauseModelFixture.unexpectedAnswer].exists)

        app.terminate()
        app = launch(reset: false, timeline: true, fixtureURL: url)
        let continueButton = app.buttons["continuePausedRunButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["endPausedRunButton"].exists)
        XCTAssertFalse(app.buttons["stopRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 2)
        assertNoFurtherModelRequests(fixture, expected: 1)

        continueButton.tap()
        XCTAssertTrue(app.staticTexts[MixedToolPauseModelFixture.continuedAnswer].waitForExistence(timeout: 20))
        waitUntilIdle(in: app)
        XCTAssertFalse(app.buttons["continuePausedRunButton"].exists)
        XCTAssertFalse(app.buttons["endPausedRunButton"].exists)
        XCTAssertFalse(app.buttons["resumeRunButton"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 2,
                       "Explicit continuation must not replay either settled tool call.")
        assertNoFurtherModelRequests(fixture, expected: 2)
        XCTAssertEqual(fixture.snapshot.continuations, 1)
        XCTAssertFalse(app.staticTexts[MixedToolPauseModelFixture.unexpectedAnswer].exists)
    }

    @MainActor private func assertNoFurtherModelRequests(_ fixture: MixedToolPauseModelFixture, expected: Int,
                                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.snapshot.requests, expected, file: file, line: line)
        let extraRequest = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in fixture.snapshot.requests > expected }, object: nil)
        extraRequest.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [extraRequest], timeout: 2), .completed,
                       "A settled run must not issue another model request.", file: file, line: line)
        XCTAssertEqual(fixture.snapshot.requests, expected, file: file, line: line)
        XCTAssertEqual(fixture.snapshot.unexpectedRequests, 0, file: file, line: line)
        XCTAssertEqual(fixture.snapshot.rejectedRequests, 0, file: file, line: line)
    }

    @MainActor func testToolWithoutPrefaceKeepsUserAnchorAcrossRelaunch() {
        var app = launch(timeline: true)
        send("timeline no prose fixture", in: app)
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 15))
        waitUntilIdle(in: app)
        assertToolOnlyTimeline(in: app)
        app.terminate()
        app = launch(reset: false, timeline: true)
        XCTAssertTrue(app.staticTexts["Markdown title"].waitForExistence(timeout: 10))
        assertToolOnlyTimeline(in: app)
    }

    @MainActor private func assertToolOnlyTimeline(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let user = app.staticTexts["timeline no prose fixture"]
        let tool = app.descendants(matching: .any)["toolActivityRow"].firstMatch
        let reply = app.staticTexts["File inspection finished."]
        XCTAssertTrue(user.exists && tool.exists && reply.exists, file: file, line: line)
        XCTAssertLessThan(user.frame.midY, tool.frame.midY, file: file, line: line)
        XCTAssertLessThan(tool.frame.midY, reply.frame.midY, file: file, line: line)
        XCTAssertFalse(app.staticTexts["I will inspect the file first."].exists, file: file, line: line)
    }

    @MainActor private func assertTimeline(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let firstReply = app.staticTexts["I will inspect the file first."]
        let tool = app.descendants(matching: .any)["toolActivityRow"].firstMatch
        let finalReply = app.staticTexts["File inspection finished."]
        XCTAssertTrue(tool.exists, file: file, line: line)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toolActivityRow").count, 1, file: file, line: line)
        XCTAssertLessThan(firstReply.frame.midY, tool.frame.midY, file: file, line: line)
        XCTAssertLessThan(tool.frame.midY, finalReply.frame.midY, file: file, line: line)
        XCTAssertTrue(tool.staticTexts["操作已执行"].exists, file: file, line: line)
        XCTAssertEqual(tool.buttons.count, 0, "Plain activity rows have no disclosure control.", file: file, line: line)
        if !tool.isHittable { app.swipeDown() }
        tool.tap()
        XCTAssertFalse(app.staticTexts["Fixture document content"].exists, "Raw tool output stays out of chat.", file: file, line: line)
        XCTAssertFalse(app.staticTexts["fixture_read_file"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["fixture.txt"].exists, file: file, line: line)
    }

    @MainActor private func waitUntilIdle(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed, file: file, line: line)
    }

    @MainActor func testSidebarOrderPinAndDeletePersistAcrossLaunches() throws {
        var app = launch()
        for (index, title) in ["First conversation", "Second conversation", "Third conversation"].enumerated() {
            if index > 0 {
                openSidebar(in: app)
                app.buttons["newConversationButton"].tap()
            }
            send(title, in: app)
            XCTAssertTrue(app.staticTexts["Fixture response: \(title)"].waitForExistence(timeout: 20))
            let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["stopRunButton"])
            XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed)
        }
        openSidebar(in: app)
        assertOrder(["Third conversation", "Second conversation", "First conversation"], in: app)
        conversationRow(titled: "First conversation", in: app).press(forDuration: 1)
        app.buttons["moveConversationUpButton"].tap()
        assertOrder(["Third conversation", "First conversation", "Second conversation"], in: app)
        conversationRow(titled: "Second conversation", in: app).press(forDuration: 1)
        app.buttons["pinConversationButton"].tap()
        assertOrder(["Second conversation", "Third conversation", "First conversation"], in: app)
        XCTAssertEqual(conversationRow(titled: "Second conversation", in: app).value as? String, "已置顶")
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(app.buttons["historyButton"].waitForExistence(timeout: 10))
        openSidebar(in: app)
        assertOrder(["Second conversation", "Third conversation", "First conversation"], in: app)
        XCTAssertEqual(conversationRow(titled: "Second conversation", in: app).value as? String, "已置顶")
        conversationRow(titled: "Third conversation", in: app).press(forDuration: 1)
        app.buttons["moveConversationDownButton"].tap()
        assertOrder(["Second conversation", "First conversation", "Third conversation"], in: app)
        conversationRow(titled: "First conversation", in: app).press(forDuration: 1)
        app.buttons["deleteConversationButton"].tap()
        app.buttons["confirmDeleteConversationsButton"].firstMatch.tap()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: conversationRow(titled: "First conversation", in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 10), .completed)
        assertOrder(["Second conversation", "Third conversation"], in: app)
    }

    @MainActor private func assertOrder(_ titles: [String], in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let rows = titles.map { conversationRow(titled: $0, in: app) }
        for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line) }
        for (above, below) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThan(above.frame.midY, below.frame.midY, file: file, line: line)
        }
    }
}

/// This server runs beside the App on the test destination, not on the Mac.
/// Mutable state and Network callbacks belong to queue; reads/cleanup use sync.
/// Only fixed-case counters survive a request; headers and bodies are never logged.
private final class MixedToolPauseModelFixture: @unchecked Sendable {
    static let prompt = "mixed tool pause fixture"
    static let continuedAnswer = "Mixed tool pause fixture continued successfully."
    static let unexpectedAnswer = "UNEXPECTED_IMPLICIT_MODEL_REQUEST"
    private static let continuationPrompt = "从当前画面继续我刚才的任务。先重新查看屏幕，确认哪些步骤已经完成；如果之前的操作没有进展，请换一种方式。"
    private static let maxHeaderBytes = 16_384
    private static let maxBodyBytes = 262_144

    struct Snapshot: Sendable {
        var requests = 0
        var continuations = 0
        var unexpectedRequests = 0
        var rejectedRequests = 0
    }
    private enum FixtureError: Error { case listenerUnavailable }
    private enum ParsedRequest { case incomplete, invalid, body(Data) }

    private let queue = DispatchQueue(label: "org.eiscue.uitests.mixed-tool-pause")
    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var counts = Snapshot()
    private var port: UInt16?
    private var stopped = false
    private var finishedStarting = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var snapshot: Snapshot { queue.sync { counts } }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        queue.sync {
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.finishedStarting else { return }
                switch state {
                case .ready:
                    self.port = self.listener.port?.rawValue
                case .failed, .cancelled:
                    break
                default:
                    return
                }
                self.finishedStarting = true
                ready.signal()
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped, self.connections.count < 4 else {
                    connection.cancel()
                    return
                }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, bytes: Data())
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.finish(connection)
                }
            }
            listener.start(queue: queue)
        }
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = queue.sync(execute: { port }),
              let url = URL(string: "http://127.0.0.1:\(port)/v1") else {
            stop()
            throw FixtureError.listenerUnavailable
        }
        return url
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func finish(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] content, _, complete, error in
            guard let self, !self.stopped, self.connections[ObjectIdentifier(connection)] != nil else { return }
            var received = bytes
            if let content { received.append(content) }
            switch Self.parse(received) {
            case .body(let body):
                self.respond(to: connection, body: body)
            case .invalid:
                self.counts.rejectedRequests += 1
                self.finish(connection)
            case .incomplete:
                if error != nil || complete {
                    self.counts.rejectedRequests += 1
                    self.finish(connection)
                } else {
                    self.receive(connection, bytes: received)
                }
            }
        }
    }

    private static func parse(_ bytes: Data) -> ParsedRequest {
        guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            return bytes.count <= maxHeaderBytes ? .incomplete : .invalid
        }
        guard separator.lowerBound <= maxHeaderBytes,
              let header = String(data: bytes[..<separator.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /v1/chat/completions HTTP/1.1" else { return .invalid }
        var length: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" { return .invalid }
            if name == "content-length" {
                guard length == nil, let parsed = Int(value), (1...maxBodyBytes).contains(parsed) else { return .invalid }
                length = parsed
            }
        }
        guard let length else { return .invalid }
        let body = bytes[separator.upperBound...]
        if body.count < length { return .incomplete }
        guard body.count == length else { return .invalid }
        return .body(Data(body))
    }

    private func respond(to connection: NWConnection, body: Data) {
        counts.requests += 1
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              request["stream"] as? Bool == true,
              let messages = request["messages"] as? [[String: Any]] else {
            counts.rejectedRequests += 1
            finish(connection)
            return
        }
        let userTexts = messages.filter { $0["role"] as? String == "user" }.map(Self.messageText)
        let tools = request["tools"] as? [[String: Any]] ?? []
        let hasFixtureTool = tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "fixture_read_file" }
        var events = Self.event(["role": "assistant", "content": ""])
        if counts.requests == 1, userTexts == [Self.prompt], hasFixtureTool {
            for (index, path) in ["fixture.txt", "pause.txt"].enumerated() {
                events.append(Self.event(["tool_calls": [
                    ["index": index, "id": "mixed-fixture-\(index)", "type": "function",
                     "function": ["name": "fixture_read_file", "arguments": "{\"path\":\"\(path)\"}"]]
                ]]))
            }
            events.append(Self.event([:], finish: "tool_calls"))
        } else if counts.requests == 2, userTexts == [Self.prompt, Self.continuationPrompt] {
            counts.continuations += 1
            events.append(Self.event(["content": Self.continuedAnswer]))
            events.append(Self.event([:], finish: "stop"))
        } else {
            counts.unexpectedRequests += 1
            events.append(Self.event(["content": Self.unexpectedAnswer]))
            events.append(Self.event([:], finish: "stop"))
        }
        events.append(Data("data: [DONE]\n\n".utf8))
        var response = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                             + "Cache-Control: no-cache\r\nConnection: close\r\n"
                             + "Content-Length: \(events.count)\r\n\r\n").utf8)
        response.append(events)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish(connection)
        })
    }

    private static func messageText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        let parts = message["content"] as? [[String: Any]] ?? []
        return parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    private static func event(_ delta: [String: Any], finish: String? = nil) -> Data {
        // All values are fixed fixture data, never request headers or content.
        let packet: [String: Any] = [
            "id": "mixed-pause-completion", "object": "chat.completion.chunk",
            "created": 1, "model": "fixture-model",
            "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]]
        ]
        var data = Data("data: ".utf8)
        data.append(try! JSONSerialization.data(withJSONObject: packet))
        data.append(Data("\n\n".utf8))
        return data
    }
}
