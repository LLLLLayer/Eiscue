import EiscueAgentKit
import EiscueDeviceCore
#if !EISCUE_HID_ONLY
import EiscueDeviceKit
#endif
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: String(localized: "appearance.system", table: "Runtime"); case .light: String(localized: "appearance.light", table: "Runtime"); case .dark: String(localized: "appearance.dark", table: "Runtime") }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

@MainActor @Observable
final class AppModel {
    var conversations: [Conversation] = [] { didSet { conversationFeedRevision &+= 1 } }
    var conversationOrderRevision = 0
    var selectedConversationID: UUID?
    var draft = ""
    var composerSessionID = UUID()
    var draftAttachments: [AgentAttachment] = []
    var isImportingAttachments = false
    var isLoading = true
    var isSaving = false
    var isSubmittingMessage = false
    var isStopping: Bool { runCoordinator.current?.isCancelling ?? false }
    var errorMessage: String?
    var agentAvailability: AgentAvailability = .unconfigured
    #if DEBUG
    var deviceStatus: DeviceStatus {
        get { deviceSession.status }
        set { deviceSession.debugSeedSnapshot(status: newValue) }
    }
    #else
    var deviceStatus: DeviceStatus { deviceSession.status }
    #endif
    var modelSettings: ModelSettings
    var modelProfiles: [ModelProfile] = []
    var selectedModelProfileID: UUID?
    // Keychain changes must invalidate views without keeping secrets in UI state.
    var modelCredentialRevision = 0
    @ObservationIgnored var modelProfilesLoadError: (any Error)?
    var hasAPIKey = false
    var scope: TaskScope {
        didSet { preferences.set(scope != .chat, forKey: "allowsDeviceControl") }
    }
    var allowsDeviceControl: Bool {
        get { scope != .chat }
        set { scope = newValue ? .control : .chat }
    }
    var selectedSkillID: String?
    var skills: [AgentSkill] = []
    var runs: [RunRecord] = [] { didSet { conversationFeedRevision &+= 1; runRevision &+= 1 } }
    private var runRevision = 0
    @ObservationIgnored private var submissionCache: (revision: Int, requestID: UUID?, submission: RunSubmission?, states: [UUID: RunSubmission])?
    var activeRun: RunRecord? { runCoordinator.current?.record }
    private var conversationFeedRevision = 0
    @ObservationIgnored private var cachedConversationFeed: (revision: Int, conversationID: UUID?, runID: UUID?, activityRevision: Int?, items: [ConversationFeedItem])?
    private var controlTranscriptSnapshot: (runID: UUID, conversationID: UUID, feed: [ConversationFeedItem], text: String)?
    var streamingText: String { runCoordinator.current?.streamingText ?? "" }
    private var hasStreamingText: Bool { !streamingText.isEmpty }
    var currentTool: String { runCoordinator.current?.currentTool ?? "" }
    let toolImagePreviews = ToolImagePreviewStore()
    var interruptedConversationIDs = Set<UUID>()
    var showsModelSettings = false
    var showsOnboarding = false
    var connectionMessage = String(localized: "connection.disconnected", table: "Runtime")
    var deviceConnectionError: String?
    var boardHardwareStopPending = false
    /// Change through selectDeviceConnectionMethod so old sessions are released first.
    var deviceConnectionMethod: DeviceConnectionMethod {
        didSet {
            preferences.set(deviceConnectionMethod.rawValue, forKey: "deviceConnectionMethod")
            if deviceSession.selectedMethod != deviceConnectionMethod, deviceSession.owner == nil,
               !deviceSession.isTransitioning, deviceSession.activeMethod == nil {
                try? deviceSession.configure(method: deviceConnectionMethod, backend: deviceControlBackend)
            }
        }
    }
    /// Change through selectDeviceControlBackend so an old network session is released first.
    var deviceControlBackend: DeviceControlBackend {
        didSet { preferences.set(deviceControlBackend.rawValue, forKey: "deviceControlBackend") }
    }
    #if DEBUG
    var activeDeviceControlBackend: DeviceControlBackend? {
        get { if case .connecting(_, let backend, _) = deviceSession.state { return backend }
            return deviceSession.activeBackend }
        set { deviceSession.debugSeedSnapshot(activeBackend: .some(newValue)) }
    }
    #else
    var activeDeviceControlBackend: DeviceControlBackend? { if case .connecting(_, let backend, _) = deviceSession.state { return backend }
            return deviceSession.activeBackend }
    #endif
    var isChangingDeviceConnectionMethod = false
    #if DEBUG
    var isConnecting: Bool {
        get { deviceSession.showsConnectionProgress }
        set { deviceSession.debugSeedSnapshot(showsConnectionProgress: newValue) }
    }
    #else
    var isConnecting: Bool { deviceSession.showsConnectionProgress }
    #endif
    var isRepairingDeviceConnection = false
    @ObservationIgnored var deviceConnectionRepair: DeviceConnectionRepairSession?
    var isPairing = false
    var isManagingTunnel = false
    var isStoppingTunnel = false
    var pairingCode: String?
    var hasPairingIdentity = false
    var hasTransferredPairingIdentity = false
    var screenshot: DeviceScreenshot?
    var appearance: AppAppearance { didSet { preferences.set(appearance.rawValue, forKey: "appearance") } }
    var hapticsEnabled: Bool { didSet { preferences.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    var disconnectAfterTask: Bool { didSet { preferences.set(disconnectAfterTask, forKey: "disconnectAfterTask") } }
    #if DEBUG
    var showsDebugTools: Bool { didSet { preferences.set(showsDebugTools, forKey: "showsDebugTools") } }
    #endif

    let device: DeviceDescriptor
    let storageDirectory: URL
    @ObservationIgnored let preferences: UserDefaults
    @ObservationIgnored let credentials: CredentialStore
    @ObservationIgnored let repository: any ConversationRepository
    @ObservationIgnored let journal: RunJournal
    @ObservationIgnored let skillLibrary: SkillLibrary
    @ObservationIgnored let messageAttachments: MessageAttachments
    @ObservationIgnored lazy var runCoordinator = RunCoordinator(model: self)
    @ObservationIgnored var configuredAgent: AgentClient?
    @ObservationIgnored let agentFactory: AgentFactory
    let deviceSession: DeviceSession
    #if DEBUG
    var deviceClient: DeviceClient {
        get { deviceSession.client }
        set { deviceSession.debugSeedSnapshot(client: newValue) }
    }
    #else
    var deviceClient: DeviceClient { deviceSession.client }
    #endif
    #if DEBUG
    var networkDeviceClient: DeviceClient? {
        get { deviceSession.networkClient }
        set { deviceSession.debugSeedSnapshot(networkClient: .some(newValue)) }
    }
    #else
    var networkDeviceClient: DeviceClient? { deviceSession.networkClient }
    #endif
    var bluetoothController: BluetoothDeviceController { deviceSession.bluetooth }
    var bluetoothRevision = 0
    @ObservationIgnored var bluetoothSessionEvents = BluetoothSessionEventProjection()
    @ObservationIgnored var bluetoothMonitor: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored var bluetoothSetupStages: [(stage: String, timestamp: TimeInterval)] = []
    #endif
    @ObservationIgnored var isUpdatingBoardCompanion = false
    @ObservationIgnored var companionTerminal: (status: BluetoothCompanionStatus, until: ContinuousClock.Instant)?
    @ObservationIgnored var companionLastStatus: BluetoothCompanionStatus?
    @ObservationIgnored var companionFinalizingRunID: UUID?
    let localTunnel = LocalTunnelManager()
    let taskNotifications: any RunNotifying
    var deviceTools: DeviceToolSession? { runCoordinator.current?.tools }
    @ObservationIgnored let background: any RunBackgroundExecuting
    @ObservationIgnored var didLoad = false
    var stopRequested: Bool { runCoordinator.current?.stopCause != nil }
    @ObservationIgnored var pairingTask: Task<Void, Never>?
    @ObservationIgnored var pairingLeaseID: UUID?
    @ObservationIgnored var pairingDeviceLease: DeviceLease?
    #if DEBUG
    var deviceOperationID: UUID {
        get { deviceSession.operationID }
        set { deviceSession.debugSeedSnapshot(operationID: newValue) }
    }
    #else
    var deviceOperationID: UUID { deviceSession.operationID }
    #endif
    @ObservationIgnored var deviceConnectionTask: Task<Void, Error>?
    #if DEBUG
    var activeDeviceConnectionMethod: DeviceConnectionMethod? {
        get { deviceSession.activeMethod }
        set { deviceSession.debugSeedSnapshot(activeMethod: .some(newValue)) }
    }
    #else
    var activeDeviceConnectionMethod: DeviceConnectionMethod? { deviceSession.activeMethod }
    #endif
    @ObservationIgnored lazy var dictationSession = DictationSession(model: self)
    var dictationDeviceRestoration: DictationDeviceRestoration? { get { dictationSession.deviceRestoration } set { dictationSession.deviceRestoration = newValue } }
    var dictationPreparationID: UUID? { get { dictationSession.preparationID } set { dictationSession.preparationID = newValue } }
    @ObservationIgnored let deviceOperatingSystemVersion: OperatingSystemVersion
    @ObservationIgnored var currentScenePhase: ScenePhase = .active
    var lastTaskPresentation: TaskStatusPresentation? { runCoordinator.current?.lastTaskPresentation }
    var isReceivingResponse: Bool { runCoordinator.current?.isReceivingResponse ?? false }
    var runtimeDirectory: URL { storageDirectory.appendingPathComponent("Runtime", isDirectory: true) }

    init(storageDirectory suppliedDirectory: URL? = nil, preferences suppliedPreferences: UserDefaults? = nil,
         repository suppliedRepository: (any ConversationRepository)? = nil,
         credentialStore suppliedCredentials: CredentialStore? = nil,
         operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
         background: (any RunBackgroundExecuting)? = nil, notifications: (any RunNotifying)? = nil,
         agentFactory: @escaping AgentFactory = { configuration, directory, tools in
             if let configuration { AgentClient(configuration: configuration, storageDirectory: directory, tools: tools) }
             else { AgentClient(storageDirectory: directory) }
         }) {
        deviceSession = DeviceSession(client: DeviceBuildCapabilities.makeClient(), operatingSystemVersion: operatingSystemVersion)
        self.background = background ?? BackgroundExecution.shared
        self.agentFactory = agentFactory
        deviceOperatingSystemVersion = operatingSystemVersion
        let files = FileManager.default
        var directory = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Eiscue", isDirectory: true)
        var defaults = UserDefaults.standard
        var keychainService = (Bundle.main.bundleIdentifier ?? "org.eiscue.app") + ".credentials"
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            directory = files.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("EiscueUITests", isDirectory: true)
            defaults = UserDefaults(suiteName: "org.eiscue.app.uitests")!
            keychainService = "org.eiscue.app.uitests.credentials"
            if ProcessInfo.processInfo.arguments.contains("--reset-state") {
                try? files.removeItem(at: directory)
                defaults.removePersistentDomain(forName: "org.eiscue.app.uitests")
                try? CredentialStore(service: keychainService).deleteAll()
            }
        }
        #endif
        if let suppliedDirectory { directory = suppliedDirectory }
        if let suppliedPreferences { defaults = suppliedPreferences }
        storageDirectory = directory
        preferences = defaults
        scope = (defaults.object(forKey: "allowsDeviceControl") as? Bool ?? true) ? .control : .chat
        let savedMethod = DeviceConnectionMethod(rawValue: defaults.string(forKey: "deviceConnectionMethod") ?? "")
        deviceConnectionMethod = savedMethod.flatMap { DeviceBuildCapabilities.methods.contains($0) ? $0 : nil } ?? DeviceBuildCapabilities.defaultMethod
        deviceControlBackend = DeviceControlBackend(rawValue: defaults.string(forKey: "deviceControlBackend") ?? "") ?? .automatic
        showsOnboarding = defaults.integer(forKey: "onboardingVersion") < 1
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--skip-onboarding") { showsOnboarding = false }
        #endif
        taskNotifications = notifications ?? TaskNotificationManager(preferences: defaults)
        credentials = suppliedCredentials ?? CredentialStore(service: keychainService)
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        disconnectAfterTask = defaults.bool(forKey: "disconnectAfterTask")
        #if DEBUG
        showsDebugTools = defaults.object(forKey: "showsDebugTools") as? Bool ?? true
        #endif
        do {
            let state = try ModelProfileState.load(from: defaults)
            let selectedID = state.selectedID ?? state.profiles.first?.id
            modelProfiles = state.profiles
            selectedModelProfileID = selectedID
            modelSettings = state.profiles.first { $0.id == selectedID }?.settings ?? ModelSettings()
        } catch {
            modelSettings = ModelSettings()
            modelProfilesLoadError = error
        }
        repository = suppliedRepository ?? JSONConversationRepository(fileURL: directory.appendingPathComponent("conversations.json"))
        journal = RunJournal(directory: directory.appendingPathComponent("Runs", isDirectory: true))
        skillLibrary = SkillLibrary(directory: directory.appendingPathComponent("Skills", isDirectory: true))
        messageAttachments = MessageAttachments(directory: directory.appendingPathComponent("Attachments", isDirectory: true))
        let current = UIDevice.current
        device = DeviceDescriptor(id: "local", name: current.userInterfaceIdiom == .pad ? String(localized: "device.this_ipad", table: "Runtime") : String(localized: "device.this_iphone", table: "Runtime"),
                                  platform: current.userInterfaceIdiom == .pad ? .iPadOS : .iOS, systemVersion: current.systemVersion)
        do { try deviceSession.configure(method: deviceConnectionMethod, backend: deviceControlBackend) }
        catch { deviceConnectionError = error.localizedDescription }
        bluetoothController.onChange = { [weak self] in
            #if DEBUG
            self?.recordBluetoothSetupStage()
            #endif
            self?.handleBluetoothSessionChange()
        }
        deviceSession.onExternalStop = { [weak self] id, event in
            self?.runCoordinator.interruptTools(expectedRunID: id)
            Task { await self?.stop(expectedRunID: id, reason: String(localized: "connection.lost_stopped", table: "Runtime"), cause: { if case .hardwareStopped = event { .hardwareStop } else { .paused(.connectionLost) } }()) }
        }
        deviceSession.onInvalidateDictation = { [weak self] _, _ in self?.invalidateDictationDeviceRestoration() }
        deviceSession.onExternalOutcome = { [weak self] outcome in
            guard outcome.invalidatesPreview else { return }
            self?.screenshot = nil
        }
        bluetoothController.onHardwareStop = { [weak self] _ in self?.handleBoardHardwareStop() }
        if let route = BluetoothBoardInputRoute(rawValue: defaults.string(forKey: "bluetoothInputRoute") ?? "") {
            try? bluetoothController.selectInputRoute(route)
        }
        do { try self.background.register() } catch { connectionMessage = error.localizedDescription }
        localTunnel.onDisconnect = { [weak self] in
            guard let self else { return }
            if self.dictationDeviceRestoration?.method == .localVPN { self.invalidateDictationDeviceRestoration() }
            guard self.activeDeviceConnectionMethod == .localVPN || self.isPairing else { return }
            let runID = self.activeRun?.id
            if self.isDeviceReady && !self.isStoppingTunnel {
                self.deviceConnectionError = String(localized: "connection.lost", table: "Runtime")
            }
            self.deviceSession.handle(.transportLost)
            let identity = self.deviceSession.identity
            self.screenshot = nil
            if self.activeRun?.scope != .chat { self.runCoordinator.interruptTools(expectedRunID: runID) }
            Task {
                guard self.deviceSession.isCurrent(identity),
                      self.deviceConnectionMethod == .localVPN || self.isPairing,
                      self.activeRun == nil || self.activeRun?.id == runID,
                      !self.localTunnel.isConnected else { return }
                await self.disconnectDevice(stopChatRun: false, stopReason: String(localized: "connection.lost_stopped", table: "Runtime"))
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let fixture = ProcessInfo.processInfo.environment["EISCUE_TEST_MODEL_URL"],
           let url = URL(string: fixture), url.host == "127.0.0.1", url.scheme == "http" {
            modelSettings.baseURL = fixture; modelSettings.model = "fixture-model"
            let profile = ModelProfile(id: ModelProfile.legacyID, name: "", settings: modelSettings)
            modelProfiles = [profile]; selectedModelProfileID = profile.id; modelProfilesLoadError = nil
            try? credentials.write("local-fixture-key", account: profile.credentialAccount)
        }
        #endif
    }

    var selectedConversation: Conversation? { conversations.first { $0.id == selectedConversationID } }

    func finishOnboarding() {
        preferences.set(1, forKey: "onboardingVersion")
        showsOnboarding = false
    }
    var isRunning: Bool { activeRun != nil }
    var isBusy: Bool {
        let deviceBusy: Bool
        if case .dictation = deviceSession.owner { deviceBusy = deviceSession.isTransitioning }
        else { deviceBusy = deviceSession.isBusy }
        return isSaving || isRunning || isImportingAttachments || deviceBusy
    }
    var canSend: Bool { !isLoading && !isBusy && deviceSession.owner == nil && dictationDeviceRestoration == nil && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty) }
    var canAddAttachments: Bool { !isLoading && !isBusy && draftAttachments.count < MessageAttachments.maximumCount }
    var isDeviceReady: Bool { if case .ready = deviceStatus { true } else { false } }
    var newRunScope: TaskScope { isDeviceReady ? scope : .chat }
    var hasDeviceContinuation: Bool {
        runs.contains { run in run.scope != .chat &&
            (((run.state == .interrupted || run.state == .outcomeUnknown) && interruptedConversationIDs.contains(run.conversationID)) ||
             (run.state == .paused && runs.first(where: { $0.conversationID == run.conversationID })?.id == run.id)) }
    }
    var isDeviceRunActive: Bool { activeRun.map { $0.scope != .chat } ?? false }
    var canChangeDeviceControl: Bool { !isBusy && !hasDeviceContinuation }
    var canChangeDeviceRoute: Bool {
        guard deviceSession.owner == nil, !isDeviceRunActive, !isSaving, !isImportingAttachments else { return false }
        switch deviceSession.state {
        case .idle, .connected, .connecting: return true
        case .releasing, .switching: return false
        }
    }
    var hasConfiguredModel: Bool { agentAvailability == .ready }
    var agentStatusTitle: String { agentAvailability == .ready ? String(localized: "agent.configured", table: "Runtime") : String(localized: "agent.configure_first", table: "Runtime") }
    var selectedSkill: AgentSkill? { skills.first { $0.id == selectedSkillID } }
    var selectedRuns: [RunRecord] { runs.filter { $0.conversationID == selectedConversationID } }
    var conversationFeed: [ConversationFeedItem] { conversationFeed(for: selectedConversationID) }
    private func conversationFeed(for conversationID: UUID?) -> [ConversationFeedItem] {
        let revision = conversationFeedRevision
        let session = runCoordinator.current
        let runID = session?.id, activityRevision = session?.activityRevision
        if let cached = cachedConversationFeed, cached.revision == revision, cached.conversationID == conversationID,
           cached.runID == runID, cached.activityRevision == activityRevision {
            return cached.items
        }
        var records = runs.filter { $0.conversationID == conversationID }
        if let activeRun, activeRun.conversationID == conversationID {
            records.removeAll { $0.id == activeRun.id }
            records.append(activeRun)
        }
        let items = ConversationFeedItem.merge(messages: conversations.first { $0.id == conversationID }?.messages ?? [],
                                              activities: records.flatMap { $0.activities ?? [] })
        cachedConversationFeed = (revision, conversationID, runID, activityRevision, items)
        return items
    }
    var isHoldingDeviceTranscript: Bool {
        guard let snapshot = controlTranscriptSnapshot, let activeRun else { return false }
        return activeRun.id == snapshot.runID && activeRun.scope == .control && selectedConversationID == snapshot.conversationID
    }
    var displayedConversationFeed: [ConversationFeedItem] {
        if isHoldingDeviceTranscript, let snapshot = controlTranscriptSnapshot { return snapshot.feed }
        return conversationFeed
    }
    var displayedStreamingText: String { isHoldingDeviceTranscript ? controlTranscriptSnapshot?.text ?? "" : streamingText }
    var hasDisplayedStreamingText: Bool { isHoldingDeviceTranscript ? !(controlTranscriptSnapshot?.text.isEmpty ?? true) : hasStreamingText }
    var isShowingDeviceControlRun: Bool { activeRun?.scope == .control && activeRun?.conversationID == selectedConversationID }

    func holdDeviceTranscript(for runID: UUID) {
        guard let run = activeRun, run.id == runID, run.scope == .control else { return }
        // Publish the previous step, then keep exactly this presentation stable
        // until the observed action finishes. Durable events continue recording.
        controlTranscriptSnapshot = (run.id, run.conversationID, conversationFeed(for: run.conversationID), streamingText)
    }

    func releaseDeviceTranscript(for runID: UUID) {
        guard controlTranscriptSnapshot?.runID == runID else { return }
        controlTranscriptSnapshot = nil
    }

    func prepareDeviceObservation(for runID: UUID) async {
        guard activeRun?.id == runID, activeRun?.scope == .control else { return }
        holdDeviceTranscript(for: runID)
        // Give SwiftUI and ReplayKit time to publish the step boundary. This is
        // presentation settling, never an exemption from the frame freshness gate.
        try? await Task.sleep(for: .milliseconds(180))
    }

    var pausedRun: RunRecord? {
        guard let run = selectedRuns.first, run.state == .paused else { return nil }
        return run
    }
    var needsRecovery: Bool {
        guard let id = selectedConversationID else { return false }
        return interruptedConversationIDs.contains(id) || pendingRequestID(in: selectedConversation) != nil
    }
    private var submissionStates: [UUID: RunSubmission] {
        if let cached = submissionCache, cached.revision == runRevision,
           cached.requestID == activeRun?.requestID, cached.submission == activeRun?.submission { return cached.states }
        var states: [UUID: RunSubmission] = [:]
        for run in ([activeRun].compactMap { $0 } + runs) where states[run.requestID] == nil {
            states[run.requestID] = run.submission ?? .accepted
        }
        submissionCache = (runRevision, activeRun?.requestID, activeRun?.submission, states)
        return states
    }
    var unsubmittedMessageIDs: Set<UUID> {
        let states = submissionStates
        var result = Set(states.filter { $0.value != .accepted }.map(\.key))
        for conversation in conversations {
            if let id = conversation.pendingRequestID, states[id] != .accepted { result.insert(id) }
        }
        return result
    }
    private func pendingRequestID(in conversation: Conversation?) -> UUID? {
        guard let id = conversation?.pendingRequestID else { return nil }
        let state = submissionStates[id]
        return state == .accepted || state == .abandoned ? nil : id
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        defer { isLoading = false }
        // Each store fails independently. A damaged conversation file, run record
        // or skill must not also disable device monitoring, tunnels or recovery.
        var failures: [String] = []
        do {
            let loaded = try await repository.loadResult()
            conversations = loaded.conversations
            if !loaded.corruptIDs.isEmpty { failures.append(ConversationStoreError.corruptConversations(loaded.corruptIDs).localizedDescription) }
            if let failure = loaded.maintenanceFailure { failures.append(failure) }
        } catch { failures.append(error.localizedDescription) }
        do {
            let loaded = try await journal.load()
            failures += loaded.failures
            runs = loaded.records
            for index in runs.indices where runs[index].state == .running || runs[index].state == .preparing {
                runs[index].state = .interrupted
                runs[index].detail = String(localized: "run.recovered_interruption", table: "Runtime")
                runs[index].endedAt = Date()
                runs[index].interruptOpenActivities()
                do { try await journal.save(runs[index]) } catch { failures.append(error.localizedDescription) }
            }
            var latestStates: [UUID: RunState] = [:]
            for run in runs where latestStates[run.conversationID] == nil { latestStates[run.conversationID] = run.state }
            interruptedConversationIDs = Set(latestStates.filter { $0.value == .interrupted || $0.value == .outcomeUnknown }.map(\.key))
        } catch { failures.append(error.localizedDescription) }
        do { skills = try skillLibrary.load() } catch { failures.append(error.localizedDescription) }
        if let saved = preferences.string(forKey: "selectedConversationID"),
           let id = UUID(uuidString: saved), conversations.contains(where: { $0.id == id }) { selectedConversationID = id }
        do {
            if let modelProfilesLoadError { throw modelProfilesLoadError }
            try refreshAgentConfiguration()
        } catch {
            configuredAgent = agentFactory(nil, runtimeDirectory, []); agentAvailability = .unconfigured
            failures.append(error.localizedDescription)
        }
        do { try await localTunnel.refresh() }
        catch { connectionMessage = error.localizedDescription }
        await refreshDeviceStatus()
        startBluetoothMonitor()
        refreshPairingTransfer()
        #if DEBUG
        await runRequestedDeviceSetupCheck()
        #endif
        await taskNotifications.refreshAuthorization()
        await recoverSelectedConversation()
        if !failures.isEmpty {
            errorMessage = String(format: String(localized: "error.load_data", table: "Runtime"), sanitizedText(failures.joined(separator: "\n")))
        }
    }

    func newConversation() {
        guard !isBusy else { return }
        composerSessionID = UUID()
        discardDraftAttachments()
        selectedConversationID = nil; draft = ""; runCoordinator.clearStreamingText()
        preferences.removeObject(forKey: "selectedConversationID")
    }

    func select(_ conversation: Conversation) {
        guard !isBusy else { return }
        composerSessionID = UUID()
        discardDraftAttachments()
        selectedConversationID = conversation.id; draft = ""; runCoordinator.clearStreamingText()
        preferences.set(conversation.id.uuidString, forKey: "selectedConversationID")
        Task { await recoverSelectedConversation() }
    }

    func recoverSelectedConversation() async {
        guard !isBusy, let id = selectedConversationID, let configuredAgent else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let recovery = try await configuredAgent.recover(conversationID: id)
            guard selectedConversationID == id, !isRunning else { return }
            try await applyRecovery(recovery, conversationID: id)
        } catch { errorMessage = String(format: String(localized: "error.recover_chat", table: "Runtime"), error.localizedDescription) }
    }

    private func applyRecovery(_ recovery: AgentRecovery, conversationID: UUID) async throws {
        if recovery.hasInterruptedRun { interruptedConversationIDs.insert(conversationID) }
        let acceptedIDs = recovery.acceptedRequestIDs
        // SQLite admission is authoritative in both directions. Abandonment is
        // a separate user decision, retained only while no admission exists.
        for index in runs.indices where runs[index].conversationID == conversationID {
            var record = runs[index]
            let submission: RunSubmission = acceptedIDs.contains(record.requestID) ? .accepted : record.submission == .abandoned ? .abandoned : .pending
            guard record.submission != submission else { continue }
            record.submission = submission
            try await journal.save(record); runs[index] = record
        }
        guard var conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        conversation.messages = Self.reconciled(local: conversation.messages, runtime: recovery.messages, unsubmittedIDs: unsubmittedMessageIDs)
        if let id = conversation.pendingRequestID,
           acceptedIDs.contains(id) || submissionStates[id] == .abandoned {
            conversation.pendingRequestID = nil
        }
        // Older versions saved the message before any pending record existed.
        // Recover only the unmatched trailing user message, never seed it as
        // accepted history or infer acceptance from a previous identical prompt.
        if conversation.pendingRequestID == nil, let message = conversation.messages.last, message.role == .user,
           !acceptedIDs.contains(message.id), submissionStates[message.id] != .abandoned {
            conversation.pendingRequestID = message.id
        }
        try await repository.save(conversation); upsert(conversation)
    }

    func sendMessage() async {
        guard canSend else { return }
        guard agentAvailability == .ready else { showsModelSettings = true; return }
        if needsRecovery { errorMessage = String(localized: "run.resolve_interruption", table: "Runtime"); return }
        // Permission makes tools available only for a ready device. Capture it
        // before persistence so connecting later cannot widen this request.
        let runScope = newRunScope
        if runScope != .chat && !modelSettings.supportsImages { errorMessage = String(localized: "run.images_required", table: "Runtime"); return }
        let originalDraft = draft
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draftAttachments
        do { try AgentAttachment.validate(attachments, supportsImages: modelSettings.supportsImages) }
        catch { errorMessage = error.localizedDescription; return }
        isSaving = true; isSubmittingMessage = true
        let previousConversation = selectedConversation
        let previousSelection = selectedConversationID
        var conversation = previousConversation ?? Conversation(title: String((text.isEmpty ? attachments.first?.name ?? "" : text).prefix(40)))
        let history = conversation.messages.filter { !unsubmittedMessageIDs.contains($0.id) }
        let message = AgentMessage(role: .user, text: text, attachments: attachments)
        conversation.messages.append(message); conversation.updatedAt = Date()
        conversation.pendingRequestID = message.id
        // Sending immediately moves the draft onto the transcript. Persistence
        // and provider admission still happen before any model/tool execution.
        composerSessionID = UUID()
        let submissionSession = composerSessionID
        draft = ""; draftAttachments = []
        runCoordinator.clearStreamingText()
        upsert(conversation); selectedConversationID = conversation.id
        do {
            try await repository.save(conversation)
            preferences.set(conversation.id.uuidString, forKey: "selectedConversationID")
            isSaving = false
            if hapticsEnabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            _ = await perform(conversationID: conversation.id, requestID: message.id, prompt: text, history: history, resume: false, attachments: attachments, runScope: runScope)
        } catch {
            // A local save failure did not submit the message. Remove only the
            // optimistic copy; restore the draft without overwriting new edits.
            conversations.removeAll { $0.id == conversation.id }
            if let previousConversation { upsert(previousConversation) }
            if selectedConversationID == conversation.id { selectedConversationID = previousSelection }
            if composerSessionID == submissionSession, draft.isEmpty, draftAttachments.isEmpty {
                draft = originalDraft; draftAttachments = attachments
            }
            isSaving = false
            errorMessage = String(format: String(localized: "error.save_message", table: "Runtime"), safeError(error))
        }
        isSubmittingMessage = false
    }

    var continuationNotice: String? {
        guard let pendingID = pendingRequestID(in: selectedConversation),
              !selectedRuns.contains(where: { $0.requestID == pendingID }) else { return nil }
        return String(localized: "run.missing_record_chat", table: "Runtime")
    }

    func continueInterruptedRun() async {
        guard !isBusy, let id = selectedConversationID, let configuredAgent else { return }
        guard agentAvailability == .ready else { showsModelSettings = true; return }
        isSaving = true
        do {
            let recovery = try await configuredAgent.recover(conversationID: id)
            try await applyRecovery(recovery, conversationID: id)
            // A message can survive without its first journal record. Never
            // borrow an unrelated earlier task's device permission for it.
            let continuationScope: TaskScope
            if let pendingID = pendingRequestID(in: selectedConversation) {
                continuationScope = selectedRuns.first { $0.requestID == pendingID }?.scope ?? .chat
            } else { continuationScope = selectedRuns.first?.scope ?? .chat }
            if continuationScope != .chat && !allowsDeviceControl {
                isSaving = false; errorMessage = String(localized: "run.enable_control_first", table: "Runtime"); return
            }
            if continuationScope != .chat && !isDeviceReady {
                isSaving = false; errorMessage = String(localized: "run.reconnect_first", table: "Runtime"); return
            }
            if continuationScope != .chat && !modelSettings.supportsImages {
                isSaving = false; errorMessage = String(localized: "run.images_required", table: "Runtime"); return
            }
            if recovery.hasInterruptedRun {
                let original = selectedConversation?.messages.first(where: { $0.id == selectedRuns.first?.requestID })
                    ?? recovery.messages.last(where: { $0.role == .user })
                isSaving = false
                let finished = await perform(conversationID: id, requestID: selectedRuns.first?.requestID ?? UUID(), prompt: "", history: [], resume: true, runScope: continuationScope)
                if finished { clearDraftMatching(original) }
            } else if let conversation = selectedConversation,
                      let requestID = pendingRequestID(in: conversation) ?? selectedRuns.first.flatMap({ $0.submission == .pending ? $0.requestID : nil }),
                      let original = conversation.messages.first(where: { $0.id == requestID }) {
                let history = conversation.messages.prefix { $0.id != original.id }.filter { !unsubmittedMessageIDs.contains($0.id) }
                isSaving = false
                let finished = await perform(conversationID: id, requestID: original.id, prompt: original.text, history: history, resume: false, attachments: original.attachments, runScope: continuationScope)
                if finished { clearDraftMatching(original) }
            } else if var conversation = selectedConversation {
                let original = conversation.messages.last(where: { $0.role == .user })
                let message = AgentMessage(role: .user, text: pausedRun != nil
                    ? String(localized: "run.paused.resume_prompt", table: "Runtime")
                    : String(localized: "run.resume_prompt", table: "Runtime"))
                let history = conversation.messages.filter { !unsubmittedMessageIDs.contains($0.id) }
                conversation.messages.append(message); conversation.updatedAt = Date()
                conversation.pendingRequestID = message.id
                try await repository.save(conversation); upsert(conversation)
                isSaving = false
                let finished = await perform(conversationID: id, requestID: message.id, prompt: message.text, history: history, resume: false, runScope: continuationScope)
                if finished { clearDraftMatching(original) }
            } else { isSaving = false }
        } catch { isSaving = false; errorMessage = safeError(error) }
    }

    func abandonInterruptedRun() async {
        guard !isBusy, let id = selectedConversationID, let configuredAgent else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await configuredAgent.cancel(conversationID: id)
            // A process can exit after the atomic message save but before the
            // first run record. Preserve its exclusion from future model history.
            if let requestID = pendingRequestID(in: selectedConversation),
               !selectedRuns.contains(where: { $0.requestID == requestID }) {
                var record = RunRecord(id: UUID(), conversationID: id, requestID: requestID, startedAt: Date(),
                                       scope: .chat, model: modelSettings.model, skill: nil, state: .failed,
                                       endedAt: Date(), detail: String(localized: "run.ended_by_user", table: "Runtime"), events: [])
                record.submission = .abandoned
                try await journal.save(record)
                runs.insert(record, at: 0)
            }
            for index in runs.indices where runs[index].conversationID == id &&
                (runs[index].state == .interrupted || runs[index].state == .outcomeUnknown || runs[index].state == .paused || runs[index].submission == .pending) {
                var record = runs[index]
                record.state = .failed; record.pauseReason = nil; record.detail = String(localized: "run.ended_by_user", table: "Runtime")
                if record.submission == .pending { record.submission = .abandoned }
                try await journal.save(record); runs[index] = record
            }
            if var conversation = selectedConversation, conversation.pendingRequestID != nil {
                conversation.pendingRequestID = nil
                try await repository.save(conversation); upsert(conversation)
            }
            interruptedConversationIDs.remove(id)
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    private func perform(conversationID: UUID, requestID: UUID, prompt: String, history: [AgentMessage], resume: Bool, attachments: [AgentAttachment] = [], runScope: TaskScope) async -> Bool {
        await runCoordinator.perform(conversationID: conversationID, requestID: requestID, prompt: prompt,
                                     history: history, resume: resume, attachments: attachments, runScope: runScope)
    }

    func stop(expectedRunID: UUID? = nil, reason: String = String(localized: "run.user_stopped", table: "Runtime"), cause: StopCause = .userRequested) async {
        await runCoordinator.stop(expectedRunID: expectedRunID, reason: reason, cause: cause)
    }

    func sceneChanged(_ phase: ScenePhase) {
        currentScenePhase = phase
        if phase == .background { deviceSession.handle(.backgrounded); invalidateDictationDeviceRestoration() }
        if phase == .active {
            refreshPairingTransfer()
            Task { await taskNotifications.refreshAuthorization() }
        }
        // Connection lifetime is user-controlled. A scene transition alone
        // does not end it or create a background execution lease.
        if phase == .background, let run = activeRun, run.scope == .chat {
            Task { [weak self] in
                guard let self, self.currentScenePhase == .background else { return }
                await self.stop(expectedRunID: run.id, reason: String(localized: "run.chat_backgrounded", table: "Runtime"))
            }
        }
    }

    func logEvent(_ kind: String, _ summary: String) async throws {
        try await runCoordinator.logEvent(kind, summary)
    }

    func updateTaskStatus(isFinishing: Bool = false) {
        runCoordinator.updateTaskStatus(isFinishing: isFinishing)
    }

    func taskStatusPresentation(isFinishing: Bool = false) -> TaskStatusPresentation? {
        guard var run = activeRun, run.scope != .chat else { return nil }
        // A successful model turn still has device cleanup and durable writes
        // ahead of it. Runner stop callbacks must retain the host's finalizing
        // state until cleanup and the final journal write both finish.
        let finishing = isFinishing || isStopping || companionFinalizingRunID == run.id
            || (stopRequested && run.endedAt == nil)
        if finishing, run.state == .completed { run.state = .running }
        return TaskStatusPresentation.snapshot(for: run, currentTool: currentTool,
                                               isReceivingResponse: isReceivingResponse,
                                               isFinishing: finishing, devicePhase: deviceTools?.phase)
    }

    func persistActiveRun() async throws { try await runCoordinator.persistActiveRun() }

    func delete(_ conversation: Conversation) async {
        await deleteConversations([conversation.id])
    }

    func deleteConversations(_ ids: Set<UUID>) async {
        guard !isLoading, !isBusy else { return }
        let selected = conversations.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        isSaving = true; defer { isSaving = false }
        do {
            for conversation in selected { try await deleteStoredConversation(conversation) }
        } catch { errorMessage = String(format: String(localized: "error.delete_partial", table: "Runtime"), safeError(error)) }
    }

    private func deleteStoredConversation(_ conversation: Conversation) async throws {
        let runIDs = try await journal.runIDsForDeletion(conversationID: conversation.id, knownRecords: runs)
        let runtime = configuredAgent ?? agentFactory(nil, runtimeDirectory, [])
        try await runtime.removeConversation(id: conversation.id)
        try await journal.delete(ids: runIDs)
        try await repository.delete(id: conversation.id)
        toolImagePreviews.remove(conversationID: conversation.id)
        conversations.removeAll { $0.id == conversation.id }; runs.removeAll { $0.conversationID == conversation.id }
        interruptedConversationIDs.remove(conversation.id)
        if selectedConversationID == conversation.id { composerSessionID = UUID(); discardDraftAttachments(); selectedConversationID = nil; draft = ""; preferences.removeObject(forKey: "selectedConversationID") }
        await removeStoredAttachmentsIfUnreferenced(conversation.messages.flatMap { $0.attachments.map(\.id) })
    }

    func importSkill(_ url: URL) {
        do { let skill = try skillLibrary.importFile(url); skills = try skillLibrary.load(); selectedSkillID = skill.id }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteSkill(_ skill: AgentSkill) {
        guard !isBusy else { return }
        do { try skillLibrary.delete(skill); skills = try skillLibrary.load(); if selectedSkillID == skill.id { selectedSkillID = nil } }
        catch { errorMessage = error.localizedDescription }
    }

    func upsert(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }; conversations.append(conversation)
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Runtime entries have stable runtime IDs. A local user message may not
    /// have reached submit yet (for example when the execution lease failed).
    /// Keep that unaccepted suffix instead of overwriting it with older history.
    static func reconciled(local: [AgentMessage], runtime: [AgentMessage], unsubmittedIDs: Set<UUID> = []) -> [AgentMessage] {
        guard !runtime.isEmpty else { return local }
        var cursor = 0
        var seenLocalIDs = Set<UUID>()
        var pendingUsers: [AgentMessage] = []
        var insertions: [Int: [AgentMessage]] = [:]
        for message in local where message.role == .user {
            guard seenLocalIDs.insert(message.id).inserted else { continue }
            if let match = runtime.firstIndex(where: { $0.id == message.id }) {
                if match >= cursor {
                    insertions[match, default: []] += pendingUsers
                    pendingUsers = []
                    cursor = match + 1
                }
                continue
            }
            if unsubmittedIDs.contains(message.id) { pendingUsers.append(message); continue }
            if let match = runtime.indices.dropFirst(cursor).first(where: {
                runtime[$0].role == message.role && runtime[$0].text == message.text && runtime[$0].attachments == message.attachments
            }) {
                insertions[match, default: []] += pendingUsers
                pendingUsers = []
                cursor = match + 1
            } else {
                pendingUsers.append(message)
            }
        }
        var merged: [AgentMessage] = []
        for (index, message) in runtime.enumerated() {
            merged += insertions[index, default: []]
            merged.append(message)
        }
        merged += pendingUsers
        return merged
    }

    func safeError(_ error: Error) -> String {
        ModelFailurePresentation.message(for: error, api: modelSettings.api, baseURL: modelSettings.baseURL)
            ?? sanitizedText(error.localizedDescription)
    }

    func sanitizedText(_ text: String) -> String { redacted(text, limit: 1000) }
    func sanitizedActivityText(_ text: String) -> String { redacted(text, limit: 8_192) }

    private func redacted(_ text: String, limit: Int) -> String {
        var value = text
        for key in modelKeysForRedaction {
            value = value.replacingOccurrences(of: key, with: String(localized: "privacy.redacted_key", table: "Runtime"))
        }
        return String(value.prefix(limit))
    }
}
