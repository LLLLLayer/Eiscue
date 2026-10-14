import EiscueAgentKit
import SwiftUI

/// Kept separate from the composer so typing and speech updates don't rebuild history.
struct AssistantTranscriptView<Welcome: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let welcome: () -> Welcome
    @State private var followsLatest = true
    @State private var isUserScrolling = false

    var body: some View {
        let feed = model.displayedConversationFeed
        let actionIDs = ConversationFeedItem.latestActionMessageIDs(in: feed, isAssistantStreaming: model.hasDisplayedStreamingText)
        let unsubmittedIDs = model.unsubmittedMessageIDs
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if feed.isEmpty { welcome() }
                    else if let conversation = model.selectedConversation {
                        Text(conversation.createdAt, format: .dateTime.month().day())
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    ForEach(feed) { item in
                        switch item {
                        case .message(let message):
                            ChatMessageRow(message: message, showsActions: actionIDs.contains(message.id),
                                           isUnsubmitted: unsubmittedIDs.contains(message.id)).equatable()
                        case .activity(let activity):
                            ToolActivityRow(activity: activity, showsProgress: !model.isShowingDeviceControlRun).equatable()
                        }
                    }
                    StreamingResponseView()
                    if model.isShowingDeviceControlRun {
                        Label(chatText("chat.operatingDevice"), systemImage: "hand.tap")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                            .accessibilityIdentifier("deviceControlRunStatus")
                    } else if model.activeRun != nil || model.isSubmittingMessage { AssistantReplyIndicator() }
                    runStatus
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24).padding(.top, 20)
                .frame(maxWidth: .infinity)
                .environment(\.holdsChatRendering, model.isHoldingDeviceTranscript)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("conversationScrollView")
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(followsLatest && !model.isHoldingDeviceTranscript ? .bottom : nil, for: .sizeChanges)
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 60
            } action: { _, nearBottom in
                if isUserScrolling { followsLatest = nearBottom }
            }
            .onChange(of: feed.count) {
                guard followsLatest, !model.isHoldingDeviceTranscript else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.isSubmittingMessage) { _, isSubmitting in
                guard isSubmitting, !model.isHoldingDeviceTranscript else { return }
                followsLatest = true
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var runStatus: some View {
        if model.activeRun == nil, model.needsRecovery {
            VStack(alignment: .leading, spacing: 10) {
                Label("assistant.interrupted", systemImage: "pause.circle").font(.subheadline.weight(.medium))
                Text("assistant.recoveryDetail").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("assistant.resume") { Task { await model.continueInterruptedRun() } }
                        .buttonStyle(.glassProminent).accessibilityIdentifier("resumeRunButton")
                        .foregroundStyle(EiscueStyle.onAccent)
                    Button("assistant.endTask") { Task { await model.abandonInterruptedRun() } }
                        .buttonStyle(.glass)
                }
            }.padding(.vertical, 8)
        } else if model.activeRun == nil, let run = model.pausedRun {
            VStack(alignment: .leading, spacing: 10) {
                Label("run.paused", systemImage: "pause.circle").font(.subheadline.weight(.medium))
                Text(run.pauseReason?.detail ?? run.detail).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "run.paused.continue", table: "Runtime")) { Task { await model.continueInterruptedRun() } }
                        .buttonStyle(.glassProminent).accessibilityIdentifier("continuePausedRunButton")
                        .foregroundStyle(EiscueStyle.onAccent)
                    Button(String(localized: "run.paused.end", table: "Runtime")) { Task { await model.abandonInterruptedRun() } }
                        .buttonStyle(.glass).accessibilityIdentifier("endPausedRunButton")
                }.disabled(model.isBusy)
            }.padding(.vertical, 8).accessibilityElement(children: .contain).accessibilityIdentifier("pausedRunStatus")
        } else if model.activeRun == nil, let run = model.selectedRuns.first, run.state == .failed {
            Label(run.detail, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

}

private struct StreamingResponseView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if !model.displayedStreamingText.isEmpty {
            AssistantMessageContent(text: model.displayedStreamingText).equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("streamingResponse")
        }
    }
}
