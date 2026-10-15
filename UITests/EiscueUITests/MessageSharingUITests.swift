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
        let filename = app.staticTexts["fixtureSharedFilename"].label
        let row = app.descendants(matching: .any)["fixtureFileShareRow"]
        XCTAssertFalse(row.buttons["userCopyMessageButton"].exists, "No empty-text Copy action")
        XCTAssertFalse(row.buttons["selectMessageTextButton"].exists, "No text-selection action for an attachment-only message")
        shareAttachment(in: row, app: app)
        assertNativeController(in: app)
        let nativeShare = nativeController(in: app)
        let caption = nativeShare.descendants(matching: .any)["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "The system preview must show the actual document name")
        XCTAssertTrue([filename, (filename as NSString).deletingPathExtension].contains(caption.label), "The native preview must name this run's exported document")
        record(app, name: "Attachment-only native file share")
        dismissNativeController(in: app)
        XCTAssertTrue(row.isHittable)
        // A second presentation needs a new, live export after cleanup.
        shareAttachment(in: row, app: app)
        assertNativeController(in: app)
        dismissNativeController(in: app)
    }

    @MainActor func testAttachmentOnlyPhotoOpensNativeShareAndDismisses() {
        let app = launch()
        let row = app.descendants(matching: .any)["fixturePhotoShareRow"]
        XCTAssertFalse(row.buttons["userCopyMessageButton"].exists)
        XCTAssertFalse(row.buttons["selectMessageTextButton"].exists)
        shareAttachment(in: row, app: app)
        assertNativeController(in: app)
        record(app, name: "Attachment-only native photo share")
        dismissNativeController(in: app)
        XCTAssertTrue(row.isHittable)
        XCTAssertFalse(app.staticTexts["messageShareUnavailable"].exists)
        shareAttachment(in: row, app: app)
        assertNativeController(in: app)
        dismissNativeController(in: app)
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
        let row = app.descendants(matching: .any)["fixtureFileShareRow"]
        shareAttachment(in: row, app: app)
        assertNativeController(in: app)
        guard openNativeSaveToFiles(in: app) else { return }
        guard let save = waitForVisibleButton(saveLabels, in: app) else {
            XCTFail("The native Save to Files confirmation is missing"); return
        }
        guard openLocalStorage(in: app), createFolder(folderName, in: app) else { return }
        let canSave = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [canSave], timeout: 5), .completed)
        save.tap()
        let shareClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: nativeController(in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [shareClosed], timeout: 8), .completed)

        app.buttons["verifySavedShareButton"].tap()
        let picker = app.descendants(matching: .any)["fixtureSavedDocumentPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "Read-back must use a fresh public document picker")
        guard openLocalStorage(in: app), openLocalFolder(folderName, in: picker) else { return }
        // Files exposes the extension separately in its cell identifier and
        // omits it from the caption, even with shouldShowFileExtensions enabled.
        let name = filename as NSString
        let document = picker.cells["\(name.deletingPathExtension), \(name.pathExtension)"]
        guard document.waitForExistence(timeout: 5), document.isHittable else {
            XCTFail("The native picker did not expose this run's exact document name and extension"); return
        }
        let icon = document.images.firstMatch
        if icon.exists && icon.isHittable { icon.tap() } else { document.tap() }
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
        return openLocalFolder(name, in: app)
    }

    @MainActor private func openLocalFolder(_ name: String, in element: XCUIElement) -> Bool {
        // Files can enter the new folder immediately after the inline rename.
        // Its navigation bar keeps a fixed identifier; the browsing root names
        // the current directory and its actual local file provider.
        let folder = element.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: \(name)"]
        if folder.waitForExistence(timeout: 2) { return true }
        let directory = element.cells.containing(.staticText, identifier: name).firstMatch
        guard directory.waitForExistence(timeout: 5), directory.isHittable else {
            XCTFail("The native picker did not expose the unique saved-file folder"); return false
        }
        // In icon mode a caption tap can leave the picker at its parent. Tap
        // the folder artwork and verify the resulting directory before saving
        // or looking for the document.
        let icon = directory.images.firstMatch
        if icon.exists && icon.isHittable { icon.tap() } else { directory.tap() }
        guard folder.waitForExistence(timeout: 5) else {
            XCTFail("The native picker did not enter the unique local folder"); return false
        }
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

    @MainActor private func shareAttachment(in row: XCUIElement, app: XCUIApplication) {
        XCTAssertFalse(row.buttons["userShareMessageButton"].exists, "Sharing should not add a permanent footer button.")
        let bubble = row.descendants(matching: .any).matching(identifier: "messageBubble").firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        XCTAssertTrue(bubble.isHittable)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: bubble.frame.maxX - 8, dy: bubble.frame.midY)).press(forDuration: 1)
        let share = app.buttons["userShareMessageButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["userCopyMessageButton"].exists, "Attachment-only messages must not offer an empty-text Copy action.")
        XCTAssertFalse(app.buttons["selectMessageTextButton"].exists, "Attachment-only messages must not offer empty text selection.")
        XCTAssertFalse(app.buttons["messageRunHistoryButton"].exists)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: share)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        share.tap()
    }

    @MainActor private func nativeController(in app: XCUIApplication) -> XCUIElement {
        // iOS can replace the root controller identifier when its share surface
        // attaches; both identify the actual system UI, never fixture content.
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["ActivityListView", "messageActivityController"])).firstMatch
    }

    @MainActor private func assertNativeController(in app: XCUIApplication) {
        XCTAssertTrue(nativeController(in: app).waitForExistence(timeout: 8))
        // These belong to Apple's share controller, rather than the fixture.
        let nativeShare = nativeController(in: app)
        let actions = ["Copy", "拷贝", "复制", "Print", "打印", "Assign to Contact", "指定给联系人", "分配给联系人"] + saveToFilesLabels
        let action = nativeShare.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", actions as NSArray)).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "The real native file/photo sharing actions must be present")
    }

    @MainActor private func dismissNativeController(in app: XCUIApplication) {
        if let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭"] as NSArray)).allElementsBoundByIndex.first(where: \.isHittable) {
            close.tap()
        } else if app.otherElements["PopoverDismissRegion"].exists {
            // The system share popover exposes this region even when XCTest's
            // popovers query is empty. Tap real content outside its bounds,
            // keeping clear of the status bar rather than swiping the popover.
            let region = app.otherElements["PopoverDismissRegion"].frame
            let share = nativeController(in: app).frame
            let bounds = region.insetBy(dx: 16, dy: 16)
            let candidates = [
                CGRect(x: bounds.minX, y: bounds.minY + 48, width: bounds.width, height: share.minY - bounds.minY - 48),
                CGRect(x: bounds.minX, y: share.maxY, width: bounds.width, height: bounds.maxY - share.maxY),
                CGRect(x: bounds.minX, y: bounds.minY + 48, width: share.minX - bounds.minX, height: bounds.height - 48),
                CGRect(x: share.maxX, y: bounds.minY + 48, width: bounds.maxX - share.maxX, height: bounds.height - 48)
            ].filter { $0.size.width > 0 && $0.size.height > 0 }
            guard let target = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
                XCTFail("The native share popover has no reachable dismissal region"); return
            }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.midX, dy: target.midY)).tap()
        } else {
            nativeController(in: app).swipeDown()
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: nativeController(in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    @MainActor private func record(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
