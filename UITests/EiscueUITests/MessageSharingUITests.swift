import XCTest
import UIKit

final class MessageSharingUITests: XCTestCase {
    private let saveToFilesLabels = ["Save to Files", "保存到“文件”", "保存到‘文件’", "保存到「文件」", "保存到\"文件\"",
                                     "存储到“文件”", "存储到‘文件’", "存储到「文件」", "保存到文件", "存储到文件"]
    private let saveLabels = ["Save", "保存", "存储"]
    private let newFolderLabels = ["New Folder", "Create Folder", "新建文件夹", "新文件夹", "创建文件夹"]

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--message-sharing-fixture", "--skip-onboarding", "--reset-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["fixtureFileShareRow"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["fixtureShareError"].exists)
        return app
    }

    @MainActor func testAttachmentOnlyFileShowsRealFilenameAndNativeSharingActions() {
        let app = launch()
        let row = app.descendants(matching: .any)["fixtureFileShareRow"]
        XCTAssertFalse(row.buttons["userCopyMessageButton"].exists, "No empty-text Copy action")
        let share = row.buttons["userShareMessageButton"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: share)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        share.tap()
        assertNativeController(in: app)
        let nativeShare = app.descendants(matching: .any)["messageActivityController"]
        XCTAssertTrue(nativeShare.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Shared notes")).firstMatch.waitForExistence(timeout: 5), "The system preview must show the actual document name")
        record(app, name: "Attachment-only native file share")
        dismissNativeController(in: app)
        XCTAssertTrue(share.isEnabled)
        // A second presentation needs a new, live export after cleanup.
        share.tap()
        assertNativeController(in: app)
        dismissNativeController(in: app)
    }

    @MainActor func testAttachmentOnlyPhotoOpensNativeShareAndDismisses() {
        let app = launch()
        let row = app.descendants(matching: .any)["fixturePhotoShareRow"]
        XCTAssertFalse(row.buttons["userCopyMessageButton"].exists)
        let share = row.buttons["userShareMessageButton"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: share)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        share.tap()
        assertNativeController(in: app)
        record(app, name: "Attachment-only native photo share")
        dismissNativeController(in: app)
        XCTAssertTrue(share.isEnabled)
        XCTAssertFalse(app.staticTexts["messageShareUnavailable"].exists)
    }

    @MainActor func testAttachmentOnlyFileSavesToLocalFilesAndReadsBackExactBytes() {
        let app = launch()
        let filename = app.staticTexts["fixtureSharedFilename"].label
        let expectedBytes = app.staticTexts["fixtureSharedByteCount"].label
        XCTAssertTrue(filename.hasPrefix("Shared notes-"))
        XCTAssertTrue(filename.hasSuffix(".txt"))
        XCTAssertNotNil(Int(expectedBytes))
        let nonce = String(filename.dropFirst("Shared notes-".count).dropLast(".txt".count))
        XCTAssertNotNil(UUID(uuidString: nonce), "Read-back must belong to this run, never an existing user file")
        let folderName = "Eiscue ShareCheck-" + nonce
        let share = app.descendants(matching: .any)["fixtureFileShareRow"].buttons["userShareMessageButton"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: share)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        share.tap()
        assertNativeController(in: app)
        guard openNativeSaveToFiles(in: app) else { return }
        guard let save = waitForVisibleButton(saveLabels, in: app) else {
            XCTFail("The native Save to Files confirmation is missing"); return
        }
        guard openLocalStorage(in: app), createFolder(folderName, in: app) else { return }
        let canSave = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [canSave], timeout: 5), .completed)
        save.tap()
        let shareClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.descendants(matching: .any)["messageActivityController"])
        XCTAssertEqual(XCTWaiter.wait(for: [shareClosed], timeout: 8), .completed)

        app.buttons["verifySavedShareButton"].tap()
        let picker = app.descendants(matching: .any)["fixtureSavedDocumentPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "Read-back must use a fresh public document picker")
        guard openLocalStorage(in: app), tapLabel(folderName, in: app) else { return }
        guard tapLabel(filename, in: picker) else { return }
        let result = app.staticTexts["fixtureSavedFileVerification"]
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        XCTAssertEqual(result.label, "Saved file bytes verified")
        XCTAssertEqual(result.value as? String, "verified|\(filename)|\(expectedBytes)", "Only exact contents read from the newly saved file may pass")
        record(app, name: "Native Save to Files and public picker exact-byte read-back")
    }

    /// Navigate the system's local location explicitly. Do not accept iCloud,
    /// another provider, a share-success callback, or an unavailable picker.
    @MainActor private func openLocalStorage(in app: XCUIApplication) -> Bool {
        let locations = UIDevice.current.userInterfaceIdiom == .pad ? ["On My iPad", "我的 iPad", "我的iPad"] : ["On My iPhone", "我的 iPhone", "我的iPhone"]
        for _ in 0..<6 {
            if let element = visibleLabel(locations, in: app) {
                element.tap()
                return true
            }
            let navigation = ["Browse", "浏览", "Locations", "位置", "Show Sidebar", "显示侧边栏", "iCloud Drive", "iCloud 云盘", "Downloads", "下载"]
                .compactMap { label in app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first(where: \.isHittable) }
            guard let back = navigation.first else {
                XCTFail("The native picker did not expose the local \(locations[0]) location or a known navigation control")
                return false
            }
            back.tap()
        }
        XCTFail("Could not navigate the native picker to \(locations[0])")
        return false
    }

    @MainActor private func createFolder(_ name: String, in app: XCUIApplication) -> Bool {
        if visibleLabel(newFolderLabels, in: app) == nil {
            let more = ["More", "More Actions", "更多", "更多操作"].compactMap { label in
                app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first(where: \.isHittable)
            }.first
            guard let more else { XCTFail("Local Save to Files did not expose New Folder"); return false }
            more.tap()
        }
        guard tapLabel(newFolderLabels, in: app) else { return false }
        guard let editor = folderNameEditor(in: app) else {
            XCTFail("The native New Folder name field is missing"); return false
        }
        let nameField = editor.field
        nameField.tap()
        // iPadOS creates a blue directory tile and selects 'untitled folder'
        // inline. Select All also handles tapping that collapsed the selection.
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        guard nameField.value as? String == name else {
            XCTFail("The native folder editor did not replace the default name exactly"); return false
        }
        if editor.isAlert {
            guard let confirm = waitForVisibleButton(["Create", "Done", "创建", "完成"], in: app.alerts.firstMatch) else {
                XCTFail("The native New Folder alert confirmation is missing"); return false
            }
            confirm.tap()
        } else {
            // Use the observed keyboard Return/check action, including a
            // hardware-keyboard run where the software key is not displayed.
            let keys = ["Return", "return", "Done", "done", "完成", "确定", "换行"]
            if let confirm = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", keys as NSArray))
                .allElementsBoundByIndex.first(where: \.isHittable) {
                confirm.tap()
            } else { nameField.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: []) }
        }
        if app.navigationBars[name].waitForExistence(timeout: 2) { return true }
        let directory = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND elementType != %d AND elementType != %d", name,
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
        guard directory.waitForExistence(timeout: 5), directory.isHittable else {
            XCTFail("The renamed folder did not become a selectable native directory"); return false
        }
        directory.tap()
        return true
    }

    @MainActor private func folderNameEditor(in app: XCUIApplication) -> (field: XCUIElement, isAlert: Bool)? {
        let alertField = app.alerts.textFields.firstMatch
        if alertField.waitForExistence(timeout: 1), alertField.isHittable { return (alertField, true) }
        let predicate = NSPredicate(format: "value BEGINSWITH[c] %@ OR value BEGINSWITH %@ OR value BEGINSWITH %@", "untitled folder", "未命名文件夹", "无标题文件夹")
        let textField = app.textFields.matching(predicate).firstMatch
        let textView = app.textViews.matching(predicate).firstMatch
        guard textField.waitForExistence(timeout: 3) || textView.waitForExistence(timeout: 1) else { return nil }
        for fields in [app.textFields, app.textViews] {
            for (index, field) in fields.allElementsBoundByIndex.enumerated() where field.isHittable && predicate.evaluate(with: field) {
                // Bind by the unfiltered type/index: a value-based query would
                // stop resolving as soon as the typed name changes.
                return (fields.element(boundBy: index), false)
            }
        }
        return nil
    }

    @MainActor private func openNativeSaveToFiles(in app: XCUIApplication) -> Bool {
        if visibleLabel(saveToFilesLabels, in: app) == nil {
            let more = ["Show More", "More", "查看更多", "显示更多", "更多"]
            if let expansion = visibleLabel(more, in: app) { expansion.tap() }
        }
        return tapLabel(saveToFilesLabels, in: app)
    }

    @MainActor private func visibleLabel(_ label: String, in element: XCUIElement) -> XCUIElement? {
        visibleLabel([label], in: element)
    }
    @MainActor private func visibleLabel(_ labels: [String], in element: XCUIElement) -> XCUIElement? {
        element.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels as NSArray))
            .allElementsBoundByIndex.first(where: \.isHittable)
    }
    @MainActor private func tapLabel(_ label: String, in element: XCUIElement) -> Bool {
        tapLabel([label], in: element)
    }
    @MainActor private func tapLabel(_ labels: [String], in element: XCUIElement) -> Bool {
        let candidate = element.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels as NSArray)).firstMatch
        guard candidate.waitForExistence(timeout: 5), let visible = visibleLabel(labels, in: element) else {
            XCTFail("Missing visible native file-picker item: \(labels.joined(separator: " / "))"); return false
        }
        visible.tap()
        return true
    }

    @MainActor private func waitForVisibleButton(_ labels: [String], in element: XCUIElement) -> XCUIElement? {
        let query = element.buttons.matching(NSPredicate(format: "label IN %@", labels as NSArray))
        guard query.firstMatch.waitForExistence(timeout: 5) else { return nil }
        return query.allElementsBoundByIndex.first(where: \.isHittable)
    }

    @MainActor private func assertNativeController(in app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["messageActivityController"].waitForExistence(timeout: 8))
        // These belong to Apple's share controller, rather than the fixture.
        let nativeShare = app.descendants(matching: .any)["messageActivityController"]
        let actions = ["Copy", "拷贝", "复制", "Print", "打印", "Assign to Contact", "指定给联系人", "分配给联系人"] + saveToFilesLabels
        let action = nativeShare.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", actions as NSArray)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "The real native file/photo sharing actions must be present")
    }

    @MainActor private func dismissNativeController(in app: XCUIApplication) {
        if let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭"] as NSArray)).allElementsBoundByIndex.first(where: \.isHittable) {
            close.tap()
        } else if app.popovers.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.03)).tap()
        } else {
            app.descendants(matching: .any)["messageActivityController"].swipeDown()
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.descendants(matching: .any)["messageActivityController"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    @MainActor private func record(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
