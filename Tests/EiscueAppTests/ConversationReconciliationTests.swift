import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class ConversationReconciliationTests: XCTestCase {
    func testIdenticalTextWithDifferentAttachmentsDoesNotLoseTheUnsubmittedFile() {
        let first = AgentAttachment(name: "one.txt", mimeType: "text/plain", content: .text("first document"))
        let second = AgentAttachment(name: "two.txt", mimeType: "text/plain", content: .text("second document"))
        let accepted = AgentMessage(role: .user, text: "Read this", attachments: [first])
        let pending = AgentMessage(role: .user, text: "Read this", attachments: [second])
        let runtime = AgentMessage(role: .user, text: "Read this", attachments: [first])
        XCTAssertEqual(AppModel.reconciled(local: [accepted, pending], runtime: [runtime]), [runtime, pending])
    }

    func testEmptyRuntimePreservesUnsubmittedLocalConversation() {
        let local = [AgentMessage(role: .user, text: "尚未发送的任务")]

        XCTAssertEqual(AppModel.reconciled(local: local, runtime: []), local)
    }

    func testRecoveryReplacesPartialReplyAndPreservesUnsubmittedSuffixAfterFinalReply() {
        let localRequest = AgentMessage(role: .user, text: "查看天气")
        let partialReply = AgentMessage(role: .assistant, text: "正在查看")
        let unsubmittedRequest = AgentMessage(role: .user, text: "再查明天")
        // A runtime rehydration can give accepted messages different IDs.
        let acceptedRequest = AgentMessage(role: .user, text: localRequest.text)
        let finalReply = AgentMessage(role: .assistant, text: "今天晴天。")

        let result = AppModel.reconciled(
            local: [localRequest, partialReply, unsubmittedRequest],
            runtime: [acceptedRequest, finalReply]
        )

        XCTAssertEqual(result, [acceptedRequest, finalReply, unsubmittedRequest])
    }

    func testAuthoritativeMessageWithSameIDReplacesLocalContent() {
        let request = AgentMessage(role: .user, text: "总结结果")
        let partialReply = AgentMessage(role: .assistant, text: "已完成第一步")
        let finalReply = AgentMessage(id: partialReply.id, role: .assistant, text: "已完成全部步骤。")

        let result = AppModel.reconciled(local: [request, partialReply], runtime: [request, finalReply])

        XCTAssertEqual(result, [request, finalReply])
    }

    func testRepeatedPromptDoesNotLoseTheUnacceptedSecondOccurrence() {
        let firstRequest = AgentMessage(role: .user, text: "再看一次")
        let reply = AgentMessage(role: .assistant, text: "画面未变化。")
        let unsubmittedRepeat = AgentMessage(role: .user, text: firstRequest.text)
        let acceptedRequest = AgentMessage(role: .user, text: firstRequest.text)

        let result = AppModel.reconciled(
            local: [firstRequest, reply, unsubmittedRepeat],
            runtime: [acceptedRequest, reply]
        )

        XCTAssertEqual(result, [acceptedRequest, reply, unsubmittedRepeat])
    }

    func testAbandonedPromptDoesNotStealAnIdenticalLaterSubmission() {
        let abandoned = AgentMessage(role: .user, text: "再看一次")
        let submitted = AgentMessage(role: .user, text: "再看一次")
        let canonical = AgentMessage(role: .user, text: "再看一次")
        let reply = AgentMessage(role: .assistant, text: "已查看。")
        let result = AppModel.reconciled(local: [abandoned, submitted, reply],
                                        runtime: [canonical, reply], unsubmittedIDs: [abandoned.id])
        XCTAssertEqual(result, [abandoned, canonical, reply])
    }
}
