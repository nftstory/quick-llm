import AppKit
import Carbon.HIToolbox
import SwiftUI

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
    let panelFrame: CodableRect
    let inputBarFrame: CodableRect
    let inputBarBottomInset: Double
    let historyAreaHeight: Double
    let messageCount: Int
    let queuedCount: Int
    let isGenerating: Bool
    let selectedModel: String
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
    @Published var statusText = ""

    weak var layoutDelegate: QuickAskLayoutDelegate?

    private let backendPath: String
    private let defaults = UserDefaults.standard
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
    private var pendingSteerAfterTermination = false

    init(backendPath: String) {
        self.backendPath = backendPath
        if let storedModel = defaults.string(forKey: lastModelKey), !storedModel.isEmpty {
            selectedModelID = storedModel
        }
        startIdleTimer()
    }

    deinit {
        idleTimer?.invalidate()
    }

    func requestFocus() {
        focusToken = UUID()
    }

    func touch() {
        lastInteractionAt = Date()
    }

    func panelShown() {
        touch()
        requestFocus()
    }

    func panelHidden() {
        touch()
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
        let backendPath = self.backendPath
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", backendPath, "models"]
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
                    self.statusText = "Could not load models."
                }
                return
            }

            await MainActor.run {
                self.models = payload.models
                if let selected = self.models.first(where: { $0.id == self.selectedModelID }) {
                    self.selectedModelID = selected.id
                } else if let defaultModel = self.models.first(where: { $0.default == true }) ?? self.models.first {
                    self.selectedModelID = defaultModel.id
                }
                self.defaults.set(self.selectedModelID, forKey: self.lastModelKey)
                if self.statusText == "Could not load models." {
                    self.statusText = ""
                }
            }
        }
    }

    func selectModel(_ modelID: String) {
        selectedModelID = modelID
        defaults.set(modelID, forKey: lastModelKey)
        touch()
    }

    func clearHistory() {
        saveTranscript()
        messages = []
        queuedPrompts = []
        historyAreaHeight = 0
        inputText = ""
        statusText = ""
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
        if isGenerating {
            pendingResetAfterTermination = true
            cancelActiveGeneration()
            return
        }
        clearHistory()
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

    func steerQueuedPrompt() {
        touch()
        guard !queuedPrompts.isEmpty else { return }
        if isGenerating {
            pendingSteerAfterTermination = true
            cancelActiveGeneration()
            return
        }
        sendNextQueuedPrompt()
    }

    private func startGeneration(for prompt: String) {
        statusText = ""
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
            statusText = message
        default:
            break
        }
    }

    private func appendAssistantChunk(_ text: String) {
        guard !text.isEmpty else { return }
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
        let interruptedForSteer = pendingSteerAfterTermination
        pendingSteerAfterTermination = false
        isGenerating = false
        activeProcess = nil

        if pendingResetAfterTermination {
            pendingResetAfterTermination = false
            clearHistory()
            requestFocus()
            return
        }

        if exitCode != 0 && statusText.isEmpty && !interruptedForSteer {
            let stderr = String(data: stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            statusText = stderr?.isEmpty == false ? stderr! : "The reply failed."
        }

        if let assistantID = activeAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == assistantID }),
           messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: index)
        }

        activeAssistantMessageID = nil
        saveTranscript()
        layoutDelegate?.quickAskNeedsLayout()
        if !queuedPrompts.isEmpty {
            sendNextQueuedPrompt()
            return
        }
        requestFocus()
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

    private let backendPath: String

    init(backendPath: String) {
        self.backendPath = backendPath
    }

    nonisolated private static func fetchHistory(backendPath: String) -> (payload: QuickAskHistoryEnvelope?, message: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", backendPath, "history", "--limit", "200"]

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
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                QuickAskHistoryViewModel.fetchHistory(backendPath: backendPath)
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
}

struct QuickAskHistoryRow: View {
    let session: QuickAskHistorySession

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
                Text(session.preview.isEmpty ? "Untitled session" : session.preview)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(QuickAskTheme.strongText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(session.messageCount)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(QuickAskTheme.strongText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Rectangle().fill(QuickAskTheme.panelAccent))
                    .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(QuickAskTheme.inputBackground)

            HStack(spacing: 8) {
                if !session.model.isEmpty {
                    Text(session.model)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QuickAskTheme.strongText)
                        .lineLimit(1)
                }
                Text(relativeSavedAtText)
                        .font(.system(size: 11))
                        .foregroundStyle(QuickAskTheme.mutedText)
                        .lineLimit(1)
                Spacer(minLength: 8)
                Text("restore")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QuickAskTheme.strongText.opacity(0.82))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(QuickAskTheme.historyBackground)
        }
        .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Rectangle().fill(QuickAskTheme.panelAccent))
            .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
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
                commandButton("Close") {
                    onClose()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(QuickAskTheme.inputBackground)
            .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))

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
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.sessions) { session in
                                Button {
                                    onSelectSession(session)
                                } label: {
                                    QuickAskHistoryRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(10)
                    .background(QuickAskTheme.historyBackground)
                }
            }
            .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(QuickAskTheme.frameBackground)
        .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
        .onAppear {
            if viewModel.sessions.isEmpty {
                viewModel.reload()
            }
        }
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

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.content.isEmpty ? "…" : message.content)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 360, alignment: .leading)
                .background(
                    Rectangle()
                        .fill(bubbleColor)
                )
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                )
            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
    }
}

struct QueuedPromptRow: View {
    let prompt: QueuedPrompt

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(prompt.content)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(QuickAskTheme.strongText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("queued")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(QuickAskTheme.mutedText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Rectangle().fill(Color.white.opacity(0.12)))
        .overlay(Rectangle().stroke(QuickAskTheme.dividerColor, lineWidth: 1))
    }
}

struct QuickAskView: View {
    @ObservedObject var viewModel: QuickAskViewModel
    @FocusState private var inputFocused: Bool

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
                        actionButton("Steer") {
                            viewModel.steerQueuedPrompt()
                        }
                    }

                    ForEach(viewModel.queuedPrompts) { prompt in
                        QueuedPromptRow(prompt: prompt)
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
                    } label: {
                        Text(currentModelShortLabel)
                            .lineLimit(1)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(QuickAskTheme.strongText)
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
                    .fixedSize()

                    Rectangle()
                        .fill(QuickAskTheme.dividerColor)
                        .frame(width: 1, height: 24)

                    TextField("Ask quickly…", text: $viewModel.inputText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(QuickAskTheme.strongText)
                        .font(.system(size: 14, weight: .regular))
                        .focused($inputFocused)
                        .onSubmit {
                            viewModel.send()
                        }
                        .onChange(of: viewModel.inputText) { _, _ in
                            viewModel.touch()
                        }
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
                }
            }
        }
        .frame(width: 560)
        .background(QuickAskTheme.frameBackground)
        .onAppear {
            inputFocused = true
        }
        .onChange(of: viewModel.focusToken) { _, _ in
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
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
    private var historyViewModel: QuickAskHistoryViewModel!
    private var hotKeyManager: HotKeyManager?
    private var viewModel: QuickAskViewModel!
    private var localKeyMonitor: Any?
    private var panelBottomY: CGFloat?
    private var isProgrammaticPanelMove = false
    private var uiTestHarness: QuickAskUITestHarness?
    private let defaults = UserDefaults.standard
    private let panelOriginXKey = "QuickAskPanelOriginX"
    private let panelBottomYKey = "QuickAskPanelBottomY"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let backendPath = resolveBackendPath()
        viewModel = QuickAskViewModel(backendPath: backendPath)
        viewModel.layoutDelegate = self
        historyViewModel = QuickAskHistoryViewModel(backendPath: backendPath)

        hostingView = MovableHostingView(rootView: QuickAskView(viewModel: viewModel))
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
        historyWindow.isMovableByWindowBackground = true
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

        hotKeyManager = HotKeyManager { [weak self] in
            self?.togglePanel()
        } historyCallback: { [weak self] in
            self?.toggleHistoryWindow()
        }
        hotKeyManager?.install()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
                self.viewModel.steerQueuedPrompt()
                return nil
            }
            return event
        }
        viewModel.loadModels()
        historyViewModel.reload()
        quickAskNeedsLayout()
        uiTestHarness = QuickAskUITestHarness(appDelegate: self)
        uiTestHarness?.writeState()
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
            if let savedOriginX = defaults.object(forKey: panelOriginXKey) as? Double,
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
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticPanelMove = false
        }
        uiTestHarness?.writeState()
    }

    private func togglePanel() {
        if panel.isVisible {
            viewModel.panelHidden()
            panel.orderOut(nil)
            uiTestHarness?.writeState()
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

    private func showPanel() {
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
        if historyWindow.isVisible {
            hideHistoryWindow()
            return
        }

        historyViewModel.reload()
        historyWindow.makeKeyAndOrderFront(nil)
        historyWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        uiTestHarness?.writeState()
    }

    private func hideHistoryWindow() {
        historyWindow.saveFrame(usingName: "QuickAskHistoryWindowFrame")
        historyWindow.orderOut(nil)
        uiTestHarness?.writeState()
    }

    private func restoreSession(_ session: QuickAskHistorySession) {
        hideHistoryWindow()
        loadSession(session.sessionID)
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

    private func currentScreen() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) ?? NSScreen.main
    }

    private func loadSession(_ sessionID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", resolveBackendPath(), "load", "--session-id", sessionID]

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

    fileprivate func uiTestState(handledCommandID: Int) -> QuickAskUITestState {
        let selectedModel: String
        if let viewModel {
            selectedModel = viewModel.models.first(where: { $0.id == viewModel.selectedModelID })?.shortLabel ?? ""
        } else {
            selectedModel = ""
        }

        return QuickAskUITestState(
            panelVisible: panel?.isVisible ?? false,
            historyWindowVisible: historyWindow?.isVisible ?? false,
            panelFrame: CodableRect(panel?.frame ?? .zero),
            inputBarFrame: CodableRect(viewModel?.inputBarFrame ?? .zero),
            inputBarBottomInset: max(
                0,
                Double((panel?.frame.height ?? 0) - ((viewModel?.inputBarFrame.maxY ?? 0)))
            ),
            historyAreaHeight: Double(viewModel?.historyAreaHeight ?? 0),
            messageCount: viewModel?.messages.count ?? 0,
            queuedCount: viewModel?.queuedPrompts.count ?? 0,
            isGenerating: viewModel?.isGenerating ?? false,
            selectedModel: selectedModel,
            handledCommandID: handledCommandID
        )
    }

    fileprivate func handleUITestCommand(_ command: QuickAskUITestCommand) {
        switch command.action {
        case "show_panel":
            showPanel()
        case "hide_panel":
            if panel.isVisible {
                viewModel.panelHidden()
                panel.orderOut(nil)
            }
        case "set_input":
            viewModel.inputText = command.text ?? ""
            viewModel.touch()
            quickAskNeedsLayout()
        case "submit":
            viewModel.send()
        case "complete_generation":
            viewModel.completeTestGeneration(with: command.text ?? "")
        case "new_chat":
            startNewChat()
        case "shortcut":
            switch command.shortcut {
            case "cmd_n":
                startNewChat()
            case "cmd_enter":
                viewModel.steerQueuedPrompt()
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

final class MovableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

@main
struct QuickAskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
