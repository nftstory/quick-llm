import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI

final class QuickAskLog {
    static let shared = QuickAskLog()

    private let queue = DispatchQueue(label: "app.quickask.log", qos: .utility)
    private let formatter: ISO8601DateFormatter
    private let logURL: URL

    private init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Quick Ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        self.logURL = logsDirectory.appendingPathComponent("quick-ask.log", isDirectory: false)
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func write(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: self.logURL.path) {
                do {
                    let handle = try FileHandle(forWritingTo: self.logURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    return
                }
            } else {
                try? data.write(to: self.logURL, options: .atomic)
            }
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

struct QueuedPrompt: Identifiable, Equatable {
    let id: UUID
    let content: String

    init(id: UUID = UUID(), content: String) {
        self.id = id
        self.content = content
    }
}

struct ModelOption: Codable, Identifiable, Equatable {
    let id: String
    let provider: String
    let model: String
    let label: String
    let short_label: String
    let hint: String?
    let endpoint: String?
    let `default`: Bool?

    var shortLabel: String { short_label }
}

private struct ModelsEnvelope: Codable {
    let type: String
    let models: [ModelOption]
}

struct QuickAskHistorySession: Codable, Identifiable, Equatable {
    let sessionID: String
    let createdAt: String
    let savedAt: String
    let model: String
    let modelID: String
    let endpointLabel: String
    let messageCount: Int
    let preview: String

    var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case createdAt = "created_at"
        case savedAt = "saved_at"
        case model
        case modelID = "model_id"
        case endpointLabel = "endpoint_label"
        case messageCount = "message_count"
        case preview
    }
}

struct QuickAskHistoryEnvelope: Codable {
    let type: String
    let sessions: [QuickAskHistorySession]
}

struct QuickAskTranscriptMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct QuickAskLoadedSession: Codable {
    let sessionID: String
    let createdAt: String
    let savedAt: String
    let model: String
    let modelID: String
    let messages: [QuickAskTranscriptMessage]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case createdAt = "created_at"
        case savedAt = "saved_at"
        case model
        case modelID = "model_id"
        case messages
    }
}

struct QuickAskLoadedEnvelope: Codable {
    let type: String
    let session: QuickAskLoadedSession
}

struct QuickAskProviderStatus: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let available: Bool
    let loggedIn: Bool
    let detail: String
    let setupCommand: String?

    var isReady: Bool { available && loggedIn }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case available
        case loggedIn = "logged_in"
        case detail
        case setupCommand = "setup_command"
    }
}

private struct QuickAskProvidersEnvelope: Codable {
    let type: String
    let providers: [QuickAskProviderStatus]
}

private struct HistoryHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct InputBarFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty {
            value = next
        }
    }
}

private enum QuickAskTheme {
    static let frameBackground = Color(red: 0.55, green: 0.79, blue: 0.77)
    static let historyBackground = Color(red: 0.55, green: 0.79, blue: 0.77)
    static let inputBackground = Color(red: 0.55, green: 0.79, blue: 0.77)
    static let dividerColor = Color.black.opacity(0.18)
    static let strongText = Color(red: 0.03, green: 0.16, blue: 0.16)
    static let mutedText = Color(red: 0.03, green: 0.16, blue: 0.16).opacity(0.78)
    static let panelAccent = Color.white.opacity(0.18)
}

private func quickAskUserDefaults() -> UserDefaults {
    let environment = ProcessInfo.processInfo.environment
    if let suiteName = environment["QUICK_ASK_USER_DEFAULTS_SUITE"],
       !suiteName.isEmpty,
       let defaults = UserDefaults(suiteName: suiteName) {
        return defaults
    }
    return .standard
}

@MainActor
final class QuickAskAppSettings: ObservableObject {
    @Published var historyEnabled: Bool
    @Published private(set) var customArchiveDirectoryPath: String
    @Published private(set) var setupCompleted: Bool
    @Published private(set) var providerStatuses: [QuickAskProviderStatus] = []
    @Published private(set) var availableModels: [ModelOption] = []
    @Published private(set) var isRefreshingProviders = false
    @Published private(set) var providerStatusMessage = ""
    @Published private(set) var keychainReady = false
    @Published private(set) var storageDetail = ""

    private let defaults: UserDefaults
    private let archiveDirectoryKey = "QuickAskCustomArchiveDirectory"
    private let historyEnabledKey = "QuickAskHistoryEnabled"
    private let setupCompletedKey = "QuickAskSetupCompleted"
    private let hiddenModelIDsKey = "QuickAskHiddenModelIDs"
    private let archiveAppFolderName = "Quick Ask"
    private let archiveSessionsFolderName = "sessions"
    private let defaultHiddenModelIDs: Set<String> = ["codex::gpt-5.4-mini"]
    private var hiddenModelIDs: Set<String>

    init(defaults: UserDefaults = quickAskUserDefaults()) {
        self.defaults = defaults
        if defaults.object(forKey: historyEnabledKey) != nil {
            self.historyEnabled = defaults.bool(forKey: historyEnabledKey)
        } else {
            self.historyEnabled = true
        }
        self.customArchiveDirectoryPath = defaults.string(forKey: archiveDirectoryKey) ?? ""
        self.setupCompleted = defaults.bool(forKey: setupCompletedKey)
        if let stored = defaults.array(forKey: hiddenModelIDsKey) as? [String] {
            self.hiddenModelIDs = Set(stored)
        } else {
            self.hiddenModelIDs = defaultHiddenModelIDs
        }
    }

    var customArchiveDirectory: URL? {
        let trimmed = customArchiveDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return normalizedArchiveDirectory(from: URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath))
    }

    var effectiveArchiveDirectory: URL? {
        guard historyEnabled else { return nil }
        return customArchiveDirectory ?? defaultArchiveDirectory
    }

    var defaultArchiveDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dropboxCandidates = [
            home.appendingPathComponent("Library/CloudStorage/Dropbox", isDirectory: true),
            home.appendingPathComponent("Dropbox", isDirectory: true),
        ]
        let baseDirectory = dropboxCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return normalizedArchiveDirectory(from: baseDirectory)
    }

    var requiresArchiveFolderChoice: Bool {
        false
    }

    var canContinuePastSetup: Bool {
        !historyEnabled || effectiveArchiveDirectory != nil
    }

    var requiresInitialSetup: Bool {
        !canContinuePastSetup
    }

    var archiveDirectorySummary: String {
        if !historyEnabled {
            return "Disabled"
        }
        return customArchiveDirectory == nil ? "Default" : "Custom"
    }

    var archiveDirectoryDetail: String {
        if !historyEnabled {
            return "History is off."
        }
        return effectiveArchiveDirectory?.path ?? "History is enabled, but no archive location is available."
    }

    func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if !historyEnabled || effectiveArchiveDirectory == nil {
            environment["QUICK_ASK_DISABLE_HISTORY"] = "1"
            environment.removeValue(forKey: "QUICK_ASK_SAVE_DIR")
        } else if let effectiveArchiveDirectory {
            environment["QUICK_ASK_SAVE_DIR"] = effectiveArchiveDirectory.path
            environment.removeValue(forKey: "QUICK_ASK_DISABLE_HISTORY")
        } else {
            environment.removeValue(forKey: "QUICK_ASK_SAVE_DIR")
        }
        return environment
    }

    func setHistoryEnabled(_ enabled: Bool) {
        historyEnabled = enabled
        defaults.set(enabled, forKey: historyEnabledKey)
    }

    func setCustomArchiveDirectory(_ url: URL) {
        let standardized = normalizedArchiveDirectory(from: url)
        try? FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
        customArchiveDirectoryPath = standardized.path
        defaults.set(standardized.path, forKey: archiveDirectoryKey)
    }

    func clearCustomArchiveDirectory() {
        customArchiveDirectoryPath = ""
        defaults.removeObject(forKey: archiveDirectoryKey)
    }

    func setAvailableModels(_ models: [ModelOption]) {
        if availableModels != models {
            availableModels = models
        }
    }

    func isModelVisible(_ modelID: String) -> Bool {
        !hiddenModelIDs.contains(modelID)
    }

    func setModelVisible(_ modelID: String, visible: Bool) {
        if visible {
            hiddenModelIDs.remove(modelID)
        } else {
            hiddenModelIDs.insert(modelID)
        }
        defaults.set(Array(hiddenModelIDs).sorted(), forKey: hiddenModelIDsKey)
        objectWillChange.send()
    }

    func visibleModels(from models: [ModelOption]) -> [ModelOption] {
        setAvailableModels(models)
        return models.filter { isModelVisible($0.id) }
    }

    func archiveFolderSelectionHint() -> String {
        let defaultParent = defaultArchiveDirectory.deletingLastPathComponent().deletingLastPathComponent()
        return "Quick Ask will save into a \(archiveAppFolderName) subfolder inside the folder you choose. Default: \(defaultParent.path)"
    }

    private func normalizedArchiveDirectory(from url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.lastPathComponent == archiveSessionsFolderName {
            return standardized
        }
        if standardized.lastPathComponent == archiveAppFolderName {
            return standardized.appendingPathComponent(archiveSessionsFolderName, isDirectory: true)
        }
        return standardized
            .appendingPathComponent(archiveAppFolderName, isDirectory: true)
            .appendingPathComponent(archiveSessionsFolderName, isDirectory: true)
    }

    func markSetupCompleted() {
        setupCompleted = true
        defaults.set(true, forKey: setupCompletedKey)
    }

    func refreshProviderStatuses(backendPath: String) {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        providerStatusMessage = ""
        let processEnvironment = processEnvironment()

        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", backendPath, "providers"]
            process.environment = processEnvironment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                if let payload = try? JSONDecoder().decode(QuickAskProvidersEnvelope.self, from: stdoutData),
                   payload.type == "providers" {
                    await MainActor.run {
                        self.providerStatuses = payload.providers
                        self.providerStatusMessage = ""
                        self.isRefreshingProviders = false
                    }
                    return
                }

                let message = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.providerStatusMessage = message?.isEmpty == false ? (message ?? "Could not check CLI logins.") : "Could not check CLI logins."
                    self.isRefreshingProviders = false
                }
            } catch {
                await MainActor.run {
                    self.providerStatusMessage = "Could not check CLI logins."
                    self.isRefreshingProviders = false
                }
            }
        }
    }

    func refreshStorageStatus(backendPath: String, ensureKey: Bool) {
        let processEnvironment = processEnvironment()
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", backendPath, "storage"] + (ensureKey ? ["--ensure-key"] : [])
            process.environment = processEnvironment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                if let payload = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any],
                   let ready = payload["keychain_ready"] as? Bool {
                    let detail = payload["detail"] as? String ?? ""
                    await MainActor.run {
                        self.keychainReady = ready
                        self.storageDetail = detail
                    }
                    return
                }
            } catch {}

            await MainActor.run {
                self.keychainReady = false
                self.storageDetail = "Could not verify encrypted history readiness."
            }
        }
    }
}

private struct CodableRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }
}

private struct QuickAskUITestState: Codable {
    let panelVisible: Bool
    let historyWindowVisible: Bool
    let settingsWindowVisible: Bool
    let shortcutsWindowVisible: Bool
    let panelIsKeyWindow: Bool
    let panelFrame: CodableRect
    let settingsFrame: CodableRect
    let inputBarFrame: CodableRect
    let inputBarBottomInset: Double
    let historyAreaHeight: Double
    let historySessionIDs: [String]
    let messageCount: Int
    let queuedCount: Int
    let queuedPromptContents: [String]
    let isGenerating: Bool
    let focusRequestCount: Int
    let frontmostAppName: String
    let selectedModel: String
    let visibleModelIDs: [String]
    let inputText: String
    let setupRequired: Bool
    let historyEnabled: Bool
    let screenVisibleHeight: Double
    let handledCommandID: Int
}

private struct QuickAskUITestCommand: Codable {
    let id: Int
    let action: String
    let text: String?
    let shortcut: String?
}

@MainActor
protocol QuickAskLayoutDelegate: AnyObject {
    func quickAskNeedsLayout()
}

@MainActor
final class QuickAskViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var queuedPrompts: [QueuedPrompt] = []
    @Published var inputText = ""
    @Published var inputBarFrame: CGRect = .zero
    @Published var historyAreaHeight: CGFloat = 0
    @Published var models: [ModelOption] = []
    @Published var selectedModelID = "claude::claude-opus-4-6"
    @Published var isGenerating = false
    @Published var focusToken = UUID()
    @Published private(set) var focusRequestCount = 0
    @Published var statusText = ""

    weak var layoutDelegate: QuickAskLayoutDelegate?

    private let backendPath: String
    private let processEnvironmentProvider: () -> [String: String]
    private let visibleModelsProvider: ([ModelOption]) -> [ModelOption]
    private let availableModelsObserver: ([ModelOption]) -> Void
    private let defaults: UserDefaults
    private let lastModelKey = "QuickAskSelectedModelID"
    private let idleTimeout: TimeInterval = 45
    private let uiTestMode = ProcessInfo.processInfo.environment["QUICK_ASK_UI_TEST_MODE"] == "1"
    private var idleTimer: Timer?
    private var lastInteractionAt = Date()
    private var activeProcess: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var activeAssistantMessageID: UUID?
    private var sessionID = UUID().uuidString
    private var sessionCreatedAt = QuickAskViewModel.timestampString(for: Date())
    private let saveQueue = DispatchQueue(label: "app.quickask.save", qos: .utility)
    private var pendingResetAfterTermination = false
    private var pendingResetPreserveInput = false
    private var pendingSteerPromptID: UUID?
    private var currentTurnStreamedAny = false

    init(
        backendPath: String,
        processEnvironmentProvider: @escaping () -> [String: String],
        visibleModelsProvider: @escaping ([ModelOption]) -> [ModelOption] = { $0 },
        availableModelsObserver: @escaping ([ModelOption]) -> Void = { _ in },
        defaults: UserDefaults = quickAskUserDefaults()
    ) {
        self.backendPath = backendPath
        self.processEnvironmentProvider = processEnvironmentProvider
        self.visibleModelsProvider = visibleModelsProvider
        self.availableModelsObserver = availableModelsObserver
        self.defaults = defaults
        if let storedModel = defaults.string(forKey: lastModelKey), !storedModel.isEmpty {
            selectedModelID = storedModel
        }
        startIdleTimer()
    }

    deinit {
        idleTimer?.invalidate()
    }

    func requestFocus() {
        QuickAskLog.shared.write("view-model requestFocus")
        focusRequestCount += 1
        focusToken = UUID()
    }

    func touch() {
        lastInteractionAt = Date()
    }

    func panelShown() {
        touch()
        QuickAskLog.shared.write("panel shown")
        requestFocus()
    }

    func panelHidden() {
        touch()
        QuickAskLog.shared.write("panel hidden")
        saveTranscript()
    }

    func setHistoryAreaHeight(_ value: CGFloat) {
        let clamped = min(max(value, 0), 450)
        if abs(clamped - historyAreaHeight) > 0.5 {
            historyAreaHeight = clamped
            layoutDelegate?.quickAskNeedsLayout()
        }
    }

    func setInputBarFrame(_ value: CGRect) {
        if abs(value.minY - inputBarFrame.minY) > 0.5 ||
            abs(value.height - inputBarFrame.height) > 0.5 ||
            abs(value.width - inputBarFrame.width) > 0.5 {
            inputBarFrame = value
        }
    }

    func loadModels() {
        if uiTestMode {
            applyLoadedModels(uiTestModelOptions())
            return
        }

        let backendPath = self.backendPath
        let processEnvironment = self.processEnvironmentProvider()
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", backendPath, "models"]
            process.environment = processEnvironment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                await MainActor.run {
                    self.statusText = "Could not load models."
                }
                return
            }

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let payload = try? JSONDecoder().decode(ModelsEnvelope.self, from: stdoutData),
                  payload.type == "models" else {
                await MainActor.run {
                    self.availableModelsObserver([])
                    self.models = []
                    self.statusText = "Could not load models."
                }
                return
            }

            await MainActor.run {
                self.applyLoadedModels(payload.models)
            }
        }
    }

    private func applyLoadedModels(_ loadedModels: [ModelOption]) {
        availableModelsObserver(loadedModels)
        let visibleModels = visibleModelsProvider(loadedModels)
        models = visibleModels

        let preferredModelID = defaults.string(forKey: lastModelKey)
        if let preferredModelID,
           visibleModels.contains(where: { $0.id == preferredModelID }) {
            selectedModelID = preferredModelID
        } else if let selected = visibleModels.first(where: { $0.id == selectedModelID }) {
            selectedModelID = selected.id
        } else if let defaultModel = visibleModels.first(where: { $0.default == true }) ?? visibleModels.first {
            selectedModelID = defaultModel.id
        }
        if visibleModels.isEmpty {
            statusText = "No enabled models are available."
        } else if statusText == "Could not load models." || statusText == "No enabled models are available." {
            statusText = ""
        }
    }

    private func uiTestModelOptions() -> [ModelOption] {
        [
            ModelOption(id: "claude::claude-opus-4-6", provider: "claude", model: "claude-opus-4-6", label: "Claude Opus 4.6", short_label: "Opus 4.6", hint: "Claude CLI login", endpoint: "claude://login", default: true),
            ModelOption(id: "claude::claude-sonnet-4-6", provider: "claude", model: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", short_label: "Sonnet 4.6", hint: "Claude CLI login", endpoint: "claude://login", default: false),
            ModelOption(id: "codex::gpt-5.4", provider: "codex", model: "gpt-5.4", label: "ChatGPT 5.4", short_label: "ChatGPT 5.4", hint: "Codex CLI login", endpoint: "codex://login", default: false),
            ModelOption(id: "codex::gpt-5.4-mini", provider: "codex", model: "gpt-5.4-mini", label: "ChatGPT 5.4 Mini", short_label: "ChatGPT 5.4 Mini", hint: "Codex CLI login", endpoint: "codex://login", default: false),
            ModelOption(id: "gemini::gemini-3-flash-preview", provider: "gemini", model: "gemini-3-flash-preview", label: "Gemini 3 Flash", short_label: "Gemini 3 Flash", hint: "Gemini CLI login", endpoint: "gemini://login", default: false),
            ModelOption(id: "gemini::gemini-2.5-flash-lite", provider: "gemini", model: "gemini-2.5-flash-lite", label: "Gemini Flash Lite", short_label: "Gemini Flash Lite", hint: "Gemini CLI login", endpoint: "gemini://login", default: false),
            ModelOption(id: "ollama::qwen2.5:14b", provider: "ollama", model: "qwen2.5:14b", label: "Qwen 2.5 14B", short_label: "Qwen 2.5 14B", hint: "Local model", endpoint: "ollama://local", default: false),
        ]
    }

    func selectModel(_ modelID: String) {
        selectedModelID = modelID
        defaults.set(modelID, forKey: lastModelKey)
        touch()
    }

    func clearHistory(preserveInput: Bool = false, preserveStatus: Bool = false) {
        saveTranscript()
        messages = []
        queuedPrompts = []
        historyAreaHeight = 0
        if !preserveInput {
            inputText = ""
        }
        if !preserveStatus {
            statusText = ""
        }
        activeAssistantMessageID = nil
        resetSessionIfNeeded()
        layoutDelegate?.quickAskNeedsLayout()
    }

    func restoreSession(_ session: QuickAskLoadedSession) {
        saveTranscript()
        sessionID = session.sessionID
        sessionCreatedAt = session.createdAt
        statusText = ""
        inputText = ""
        queuedPrompts = []
        isGenerating = false
        activeAssistantMessageID = nil
        stdoutBuffer = Data()
        stderrBuffer = Data()
        activeProcess = nil

        let restoredMessages = session.messages.compactMap { message -> ChatMessage? in
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard role == "user" || role == "assistant" else { return nil }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return ChatMessage(role: role == "user" ? .user : .assistant, content: content)
        }

        messages = restoredMessages

        if models.contains(where: { $0.id == session.modelID }) {
            selectedModelID = session.modelID
            defaults.set(session.modelID, forKey: lastModelKey)
        }

        layoutDelegate?.quickAskNeedsLayout()
        requestFocus()
    }

    func newChat() {
        touch()
        let isAlreadyFreshChat = messages.isEmpty && queuedPrompts.isEmpty
        if isGenerating {
            pendingResetAfterTermination = true
            pendingResetPreserveInput = !isAlreadyFreshChat
            cancelActiveGeneration()
            return
        }

        if isAlreadyFreshChat {
            inputText = ""
            layoutDelegate?.quickAskNeedsLayout()
            requestFocus()
            return
        }

        clearHistory(preserveInput: true, preserveStatus: true)
        requestFocus()
    }

    func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        touch()
        inputText = ""
        if isGenerating {
            queuedPrompts.append(QueuedPrompt(content: trimmed))
            layoutDelegate?.quickAskNeedsLayout()
            requestFocus()
            return
        }

        startGeneration(for: trimmed)
    }

    func steerCurrentInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            steerQueuedPrompt(id: queuedPrompts.first?.id)
            return
        }

        touch()
        inputText = ""
        if isGenerating {
            let queuedPrompt = QueuedPrompt(content: trimmed)
            queuedPrompts.insert(queuedPrompt, at: 0)
            layoutDelegate?.quickAskNeedsLayout()
            pendingSteerPromptID = queuedPrompt.id
            cancelActiveGeneration()
            return
        }

        startGeneration(for: trimmed)
    }

    func steerQueuedPrompt(id: UUID?) {
        touch()
        guard let id else { return }
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return }
        let prompt = queuedPrompts.remove(at: index)
        queuedPrompts.insert(prompt, at: 0)
        layoutDelegate?.quickAskNeedsLayout()
        if isGenerating {
            pendingSteerPromptID = id
            cancelActiveGeneration()
            return
        }
        sendQueuedPrompt(id: id)
    }

    func cancelQueuedPrompt(id: UUID) {
        touch()
        queuedPrompts.removeAll { $0.id == id }
        if pendingSteerPromptID == id {
            pendingSteerPromptID = nil
        }
        layoutDelegate?.quickAskNeedsLayout()
    }

    func clearQueuedPrompts() {
        touch()
        pendingSteerPromptID = nil
        queuedPrompts = []
        layoutDelegate?.quickAskNeedsLayout()
    }

    func persistCurrentTranscript() {
        saveTranscript()
    }

    private func startGeneration(for prompt: String) {
        statusText = ""
        currentTurnStreamedAny = false
        messages.append(ChatMessage(role: .user, content: prompt))
        let assistantID = UUID()
        activeAssistantMessageID = assistantID
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        isGenerating = true
        saveTranscript()
        layoutDelegate?.quickAskNeedsLayout()

        if uiTestMode {
            requestFocus()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", backendPath, "chat", "--model-id", selectedModelID]
        process.environment = processEnvironmentProvider()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdoutBuffer = Data()
        stderrBuffer = Data()
        activeProcess = process

        let historyPayload = messages
            .filter { message in
                if message.role == .assistant && message.id == assistantID && message.content.isEmpty {
                    return false
                }
                return true
            }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            Task { @MainActor in
                self.consumeStdout(chunk)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            Task { @MainActor in
                self.stderrBuffer.append(chunk)
            }
        }

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                let remainingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                if !remainingStdout.isEmpty {
                    self.consumeStdout(remainingStdout)
                }
                let remainingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
                if !remainingStderr.isEmpty {
                    self.stderrBuffer.append(remainingStderr)
                }

                self.finishGeneration(exitCode: process.terminationStatus)
            }
        }

        do {
            try process.run()
            if let data = try? JSONSerialization.data(withJSONObject: ["history": historyPayload]) {
                stdin.fileHandleForWriting.write(data)
            }
            try? stdin.fileHandleForWriting.close()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            activeProcess = nil
            isGenerating = false
            statusText = "Could not start backend."
            trimEmptyAssistantMessage()
            layoutDelegate?.quickAskNeedsLayout()
        }
    }

    private func sendNextQueuedPrompt() {
        guard !isGenerating, let next = queuedPrompts.first else { return }
        queuedPrompts.removeFirst()
        startGeneration(for: next.content)
        requestFocus()
    }

    private func sendQueuedPrompt(id: UUID) {
        guard !isGenerating, let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return }
        let prompt = queuedPrompts.remove(at: index)
        startGeneration(for: prompt.content)
        requestFocus()
    }

    func completeTestGeneration(with text: String) {
        guard uiTestMode, isGenerating else { return }
        if !text.isEmpty {
            appendAssistantChunk(text)
        }
        finishGeneration(exitCode: 0)
    }

    private func cancelActiveGeneration() {
        if let activeProcess {
            activeProcess.terminate()
            return
        }
        finishGeneration(exitCode: 130)
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineRange = stdoutBuffer.firstRange(of: Data([0x0a])) {
            let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)
            guard !lineData.isEmpty else { continue }
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handleBackendLine(line)
        }
    }

    private func handleBackendLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String else {
            return
        }

        touch()
        switch type {
        case "chunk":
            let text = payload["text"] as? String ?? ""
            appendAssistantChunk(text)
        case "done":
            break
        case "error":
            let message = payload["message"] as? String ?? "Something went wrong."
            statusText = friendlyErrorMessage(from: message)
        default:
            break
        }
    }

    private func appendAssistantChunk(_ text: String) {
        guard !text.isEmpty else { return }
        currentTurnStreamedAny = true
        if let assistantID = activeAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].content += text
        } else {
            let message = ChatMessage(role: .assistant, content: text)
            activeAssistantMessageID = message.id
            messages.append(message)
        }
        layoutDelegate?.quickAskNeedsLayout()
    }

    private func finishGeneration(exitCode: Int32) {
        let interruptedForSteer = pendingSteerPromptID != nil
        isGenerating = false
        activeProcess = nil

        if pendingResetAfterTermination {
            pendingResetAfterTermination = false
            let preserveInput = pendingResetPreserveInput
            pendingResetPreserveInput = false
            clearHistory(preserveInput: preserveInput, preserveStatus: true)
            requestFocus()
            return
        }

        if exitCode != 0 && statusText.isEmpty && !interruptedForSteer {
            let stderr = String(data: stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            statusText = friendlyErrorMessage(from: stderr)
        }

        if let assistantID = activeAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == assistantID }),
           messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: index)
        }

        activeAssistantMessageID = nil
        saveTranscript()
        layoutDelegate?.quickAskNeedsLayout()
        if let pendingSteerPromptID {
            self.pendingSteerPromptID = nil
            sendQueuedPrompt(id: pendingSteerPromptID)
            return
        }
        if !queuedPrompts.isEmpty {
            sendNextQueuedPrompt()
            return
        }
        requestFocus()
    }

    var progressText: String {
        guard isGenerating else { return "" }
        let modelName = models.first(where: { $0.id == selectedModelID })?.shortLabel ?? "Selected model"
        let phase = currentTurnStreamedAny ? "is still replying" : "is thinking"
        if pendingSteerPromptID != nil {
            return "\(modelName) \(phase). A queued prompt will steer in next."
        }
        if !queuedPrompts.isEmpty {
            return "\(modelName) \(phase). \(queuedPrompts.count) queued."
        }
        return "\(modelName) \(phase)…"
    }

    private func friendlyErrorMessage(from rawMessage: String?) -> String {
        let fallback = "The reply failed."
        guard let rawMessage else { return fallback }
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let lowercased = trimmed.lowercased()
        let modelLabel = models.first(where: { $0.id == selectedModelID })?.shortLabel ?? "This model"

        if lowercased.contains("env: node: no such file or directory") {
            return "\(modelLabel) could not start because the Gemini CLI could not find Node.js. Reopen Quick Ask or choose another model."
        }
        if lowercased.contains("not logged in") || lowercased.contains("auth login") {
            return "\(modelLabel) is not available from this Mac right now. Open Settings and finish the CLI login for that provider."
        }
        if lowercased.contains("quota") || lowercased.contains("capacity") || lowercased.contains("rate limit") {
            return "\(modelLabel) is temporarily out of quota or rate-limited. Try again shortly or switch models."
        }
        if lowercased.contains("requested entity was not found") || lowercased.contains("modelnotfounderror") {
            return "\(modelLabel) is not available in the installed CLI right now. Refresh providers or choose another model."
        }
        if lowercased.contains("could not start backend") {
            return "Quick Ask could not start the backend process for \(modelLabel)."
        }

        return trimmed
    }

    private func trimEmptyAssistantMessage() {
        if let assistantID = activeAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == assistantID }),
           messages[index].content.isEmpty {
            messages.remove(at: index)
        }
        activeAssistantMessageID = nil
    }

    private func resetSessionIfNeeded() {
        sessionID = UUID().uuidString
        sessionCreatedAt = QuickAskViewModel.timestampString(for: Date())
    }

    private func saveTranscript() {
        guard !messages.isEmpty else { return }
        let history = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let backendPath = self.backendPath
        let sessionID = self.sessionID
        let sessionCreatedAt = self.sessionCreatedAt
        let modelID = self.selectedModelID
        let processEnvironment = self.processEnvironmentProvider()

        saveQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3",
                backendPath,
                "save",
                "--session-id",
                sessionID,
                "--created-at",
                sessionCreatedAt,
                "--model-id",
                modelID,
            ]
            process.environment = processEnvironment

            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                if let data = try? JSONSerialization.data(withJSONObject: ["history": history]) {
                    stdin.fileHandleForWriting.write(data)
                }
                try? stdin.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch {
                return
            }
        }
    }

    private static func timestampString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isGenerating else { return }
                let idleFor = Date().timeIntervalSince(self.lastInteractionAt)
                if idleFor >= self.idleTimeout, !self.messages.isEmpty || !self.inputText.isEmpty {
                    self.clearHistory()
                }
            }
        }
        if let idleTimer {
            RunLoop.main.add(idleTimer, forMode: .common)
        }
    }
}

@MainActor
final class QuickAskHistoryViewModel: ObservableObject {
    @Published var sessions: [QuickAskHistorySession] = []
    @Published var isLoading = false
    @Published var statusText = ""
    @Published private(set) var deletingSessionIDs: Set<String> = []

    private let backendPath: String
    private let processEnvironmentProvider: () -> [String: String]

    init(backendPath: String, processEnvironmentProvider: @escaping () -> [String: String]) {
        self.backendPath = backendPath
        self.processEnvironmentProvider = processEnvironmentProvider
    }

    nonisolated private static func fetchHistory(
        backendPath: String,
        processEnvironment: [String: String]
    ) -> (payload: QuickAskHistoryEnvelope?, message: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", backendPath, "history", "--limit", "200"]
        process.environment = processEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            guard let payload = try? JSONDecoder().decode(QuickAskHistoryEnvelope.self, from: stdoutData), payload.type == "history" else {
                let message = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (nil, message?.isEmpty == false ? (message ?? "Could not load history.") : "Could not load history.")
            }

            return (payload, nil)
        } catch {
            return (nil, "Could not load history.")
        }
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        statusText = ""

        let backendPath = self.backendPath
        let processEnvironment = self.processEnvironmentProvider()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                QuickAskHistoryViewModel.fetchHistory(
                    backendPath: backendPath,
                    processEnvironment: processEnvironment
                )
            }.value
            guard let self else { return }
            if let payload = result.payload {
                self.sessions = payload.sessions
                self.isLoading = false
            } else {
                self.statusText = result.message ?? "Could not load history."
                self.isLoading = false
            }
        }
    }

    func deleteSession(_ sessionID: String) {
        guard !deletingSessionIDs.contains(sessionID) else { return }
        deletingSessionIDs.insert(sessionID)
        statusText = ""

        let backendPath = self.backendPath
        let processEnvironment = self.processEnvironmentProvider()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", backendPath, "delete", "--session-id", sessionID]
                process.environment = processEnvironment

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        return nil
                    }
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return message?.isEmpty == false ? message : "Could not delete history item."
                } catch {
                    return "Could not delete history item."
                }
            }.value

            guard let self else { return }
            self.deletingSessionIDs.remove(sessionID)
            if let result {
                self.statusText = result
            } else {
                self.sessions.removeAll { $0.sessionID == sessionID }
                self.reload()
            }
        }
    }
}

struct QuickAskHistoryRow: View {
    let session: QuickAskHistorySession
    let isDeleting: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    private var relativeSavedAtText: String {
        let raw = session.savedAt.isEmpty ? session.createdAt : session.savedAt
        guard let date = QuickAskHistoryRow.timestampFormatter.date(from: raw) else {
            return raw
        }
        return QuickAskHistoryRow.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.preview.isEmpty ? "Untitled session" : session.preview)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(QuickAskTheme.strongText)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 8) {
                            if !session.model.isEmpty {
                                Text(session.model)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(QuickAskTheme.mutedText)
                                    .lineLimit(1)
                            }
                            Text("\(session.messageCount) \(session.messageCount == 1 ? "message" : "messages")")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(QuickAskTheme.mutedText)
                                .lineLimit(1)
                            Text(relativeSavedAtText)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(QuickAskTheme.mutedText)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(QuickAskTheme.strongText)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(QuickAskTheme.strongText.opacity(0.82))
                            .frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isDeleting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(QuickAskTheme.historyBackground)

            Rectangle()
                .fill(QuickAskTheme.dividerColor)
                .frame(height: 1)
        }
    }
}

struct QuickAskHistoryView: View {
    @ObservedObject var viewModel: QuickAskHistoryViewModel
    let onSelectSession: (QuickAskHistorySession) -> Void
    let onClose: () -> Void

    private func commandButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(QuickAskTheme.strongText)
            .padding(.vertical, 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Ask History")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(QuickAskTheme.strongText)
                    Text("Encrypted saved sessions")
                        .font(.system(size: 11))
                        .foregroundStyle(QuickAskTheme.mutedText)
                }
                Spacer()
                commandButton("Refresh") {
                    viewModel.reload()
                }
                Rectangle()
                    .fill(QuickAskTheme.dividerColor)
                    .frame(width: 1, height: 18)
                commandButton("Close") {
                    onClose()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(QuickAskTheme.inputBackground)

            Rectangle()
                .fill(QuickAskTheme.dividerColor)
                .frame(height: 1)

            Group {
                if viewModel.sessions.isEmpty {
                    VStack(spacing: 10) {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(QuickAskTheme.strongText)
                        }
                        Text(viewModel.statusText.isEmpty ? "No Quick Ask sessions yet." : viewModel.statusText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(QuickAskTheme.mutedText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(QuickAskTheme.historyBackground)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.sessions) { session in
                                QuickAskHistoryRow(
                                    session: session,
                                    isDeleting: viewModel.deletingSessionIDs.contains(session.sessionID),
                                    onSelect: {
                                        onSelectSession(session)
                                    },
                                    onDelete: {
                                        viewModel.deleteSession(session.sessionID)
                                    }
                                )
                            }
                        }
                    }
                    .background(QuickAskTheme.historyBackground)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(QuickAskTheme.frameBackground)
        .onAppear {
            if viewModel.sessions.isEmpty {
                viewModel.reload()
            }
        }
    }
}

struct QuickAskSettingsView: View {
    @ObservedObject var settings: QuickAskAppSettings
    let onChooseArchiveDirectory: () -> Void
    let onClearArchiveDirectory: () -> Void
    let onRefreshProviders: () -> Void
    let onLaunchProviderSetup: (String) -> Void
    let onOpenShortcuts: () -> Void
    let onLayoutChange: () -> Void
    let onContinue: () -> Void
    let onClose: () -> Void

    private func commandButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(QuickAskTheme.strongText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Rectangle()
                    .fill(Color.white.opacity(0.16))
            )
            .overlay(
                Rectangle()
                    .stroke(QuickAskTheme.dividerColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.requiresInitialSetup ? "Quick Ask Setup" : "Quick Ask Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(QuickAskTheme.strongText)
                    Text("Reuse CLI logins only. No API keys. Encrypted history is safe to keep in cloud folders you do not trust with plaintext.")
                        .font(.system(size: 11))
                        .foregroundStyle(QuickAskTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                commandButton("Keyboard Shortcuts") {
                    onOpenShortcuts()
                }
                if settings.requiresInitialSetup {
                    commandButton("Continue") {
                        onContinue()
                    }
                    .disabled(!settings.canContinuePastSetup)
                    .opacity(settings.canContinuePastSetup ? 1 : 0.42)
                } else {
                    commandButton("Close") {
                        onClose()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(QuickAskTheme.inputBackground)

            Rectangle()
                .fill(QuickAskTheme.dividerColor)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("History")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QuickAskTheme.strongText)
                    Toggle(
                        isOn: Binding(
                            get: { settings.historyEnabled },
                            set: { settings.setHistoryEnabled($0) }
                        )
                    ) {
                        Text("Save encrypted history")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(QuickAskTheme.strongText)
                    }
                    .toggleStyle(.checkbox)

                    Text(
                        settings.historyEnabled
                        ? "Chats are encrypted before they are written to disk. Quick Ask stores the transcript key in your macOS Keychain and uses it before writing history. If that key is unavailable, Quick Ask should not write chat logs."
                        : "History is off. Quick Ask will not save transcripts."
                    )
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(QuickAskTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.historyEnabled {
                        Text(settings.storageDetail.isEmpty ? "Preparing Keychain-backed encryption…" : settings.storageDetail)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(settings.keychainReady ? QuickAskTheme.mutedText : QuickAskTheme.strongText.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if settings.historyEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Archive Folder")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(QuickAskTheme.strongText)
                        Text(settings.archiveDirectoryDetail)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(QuickAskTheme.mutedText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(settings.archiveDirectorySummary == "Default" ? "Using the default Quick Ask archive folder." : "Using a custom Quick Ask archive folder.")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(QuickAskTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            commandButton("Choose Folder…") {
                                onChooseArchiveDirectory()
                            }
                            if settings.customArchiveDirectory != nil {
                                commandButton("Clear") {
                                    onClearArchiveDirectory()
                                }
                            }
                        }

                        Text(settings.archiveFolderSelectionHint())
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(QuickAskTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Rectangle()
                    .fill(QuickAskTheme.dividerColor)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CLI Providers")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(QuickAskTheme.strongText)
                            Text("Quick Ask reuses whatever Claude, Codex/ChatGPT, Gemini, and Ollama access already exists on this Mac. Provider setup here is optional.")
                                .font(.system(size: 11))
                                .foregroundStyle(QuickAskTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        commandButton(settings.isRefreshingProviders ? "Refreshing…" : "Refresh") {
                            onRefreshProviders()
                        }
                        .disabled(settings.isRefreshingProviders)
                        .opacity(settings.isRefreshingProviders ? 0.42 : 1)
                    }

                    if !settings.providerStatusMessage.isEmpty {
                        Text(settings.providerStatusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(QuickAskTheme.mutedText)
                    }

                    ForEach(settings.providerStatuses) { provider in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .center, spacing: 8) {
                                Text(provider.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(QuickAskTheme.strongText)
                                Text(provider.isReady ? "ready" : "needs setup")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(provider.isReady ? QuickAskTheme.strongText.opacity(0.82) : QuickAskTheme.mutedText)
                                Spacer()
                                if provider.setupCommand != nil {
                                    commandButton(provider.isReady ? "Open CLI" : "Set Up…") {
                                        onLaunchProviderSetup(provider.id)
                                    }
                                }
                            }

                            Text(provider.detail)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(QuickAskTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if provider.id != settings.providerStatuses.last?.id {
                            Rectangle()
                                .fill(QuickAskTheme.dividerColor)
                                .frame(height: 1)
                        }
                    }
                }

                Rectangle()
                    .fill(QuickAskTheme.dividerColor)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Visible Models")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QuickAskTheme.strongText)
                    Text("Only enabled and currently available models appear in the picker. Refresh above to rescan Claude, Codex/ChatGPT, Gemini, and Ollama.")
                        .font(.system(size: 11))
                        .foregroundStyle(QuickAskTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Switching models only changes the next turn. A reply already in flight keeps using its current model, and the existing conversation history carries forward.")
                        .font(.system(size: 11))
                        .foregroundStyle(QuickAskTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.availableModels.isEmpty {
                        Text("No models are currently available.")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(QuickAskTheme.mutedText)
                    } else {
                        ForEach(settings.availableModels) { model in
                            Toggle(
                                isOn: Binding(
                                    get: { settings.isModelVisible(model.id) },
                                    set: { settings.setModelVisible(model.id, visible: $0) }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.shortLabel)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(QuickAskTheme.strongText)
                                    Text(model.provider == "ollama" ? "Local model" : "\(model.provider.capitalized) via CLI login")
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundStyle(QuickAskTheme.mutedText)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(QuickAskTheme.historyBackground)
        }
        .frame(minWidth: 560, minHeight: 320)
        .background(QuickAskTheme.frameBackground)
        .onAppear(perform: onLayoutChange)
        .onChange(of: settings.historyEnabled) { _, _ in onLayoutChange() }
        .onChange(of: settings.customArchiveDirectoryPath) { _, _ in onLayoutChange() }
        .onChange(of: settings.providerStatuses) { _, _ in onLayoutChange() }
        .onChange(of: settings.providerStatusMessage) { _, _ in onLayoutChange() }
        .onChange(of: settings.availableModels) { _, _ in onLayoutChange() }
        .onChange(of: settings.keychainReady) { _, _ in onLayoutChange() }
        .onChange(of: settings.storageDetail) { _, _ in onLayoutChange() }
    }
}

private struct KeyboardShortcutItem: Identifiable {
    let id = UUID()
    let keys: String
    let description: String
}

private let quickAskKeyboardShortcuts: [KeyboardShortcutItem] = [
    KeyboardShortcutItem(keys: "Cmd+\\", description: "Show or hide Quick Ask"),
    KeyboardShortcutItem(keys: "Cmd+Shift+\\", description: "Open or close history"),
    KeyboardShortcutItem(keys: "Cmd+,", description: "Open settings"),
    KeyboardShortcutItem(keys: "Cmd+N", description: "Start a fresh chat"),
    KeyboardShortcutItem(keys: "Enter", description: "Send the current prompt"),
    KeyboardShortcutItem(keys: "Cmd+Enter", description: "Steer the current draft ahead of the queue"),
]

struct QuickAskKeyboardShortcutsView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(QuickAskTheme.strongText)
                    Text("Quick Ask hotkeys and panel controls")
                        .font(.system(size: 11))
                        .foregroundStyle(QuickAskTheme.mutedText)
                }
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QuickAskTheme.strongText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Rectangle().fill(Color.white.opacity(0.16)))
                    .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(QuickAskTheme.inputBackground)

            Rectangle()
                .fill(QuickAskTheme.dividerColor)
                .frame(height: 1)

            VStack(spacing: 0) {
                ForEach(Array(quickAskKeyboardShortcuts.enumerated()), id: \.offset) { index, shortcut in
                    HStack(alignment: .top, spacing: 12) {
                        Text(shortcut.keys)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(QuickAskTheme.strongText)
                            .frame(width: 112, alignment: .leading)
                        Text(shortcut.description)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(QuickAskTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if index != quickAskKeyboardShortcuts.count - 1 {
                        Rectangle()
                            .fill(QuickAskTheme.dividerColor)
                            .frame(height: 1)
                    }
                }
            }
            .background(QuickAskTheme.historyBackground)
        }
        .frame(minWidth: 420, minHeight: 260)
        .background(QuickAskTheme.frameBackground)
    }
}

final class QuickAskPanel: NSPanel {
    var onNewChat: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           flags == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "n" {
            onNewChat?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class HotKeyManager {
    private enum Action: UInt32 {
        case togglePanel = 1
        case showHistory = 2
    }

    private final class Registration {
        let action: Action
        let hotKeyID: EventHotKeyID
        let keyCode: UInt32
        let modifiers: UInt32
        var hotKeyRef: EventHotKeyRef?

        init(action: Action, hotKeyID: EventHotKeyID, keyCode: UInt32, modifiers: UInt32, hotKeyRef: EventHotKeyRef?) {
            self.action = action
            self.hotKeyID = hotKeyID
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.hotKeyRef = hotKeyRef
        }
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private let toggleCallback: () -> Void
    private let historyCallback: () -> Void

    init(toggleCallback: @escaping () -> Void, historyCallback: @escaping () -> Void) {
        self.toggleCallback = toggleCallback
        self.historyCallback = historyCallback
    }

    func install() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, let registration = manager.registrations[hotKeyID.id] else {
                return noErr
            }

            DispatchQueue.main.async {
                switch registration.action {
                case .togglePanel:
                    manager.toggleCallback()
                case .showHistory:
                    manager.historyCallback()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )

        register(action: .togglePanel, keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey))
        register(action: .showHistory, keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey | shiftKey))
    }

    private func register(action: Action, keyCode: UInt32, modifiers: UInt32) {
        let id = action.rawValue
        let hotKeyID = EventHotKeyID(signature: OSType(0x5141534B), id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { return }
        registrations[id] = Registration(action: action, hotKeyID: hotKeyID, keyCode: keyCode, modifiers: modifiers, hotKeyRef: hotKeyRef)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var isHovering = false
    @State private var justCopied = false

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return Color.white.opacity(0.26)
        case .assistant:
            return Color.white.opacity(0.14)
        }
    }

    private var textColor: Color {
        QuickAskTheme.strongText
    }

    private var canCopy: Bool {
        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func copyMessage() {
        guard canCopy else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            justCopied = false
        }
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            MessageContentView(text: message.content.isEmpty ? "…" : message.content)
                .foregroundStyle(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .padding(.trailing, canCopy ? 24 : 10)
                .frame(maxWidth: 360, alignment: .leading)
                .background(
                    Rectangle()
                        .fill(bubbleColor)
                )
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if canCopy {
                        Button(action: copyMessage) {
                            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(QuickAskTheme.strongText.opacity(0.78))
                                .frame(width: 18, height: 18)
                                .background(Rectangle().fill(Color.white.opacity(0.18)))
                                .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovering || justCopied ? 1 : 0)
                        .padding(5)
                    }
                }
                .onHover { hovering in
                    isHovering = hovering
                }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
    }
}

private enum MessageMarkdownBlock {
    case text(String)
    case table(header: [String], rows: [[String]])
}

private struct MessageContentView: View {
    let text: String

    private var blocks: [MessageMarkdownBlock] {
        parseMarkdownBlocks(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    Text(markdownAttributedString(from: value))
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let header, let rows):
                    MessageMarkdownTableView(header: header, rows: rows)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageMarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { index in
                        Text(markdownAttributedString(from: cellText(header, index: index)))
                            .font(.system(size: 12, weight: .semibold, design: .default))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }

                Rectangle()
                    .fill(QuickAskTheme.dividerColor)
                    .frame(height: 1)
                    .gridCellColumns(columnCount)

                ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { index in
                            Text(markdownAttributedString(from: cellText(row, index: index)))
                                .font(.system(size: 12, weight: .regular, design: .default))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                    if offset != rows.count - 1 {
                        Rectangle()
                            .fill(QuickAskTheme.dividerColor.opacity(0.7))
                            .frame(height: 1)
                            .gridCellColumns(columnCount)
                    }
                }
            }
        }
        .background(Color.white.opacity(0.08))
        .overlay(Rectangle().stroke(Color.black.opacity(0.14), lineWidth: 1))
    }

    private func cellText(_ row: [String], index: Int) -> String {
        guard index < row.count else { return "" }
        return row[index]
    }
}

private func markdownAttributedString(from text: String) -> AttributedString {
    let normalizedText = normalizeMarkdownInput(text)
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var attributed = (try? AttributedString(markdown: normalizedText, options: options)) ?? AttributedString(normalizedText)
    applyDetectedLinks(to: &attributed, source: normalizedText)
    return attributed
}

private func normalizeMarkdownInput(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\s+\((https?://[^\s)]+)\)"#) else {
        return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[$1]($2)")
}

private func applyDetectedLinks(to attributed: inout AttributedString, source: String) {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
        return
    }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    for match in detector.matches(in: source, options: [], range: range) {
        guard let url = match.url,
              let textRange = Range(match.range, in: source),
              let lower = AttributedString.Index(textRange.lowerBound, within: attributed),
              let upper = AttributedString.Index(textRange.upperBound, within: attributed) else {
            continue
        }
        attributed[lower..<upper].link = url
    }
}

private func parseMarkdownBlocks(_ text: String) -> [MessageMarkdownBlock] {
    let lines = text.components(separatedBy: "\n")
    var blocks: [MessageMarkdownBlock] = []
    var textBuffer: [String] = []
    var index = 0

    func flushTextBuffer() {
        let joined = textBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            blocks.append(.text(joined))
        }
        textBuffer.removeAll(keepingCapacity: true)
    }

    while index < lines.count {
        if let table = parseMarkdownTable(lines: lines, startIndex: index) {
            flushTextBuffer()
            blocks.append(.table(header: table.header, rows: table.rows))
            index = table.nextIndex
            continue
        }

        textBuffer.append(lines[index])
        index += 1
    }

    flushTextBuffer()
    return blocks.isEmpty ? [.text(text)] : blocks
}

private func parseMarkdownTable(lines: [String], startIndex: Int) -> (header: [String], rows: [[String]], nextIndex: Int)? {
    guard startIndex + 1 < lines.count else { return nil }
    let headerLine = lines[startIndex]
    let separatorLine = lines[startIndex + 1]
    guard markdownRowLooksLikeTable(headerLine), markdownSeparatorLooksLikeTable(separatorLine) else {
        return nil
    }

    let header = parseMarkdownTableRow(headerLine)
    guard !header.isEmpty else { return nil }

    var rows: [[String]] = []
    var index = startIndex + 2
    while index < lines.count {
        let line = lines[index]
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            break
        }
        guard markdownRowLooksLikeTable(line) else { break }
        rows.append(parseMarkdownTableRow(line))
        index += 1
    }

    return (header: header, rows: rows, nextIndex: index)
}

private func markdownRowLooksLikeTable(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.contains("|") && parseMarkdownTableRow(trimmed).count >= 2
}

private func markdownSeparatorLooksLikeTable(_ line: String) -> Bool {
    let cells = parseMarkdownTableRow(line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { character in
            character == "-" || character == ":" || character == " "
        } && trimmed.contains("-")
    }
}

private func parseMarkdownTableRow(_ line: String) -> [String] {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") {
        trimmed.removeFirst()
    }
    if trimmed.hasSuffix("|") {
        trimmed.removeLast()
    }
    return trimmed
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

struct QueuedPromptRow: View {
    let prompt: QueuedPrompt
    let onSteer: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(prompt.content)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(QuickAskTheme.strongText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onSteer) {
                Text("Steer")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(QuickAskTheme.strongText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Rectangle().fill(Color.white.opacity(0.16)))
                    .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(QuickAskTheme.strongText.opacity(0.82))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Rectangle().fill(Color.white.opacity(0.12)))
        .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
    }
}

struct SuggestionFreeInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: UUID
    let onSubmit: () -> Void
    let onSteerSubmit: () -> Void
    let onTextChange: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SuggestionFreeInputField
        var lastFocusToken: UUID?

        init(parent: SuggestionFreeInputField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
            parent.onTextChange()
            configureEditor(for: field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            configureEditor(for: field)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if flags.contains(.command) {
                    parent.onSteerSubmit()
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>
        ) -> [String] {
            index.pointee = -1
            return []
        }

        func configureEditor(for field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.smartInsertDeleteEnabled = false
            editor.enabledTextCheckingTypes = 0
        }

        func requestFocus(for field: NSTextField, token: UUID) {
            guard lastFocusToken != token else { return }
            lastFocusToken = token
            QuickAskLog.shared.write("input focus requested")
            focus(field, attemptsRemaining: 6)
        }

        private func focus(_ field: NSTextField, attemptsRemaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                guard let window = field.window else {
                    QuickAskLog.shared.write("input focus retry waiting for window attempts=\(attemptsRemaining)")
                    if attemptsRemaining > 0 {
                        self.focus(field, attemptsRemaining: attemptsRemaining - 1)
                    }
                    return
                }
                guard window.isKeyWindow else {
                    QuickAskLog.shared.write("input focus skipped because window is not key attempts=\(attemptsRemaining)")
                    if attemptsRemaining > 0 {
                        self.focus(field, attemptsRemaining: attemptsRemaining - 1)
                    }
                    return
                }
                let didFocus = window.makeFirstResponder(field)
                self.configureEditor(for: field)
                if let editor = field.currentEditor() as? NSTextView {
                    editor.setSelectedRange(NSRange(location: field.stringValue.count, length: 0))
                }
                QuickAskLog.shared.write("input focus result didFocus=\(didFocus)")
                if !didFocus, attemptsRemaining > 0 {
                    self.focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = SuggestionFreeTextField(string: text)
        field.delegate = context.coordinator
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.16, alpha: 0.56),
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            ]
        )
        field.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        field.textColor = NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.16, alpha: 1)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.isAutomaticTextCompletionEnabled = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.requestFocus(for: field, token: focusToken)
    }
}

final class SuggestionFreeTextField: NSTextField {
    override func complete(_ sender: Any?) {}
}

struct QuickAskView: View {
    @ObservedObject var viewModel: QuickAskViewModel
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(QuickAskTheme.strongText)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Rectangle().fill(QuickAskTheme.panelAccent))
            .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: viewModel.historyAreaHeight >= 450) {
                        VStack(spacing: 8) {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(10)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: HistoryHeightKey.self, value: proxy.size.height)
                            }
                        )
                    }
                    .frame(height: viewModel.historyAreaHeight)
                    .background(QuickAskTheme.historyBackground)
                    .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
                    .onPreferenceChange(HistoryHeightKey.self) { value in
                        viewModel.setHistoryAreaHeight(value)
                    }
                    .onAppear {
                        scrollToBottom(using: proxy)
                    }
                    .onChange(of: viewModel.messages) { _, _ in
                        scrollToBottom(using: proxy)
                    }
                }
            }

            if !viewModel.queuedPrompts.isEmpty {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("\(viewModel.queuedPrompts.count) queued")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(QuickAskTheme.mutedText)
                        Spacer()
                    }

                    ForEach(viewModel.queuedPrompts) { prompt in
                        QueuedPromptRow(
                            prompt: prompt,
                            onSteer: {
                                viewModel.steerQueuedPrompt(id: prompt.id)
                            },
                            onCancel: {
                                viewModel.cancelQueuedPrompt(id: prompt.id)
                            }
                        )
                    }
                }
                .padding(10)
                .background(QuickAskTheme.historyBackground)
                .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(viewModel.models) { model in
                            Button {
                                viewModel.selectModel(model.id)
                            } label: {
                                Text(model.shortLabel)
                            }
                        }
                        Divider()
                        Button {
                            onOpenHistory()
                        } label: {
                            Text("History")
                        }
                        Button {
                            onOpenSettings()
                        } label: {
                            Text("Settings…")
                        }
                    } label: {
                        Text(currentModelShortLabel)
                            .lineLimit(1)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Rectangle()
                                .fill(QuickAskTheme.panelAccent)
                        )
                        .overlay(
                            Rectangle()
                                .stroke(QuickAskTheme.dividerColor, lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundColor(.black)
                    .tint(.black)
                    .fixedSize()

                    Rectangle()
                        .fill(QuickAskTheme.dividerColor)
                        .frame(width: 1, height: 24)

                    SuggestionFreeInputField(
                        text: $viewModel.inputText,
                        placeholder: "Ask quickly…",
                        focusToken: viewModel.focusToken,
                        onSubmit: {
                            viewModel.send()
                        },
                        onSteerSubmit: {
                            viewModel.steerCurrentInput()
                        },
                        onTextChange: {
                            viewModel.touch()
                        }
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(QuickAskTheme.inputBackground)
                .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: InputBarFrameKey.self, value: proxy.frame(in: .global))
                    }
                )

                if !viewModel.statusText.isEmpty {
                    HStack {
                        Text(viewModel.statusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(QuickAskTheme.mutedText)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(QuickAskTheme.inputBackground.opacity(0.96))
                    .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
                } else if !viewModel.progressText.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(QuickAskTheme.strongText)
                        Text(viewModel.progressText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(QuickAskTheme.mutedText)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(QuickAskTheme.inputBackground.opacity(0.96))
                    .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
                }
            }
        }
        .frame(width: 560)
        .background(QuickAskTheme.frameBackground)
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
        .onPreferenceChange(InputBarFrameKey.self) { value in
            viewModel.setInputBarFrame(value)
        }
    }

    private var currentModelShortLabel: String {
        viewModel.models.first(where: { $0.id == viewModel.selectedModelID })?.shortLabel ?? "Loading…"
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard let last = viewModel.messages.last else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

@MainActor
final class QuickAskUITestHarness {
    private weak var appDelegate: AppDelegate?
    private let stateURL: URL
    private let commandURL: URL
    private var timer: Timer?
    private(set) var handledCommandID = 0

    init?(appDelegate: AppDelegate) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QUICK_ASK_UI_TEST_MODE"] == "1",
              let statePath = environment["QUICK_ASK_UI_TEST_STATE_PATH"],
              let commandPath = environment["QUICK_ASK_UI_TEST_COMMAND_PATH"] else {
            return nil
        }

        self.appDelegate = appDelegate
        self.stateURL = URL(fileURLWithPath: statePath)
        self.commandURL = URL(fileURLWithPath: commandPath)
        try? FileManager.default.createDirectory(at: self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.commandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        start()
    }

    deinit {
        timer?.invalidate()
    }

    func writeState() {
        guard let appDelegate else { return }
        let state = appDelegate.uiTestState(handledCommandID: handledCommandID)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            return
        }
    }

    private func start() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handlePendingCommand()
                self.writeState()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        writeState()
    }

    private func handlePendingCommand() {
        guard let data = try? Data(contentsOf: commandURL),
              !data.isEmpty,
              let command = try? JSONDecoder().decode(QuickAskUITestCommand.self, from: data),
              command.id > handledCommandID else {
            return
        }

        appDelegate?.handleUITestCommand(command)
        handledCommandID = command.id
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, QuickAskLayoutDelegate {
    private var panel: QuickAskPanel!
    private var hostingView: MovableHostingView<QuickAskView>!
    private var historyWindow: NSWindow!
    private var historyHostingView: NSHostingView<QuickAskHistoryView>!
    private var settingsWindow: NSWindow!
    private var settingsHostingView: NSHostingView<QuickAskSettingsView>!
    private var shortcutsWindow: NSWindow!
    private var shortcutsHostingView: NSHostingView<QuickAskKeyboardShortcutsView>!
    private var historyViewModel: QuickAskHistoryViewModel!
    private var hotKeyManager: HotKeyManager?
    private var viewModel: QuickAskViewModel!
    private var settings: QuickAskAppSettings!
    private var localKeyMonitor: Any?
    private var panelBottomY: CGFloat?
    private var isProgrammaticPanelMove = false
    private var uiTestHarness: QuickAskUITestHarness?
    private var backendPath = ""
    private let defaults = quickAskUserDefaults()
    private let panelOriginXKey = "QuickAskPanelOriginX"
    private let panelBottomYKey = "QuickAskPanelBottomY"
    private let uiTestMode = ProcessInfo.processInfo.environment["QUICK_ASK_UI_TEST_MODE"] == "1"
    private let uiTestSingletonMode = ProcessInfo.processInfo.environment["QUICK_ASK_UI_TEST_ENABLE_SINGLETON"] == "1"
    private let uiTestForceSetupGate = ProcessInfo.processInfo.environment["QUICK_ASK_UI_TEST_FORCE_SETUP_GATE"] == "1"
    private var singletonLockFileDescriptor: Int32 = -1
    private var frontmostAppName = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        QuickAskLog.shared.write("applicationDidFinishLaunching uiTestMode=\(uiTestMode)")
        frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleFrontmostApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if !uiTestMode || uiTestSingletonMode {
            guard acquireSingletonLock() else {
                QuickAskLog.shared.write("singleton lock unavailable, exiting duplicate instance")
                NSApp.terminate(nil)
                return
            }
        }

        backendPath = resolveBackendPath()
        settings = QuickAskAppSettings(defaults: defaults)
        viewModel = QuickAskViewModel(
            backendPath: backendPath,
            processEnvironmentProvider: { [weak self] in
                self?.settings.processEnvironment() ?? ProcessInfo.processInfo.environment
            },
            visibleModelsProvider: { [weak self] models in
                self?.settings.visibleModels(from: models) ?? models
            },
            availableModelsObserver: { [weak self] models in
                self?.settings.setAvailableModels(models)
            },
            defaults: defaults
        )
        viewModel.layoutDelegate = self
        historyViewModel = QuickAskHistoryViewModel(
            backendPath: backendPath,
            processEnvironmentProvider: { [weak self] in
                self?.settings.processEnvironment() ?? ProcessInfo.processInfo.environment
            }
        )

        hostingView = MovableHostingView(
            rootView: QuickAskView(
                viewModel: viewModel,
                onOpenHistory: { [weak self] in
                    self?.toggleHistoryWindow()
                },
                onOpenSettings: { [weak self] in
                    self?.showSettingsWindow()
                }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 70)

        historyHostingView = NSHostingView(
            rootView: QuickAskHistoryView(
                viewModel: historyViewModel,
                onSelectSession: { [weak self] session in
                    self?.restoreSession(session)
                },
                onClose: { [weak self] in
                    self?.hideHistoryWindow()
                }
            )
        )

        settingsHostingView = NSHostingView(
            rootView: QuickAskSettingsView(
                settings: settings,
                onChooseArchiveDirectory: { [weak self] in
                    self?.chooseArchiveDirectory()
                },
                onClearArchiveDirectory: { [weak self] in
                    self?.clearArchiveDirectory()
                },
                onRefreshProviders: { [weak self] in
                    self?.refreshSettingsStatus()
                },
                onLaunchProviderSetup: { [weak self] providerID in
                    self?.launchProviderSetup(for: providerID)
                },
                onOpenShortcuts: { [weak self] in
                    self?.showShortcutsWindow()
                },
                onLayoutChange: { [weak self] in
                    self?.resizeSettingsWindowToFitContent(centerOnScreen: false)
                },
                onContinue: { [weak self] in
                    self?.completeInitialSetup()
                },
                onClose: { [weak self] in
                    self?.hideSettingsWindow()
                }
            )
        )

        shortcutsHostingView = NSHostingView(
            rootView: QuickAskKeyboardShortcutsView(
                onClose: { [weak self] in
                    self?.hideShortcutsWindow()
                }
            )
        )

        panel = QuickAskPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 70),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedRed: 0.55, green: 0.79, blue: 0.77, alpha: 1)
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.orderOut(nil)
        panel.onNewChat = { [weak self] in
            self?.startNewChat()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )

        historyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        historyWindow.title = "Quick Ask History"
        historyWindow.isReleasedWhenClosed = false
        historyWindow.isOpaque = true
        historyWindow.backgroundColor = NSColor(calibratedRed: 0.55, green: 0.79, blue: 0.77, alpha: 1)
        historyWindow.level = .floating
        historyWindow.hasShadow = true
        historyWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        historyWindow.hidesOnDeactivate = false
        historyWindow.isMovableByWindowBackground = false
        historyWindow.contentView = historyHostingView
        historyWindow.setFrameAutosaveName("QuickAskHistoryWindowFrame")
        if !historyWindow.setFrameUsingName("QuickAskHistoryWindowFrame") {
            historyWindow.setFrame(NSRect(x: 0, y: 0, width: 520, height: 420), display: false)
        }
        historyWindow.orderOut(nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHistoryWindowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: historyWindow
        )

        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Quick Ask Settings"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.isOpaque = true
        settingsWindow.backgroundColor = NSColor(calibratedRed: 0.55, green: 0.79, blue: 0.77, alpha: 1)
        settingsWindow.level = .floating
        settingsWindow.hasShadow = true
        settingsWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        settingsWindow.hidesOnDeactivate = false
        settingsWindow.contentView = settingsHostingView
        settingsWindow.setFrameAutosaveName("QuickAskSettingsWindowFrame")
        if !settingsWindow.setFrameUsingName("QuickAskSettingsWindowFrame") {
            settingsWindow.setFrame(NSRect(x: 0, y: 0, width: 560, height: 360), display: false)
        }
        settingsWindow.orderOut(nil)

        shortcutsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        shortcutsWindow.title = "Keyboard Shortcuts"
        shortcutsWindow.isReleasedWhenClosed = false
        shortcutsWindow.isOpaque = true
        shortcutsWindow.backgroundColor = NSColor(calibratedRed: 0.55, green: 0.79, blue: 0.77, alpha: 1)
        shortcutsWindow.level = .floating
        shortcutsWindow.hasShadow = true
        shortcutsWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        shortcutsWindow.hidesOnDeactivate = false
        shortcutsWindow.contentView = shortcutsHostingView
        shortcutsWindow.orderOut(nil)

        hotKeyManager = HotKeyManager { [weak self] in
            self?.togglePanel()
        } historyCallback: { [weak self] in
            self?.toggleHistoryWindow()
        }
        hotKeyManager?.install()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "w" {
                if self.shortcutsWindow.isVisible, self.shortcutsWindow.isKeyWindow {
                    self.hideShortcutsWindow()
                    return nil
                }
                if self.settingsWindow.isVisible, self.settingsWindow.isKeyWindow {
                    self.hideSettingsWindow()
                    return nil
                }
                if self.historyWindow.isVisible, self.historyWindow.isKeyWindow {
                    self.hideHistoryWindow()
                    return nil
                }
                if self.panel.isVisible, self.panel.isKeyWindow {
                    self.togglePanel()
                    return nil
                }
            }
            if self.panel.isVisible,
               self.panel.isKeyWindow,
               flags == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "n" {
                self.startNewChat()
                return nil
            }
            if self.panel.isVisible,
               self.panel.isKeyWindow,
               flags == [.command],
               (event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)) {
                self.viewModel.steerCurrentInput()
                return nil
            }
            if flags == [.command],
               event.charactersIgnoringModifiers == "," {
                self.toggleSettingsWindow()
                return nil
            }
            return event
        }
        viewModel.loadModels()
        historyViewModel.reload()
        refreshSettingsStatus()
        quickAskNeedsLayout()
        uiTestHarness = QuickAskUITestHarness(appDelegate: self)
        uiTestHarness?.writeState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        QuickAskLog.shared.write("applicationWillTerminate")
        if singletonLockFileDescriptor >= 0 {
            flock(singletonLockFileDescriptor, LOCK_UN)
            close(singletonLockFileDescriptor)
            singletonLockFileDescriptor = -1
        }
    }

    func quickAskNeedsLayout() {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let targetWidth: CGFloat = 560
        let targetHeight = round(max(44, min(fitting.height, 560)))

        var frame = panel.frame
        isProgrammaticPanelMove = true
        if !panel.isVisible {
            if uiTestMode {
                frame = NSRect(x: 700, y: 90, width: targetWidth, height: targetHeight)
            } else if let savedOriginX = defaults.object(forKey: panelOriginXKey) as? Double,
               let savedBottomY = defaults.object(forKey: panelBottomYKey) as? Double {
                frame = NSRect(
                    x: round(savedOriginX),
                    y: round(savedBottomY),
                    width: targetWidth,
                    height: targetHeight
                )
            } else {
                frame = initialFrame(width: targetWidth, height: targetHeight)
            }
            let anchoredBottomY = round(frame.minY)
            frame.origin.y = anchoredBottomY
            frame.size.width = targetWidth
            frame.size.height = targetHeight
            panelBottomY = anchoredBottomY
        } else {
            let anchoredBottomY = round(panelBottomY ?? panel.frame.minY)
            frame.origin.y = anchoredBottomY
            frame.size.height = targetHeight
            frame.size.width = targetWidth
            panelBottomY = anchoredBottomY
        }
        panel.setFrame(frame, display: true)
        if let anchoredBottomY = panelBottomY {
            let targetOrigin = NSPoint(x: round(frame.origin.x), y: anchoredBottomY)
            if abs(panel.frame.origin.x - targetOrigin.x) > 0.5 || abs(panel.frame.minY - targetOrigin.y) > 0.5 {
                panel.setFrameOrigin(targetOrigin)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isProgrammaticPanelMove = false
        }
        uiTestHarness?.writeState()
    }

    private func showSettingsWindow(activate: Bool = true) {
        refreshSettingsStatus()
        resizeSettingsWindowToFitContent(centerOnScreen: true)
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        uiTestHarness?.writeState()
    }

    private func hideSettingsWindow() {
        hideShortcutsWindow()
        settingsWindow.orderOut(nil)
        uiTestHarness?.writeState()
    }

    private func toggleSettingsWindow() {
        if settingsWindow.isVisible {
            hideSettingsWindow()
        } else {
            showSettingsWindow()
        }
    }

    private func showShortcutsWindow() {
        shortcutsWindow.center()
        shortcutsWindow.makeKeyAndOrderFront(nil)
        shortcutsWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        uiTestHarness?.writeState()
    }

    private func hideShortcutsWindow() {
        shortcutsWindow.orderOut(nil)
        uiTestHarness?.writeState()
    }

    private func chooseArchiveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = "Choose Archive Folder"
        panel.directoryURL = settings.effectiveArchiveDirectory?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            settings.setCustomArchiveDirectory(url)
            viewModel.persistCurrentTranscript()
            refreshSettingsStatus()
            historyViewModel.reload()
        }
    }

    private func clearArchiveDirectory() {
        settings.clearCustomArchiveDirectory()
        viewModel.persistCurrentTranscript()
        refreshSettingsStatus()
        historyViewModel.reload()
    }

    private func refreshSettingsStatus() {
        settings.refreshProviderStatuses(backendPath: backendPath)
        settings.refreshStorageStatus(backendPath: backendPath, ensureKey: settings.historyEnabled)
        viewModel.loadModels()
        historyViewModel.reload()
    }

    private func completeInitialSetup() {
        guard settings.canContinuePastSetup else {
            showSettingsWindow()
            return
        }
        let shouldRevealPanel = settings.requiresInitialSetup && !panel.isVisible
        settings.markSetupCompleted()
        refreshSettingsStatus()
        hideSettingsWindow()
        if shouldRevealPanel {
            showPanel()
        }
    }

    private func shouldGateOnSetup() -> Bool {
        if uiTestMode && uiTestForceSetupGate {
            return true
        }
        return settings.requiresInitialSetup
    }

    private func launchProviderSetup(for providerID: String) {
        let command: String
        switch providerID {
        case "claude":
            command = "claude auth login --claudeai"
        case "codex":
            command = "codex login --device-auth"
        case "gemini":
            command = "gemini"
        default:
            return
        }
        openTerminal(command: command)
    }

    private func openTerminal(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            QuickAskLog.shared.write("failed to launch Terminal for provider setup: \(error.localizedDescription)")
        }
    }

    private func togglePanel() {
        if panel.isVisible {
            QuickAskLog.shared.write("togglePanel hiding panel")
            if historyWindow.isVisible {
                hideHistoryWindow()
            }
            if settingsWindow.isVisible {
                hideSettingsWindow()
            }
            if shortcutsWindow.isVisible {
                hideShortcutsWindow()
            }
            viewModel.panelHidden()
            panel.orderOut(nil)
            uiTestHarness?.writeState()
            return
        }

        guard !shouldGateOnSetup() else {
            showSettingsWindow()
            return
        }

        QuickAskLog.shared.write("togglePanel showing panel")
        quickAskNeedsLayout()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        quickAskNeedsLayout()
        viewModel.panelShown()
        settleVisiblePanel()
        uiTestHarness?.writeState()
    }

    private func showPanel() {
        QuickAskLog.shared.write("showPanel")
        guard !shouldGateOnSetup() else {
            showSettingsWindow()
            return
        }
        quickAskNeedsLayout()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        quickAskNeedsLayout()
        viewModel.panelShown()
        settleVisiblePanel()
        uiTestHarness?.writeState()
    }

    private func toggleHistoryWindow() {
        guard !shouldGateOnSetup() else {
            showSettingsWindow()
            return
        }
        guard settings.historyEnabled else {
            showSettingsWindow()
            return
        }
        if historyWindow.isVisible {
            QuickAskLog.shared.write("toggleHistoryWindow hiding history")
            hideHistoryWindow()
            return
        }

        QuickAskLog.shared.write("toggleHistoryWindow showing history")
        historyViewModel.reload()
        historyWindow.makeKeyAndOrderFront(nil)
        historyWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        uiTestHarness?.writeState()
    }

    private func hideHistoryWindow() {
        QuickAskLog.shared.write("hideHistoryWindow")
        historyWindow.saveFrame(usingName: "QuickAskHistoryWindowFrame")
        historyWindow.orderOut(nil)
        uiTestHarness?.writeState()
    }

    private func restoreSession(_ session: QuickAskHistorySession) {
        hideHistoryWindow()
        loadSession(session.sessionID)
    }

    func showSettingsFromAppMenu() {
        showSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startNewChat() {
        guard panel.isVisible else { return }
        viewModel.newChat()
        quickAskNeedsLayout()
    }

    private func settleVisiblePanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.quickAskNeedsLayout()
            self.uiTestHarness?.writeState()
        }
    }

    private func initialFrame(width: CGFloat, height: CGFloat) -> NSRect {
        let screen = currentScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = round(visible.midX - (width / 2))
        let y = round(visible.minY + 90)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func acquireSingletonLock() -> Bool {
        let supportRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quick Ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let lockPath = supportRoot.appendingPathComponent("instance.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            QuickAskLog.shared.write("singleton lock open failed, allowing launch")
            return true
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            QuickAskLog.shared.write("singleton lock already held")
            return false
        }
        singletonLockFileDescriptor = descriptor
        QuickAskLog.shared.write("singleton lock acquired")
        return true
    }

    private func currentScreen() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) ?? NSScreen.main
    }

    private func positionSettingsWindow() {
        guard let screen = currentScreen() else {
            settingsWindow.center()
            return
        }
        let visible = screen.visibleFrame
        let size = settingsWindow.frame.size
        let origin = NSPoint(
            x: round(visible.midX - (size.width / 2)),
            y: round(visible.midY - (size.height / 2))
        )
        settingsWindow.setFrameOrigin(origin)
    }

    private func resizeSettingsWindowToFitContent(centerOnScreen: Bool) {
        guard let settingsWindow, let settingsHostingView else { return }
        settingsHostingView.layoutSubtreeIfNeeded()

        let targetWidth: CGFloat = 560
        let minHeight: CGFloat = 320
        let visible = currentScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxHeight = max(minHeight, floor(visible.height))
        let fittingHeight = ceil(settingsHostingView.fittingSize.height)
        let targetHeight = max(minHeight, min(fittingHeight, maxHeight))

        let currentFrame = settingsWindow.frame
        let midX = centerOnScreen ? visible.midX : currentFrame.midX
        let midY = centerOnScreen ? visible.midY : currentFrame.midY

        var frame = NSRect(
            x: round(midX - (targetWidth / 2)),
            y: round(midY - (targetHeight / 2)),
            width: targetWidth,
            height: targetHeight
        )

        if frame.width > visible.width {
            frame.size.width = visible.width
            frame.origin.x = visible.minX
        } else {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        }

        if frame.height > visible.height {
            frame.size.height = visible.height
            frame.origin.y = visible.minY
        } else {
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }

        if !settingsWindow.isVisible {
            settingsWindow.setFrame(frame, display: false)
        } else if abs(settingsWindow.frame.width - frame.width) > 0.5 ||
                    abs(settingsWindow.frame.height - frame.height) > 0.5 ||
                    abs(settingsWindow.frame.origin.x - frame.origin.x) > 0.5 ||
                    abs(settingsWindow.frame.origin.y - frame.origin.y) > 0.5 {
            settingsWindow.setFrame(frame, display: true, animate: false)
        }
    }

    private func loadSession(_ sessionID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", resolveBackendPath(), "load", "--session-id", sessionID]
        process.environment = settings.processEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            guard let payload = try? JSONDecoder().decode(QuickAskLoadedEnvelope.self, from: stdoutData), payload.type == "session" else {
                let message = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.statusText = message?.isEmpty == false ? (message ?? "Could not restore session.") : "Could not restore session."
                return
            }

            viewModel.restoreSession(payload.session)
            showPanel()
        } catch {
            viewModel.statusText = "Could not restore session."
        }
    }

    private func resolveBackendPath() -> String {
        if let bundled = Bundle.main.path(forResource: "quick_ask_backend", ofType: "py") {
            return bundled
        }
        let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("quick_ask_backend.py")
            .path
        return candidate
    }

    @objc
    private func handleWindowDidMove(_ notification: Notification) {
        guard !isProgrammaticPanelMove else { return }
        panelBottomY = panel?.frame.minY
        defaults.set(panel?.frame.minX ?? 0, forKey: panelOriginXKey)
        defaults.set(panel?.frame.minY ?? 0, forKey: panelBottomYKey)
        uiTestHarness?.writeState()
    }

    @objc
    private func handleHistoryWindowDidMove(_ notification: Notification) {
        historyWindow?.saveFrame(usingName: "QuickAskHistoryWindowFrame")
        uiTestHarness?.writeState()
    }

    @objc
    private func handleFrontmostApplicationChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            frontmostAppName = app.localizedName ?? ""
        } else {
            frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        }
        uiTestHarness?.writeState()
    }

    fileprivate func uiTestState(handledCommandID: Int) -> QuickAskUITestState {
        let selectedModel: String
        if let viewModel {
            selectedModel = viewModel.models.first(where: { $0.id == viewModel.selectedModelID })?.shortLabel ?? ""
        } else {
            selectedModel = ""
        }
        let visibleModelIDs = viewModel?.models.map(\.id) ?? []
        let screenVisibleHeight = panel?.screen?.visibleFrame.height
            ?? settingsWindow?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 0

        return QuickAskUITestState(
            panelVisible: panel?.isVisible ?? false,
            historyWindowVisible: historyWindow?.isVisible ?? false,
            settingsWindowVisible: settingsWindow?.isVisible ?? false,
            shortcutsWindowVisible: shortcutsWindow?.isVisible ?? false,
            panelIsKeyWindow: panel?.isKeyWindow ?? false,
            panelFrame: CodableRect(panel?.frame ?? .zero),
            settingsFrame: CodableRect(settingsWindow?.frame ?? .zero),
            inputBarFrame: CodableRect(viewModel?.inputBarFrame ?? .zero),
            inputBarBottomInset: max(
                0,
                Double((panel?.frame.height ?? 0) - ((viewModel?.inputBarFrame.maxY ?? 0)))
            ),
            historyAreaHeight: Double(viewModel?.historyAreaHeight ?? 0),
            historySessionIDs: historyViewModel?.sessions.map(\.sessionID) ?? [],
            messageCount: viewModel?.messages.count ?? 0,
            queuedCount: viewModel?.queuedPrompts.count ?? 0,
            queuedPromptContents: viewModel?.queuedPrompts.map(\.content) ?? [],
            isGenerating: viewModel?.isGenerating ?? false,
            focusRequestCount: viewModel?.focusRequestCount ?? 0,
            frontmostAppName: frontmostAppName,
            selectedModel: selectedModel,
            visibleModelIDs: visibleModelIDs,
            inputText: viewModel?.inputText ?? "",
            setupRequired: settings?.requiresInitialSetup ?? false,
            historyEnabled: settings?.historyEnabled ?? true,
            screenVisibleHeight: Double(screenVisibleHeight),
            handledCommandID: handledCommandID
        )
    }

    fileprivate func handleUITestCommand(_ command: QuickAskUITestCommand) {
        switch command.action {
        case "show_panel":
            showPanel()
        case "hide_panel":
            if panel.isVisible {
                if historyWindow.isVisible {
                    hideHistoryWindow()
                }
                viewModel.panelHidden()
                panel.orderOut(nil)
            }
        case "set_input":
            viewModel.inputText = command.text ?? ""
            viewModel.touch()
            quickAskNeedsLayout()
        case "show_settings":
            showSettingsWindow()
        case "show_shortcuts":
            showShortcutsWindow()
        case "submit":
            viewModel.send()
        case "complete_generation":
            viewModel.completeTestGeneration(with: command.text ?? "")
        case "new_chat":
            startNewChat()
        case "complete_setup":
            completeInitialSetup()
        case "set_history_enabled":
            settings.setHistoryEnabled((command.text ?? "1") == "1")
            historyViewModel.reload()
        case "set_archive_dir":
            if let text = command.text, !text.isEmpty {
                settings.setCustomArchiveDirectory(URL(fileURLWithPath: text))
                historyViewModel.reload()
            }
        case "set_model_visible":
            if let text = command.text,
               let separator = text.lastIndex(of: "|") {
                let modelID = String(text[..<separator])
                let visible = String(text[text.index(after: separator)...]) != "0"
                settings.setModelVisible(modelID, visible: visible)
                viewModel.loadModels()
            }
        case "select_model":
            if let text = command.text, !text.isEmpty {
                viewModel.selectModel(text)
            }
        case "clear_archive_dir":
            clearArchiveDirectory()
        case "delete_history_session":
            if let text = command.text, !text.isEmpty {
                historyViewModel.deleteSession(text)
            }
        case "clear_queue":
            viewModel.clearQueuedPrompts()
        case "steer_queue_item":
            if let text = command.text,
               let prompt = viewModel.queuedPrompts.first(where: { $0.content == text }) {
                viewModel.steerQueuedPrompt(id: prompt.id)
            }
        case "cancel_queue_item":
            if let text = command.text,
               let prompt = viewModel.queuedPrompts.first(where: { $0.content == text }) {
                viewModel.cancelQueuedPrompt(id: prompt.id)
            }
        case "refresh_models":
            viewModel.loadModels()
        case "request_focus":
            viewModel.requestFocus()
        case "shortcut":
            switch command.shortcut {
            case "cmd_n":
                startNewChat()
            case "cmd_enter":
                viewModel.steerCurrentInput()
            case "cmd_comma":
                toggleSettingsWindow()
            case "cmd_w":
                if shortcutsWindow.isVisible {
                    hideShortcutsWindow()
                } else if settingsWindow.isVisible {
                    hideSettingsWindow()
                } else if historyWindow.isVisible {
                    hideHistoryWindow()
                } else if panel.isVisible {
                    togglePanel()
                }
            case "cmd_shift_backslash":
                toggleHistoryWindow()
            case "cmd_backslash":
                togglePanel()
            default:
                break
            }
        default:
            break
        }
        uiTestHarness?.writeState()
    }
}

final class MovableHostingView<Content: View>: NSHostingView<Content> {}

private struct SettingsRedirectView: View {
    let onRedirect: () -> Void

    var body: some View {
        SettingsWindowBridge(onRedirect: onRedirect)
            .frame(width: 1, height: 1)
    }
}

private struct SettingsWindowBridge: NSViewRepresentable {
    let onRedirect: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRedirect: onRedirect)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.redirectIfNeeded(from: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.redirectIfNeeded(from: nsView.window)
        }
    }

    final class Coordinator {
        private let onRedirect: () -> Void
        private var redirected = false

        init(onRedirect: @escaping () -> Void) {
            self.onRedirect = onRedirect
        }

        func redirectIfNeeded(from window: NSWindow?) {
            guard !redirected, let window else { return }
            redirected = true
            window.orderOut(nil)
            onRedirect()
        }
    }
}

@main
struct QuickAskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsRedirectView {
                appDelegate.showSettingsFromAppMenu()
            }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettingsFromAppMenu()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
