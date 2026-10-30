//
//  ClaudeAgent.swift
//  Code
//
//  Conversation state and the agentic tool-use loop for the Claude panel.
//

import Foundation
import SwiftUI

enum ClaudeModelOption: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet 5.5"
        case .opus: return "Opus 5.5"
        case .haiku: return "Haiku 5.5"
        }
    }
}

struct ClaudeTranscriptItem: Identifiable {
    enum Kind {
        case user(String)
        case assistant(String)
        case tool(name: String, summary: String, status: ToolStatus)
        case error(String)
    }
    enum ToolStatus {
        case running, done, failed(String), rejected
    }

    let id = UUID()
    var kind: Kind
}

struct ClaudePendingApproval: Identifiable {
    let id = UUID()
    let change: ClaudeFileChange
    let resume: (Bool) -> Void
}

@MainActor
final class ClaudeAgent: ObservableObject {
    static let apiKeyKeychainID = "claude.assistant.apiKey"

    @Published var transcript: [ClaudeTranscriptItem] = []
    @Published var input: String = ""
    @Published var isRunning = false
    @Published var pendingApproval: ClaudePendingApproval?
    @Published var usageSummary: String = ""

    @Published var model: ClaudeModelOption =
        ClaudeModelOption(rawValue: UserDefaults.standard.string(forKey: "claude.assistant.model") ?? "")
        ?? .sonnet
    {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "claude.assistant.model") }
    }
    @Published var requireApproval: Bool =
        UserDefaults.standard.object(forKey: "claude.assistant.requireApproval") as? Bool ?? true
    {
        didSet { UserDefaults.standard.set(requireApproval, forKey: "claude.assistant.requireApproval") }
    }

    private let maxTokens = 16000

    var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }

    private var apiKey: String? {
        KeychainAccessor.shared.getObjectString(for: Self.apiKeyKeychainID)
    }

    private weak var app: MainApp?
    private var tools: ClaudeToolExecutor?
    private let client = ClaudeAPIClient()
    private var messages: [[String: Any]] = []
    private var runTask: Task<Void, Never>?
    private var totalInputTokens = 0
    private var totalOutputTokens = 0
    /// Transcript item receiving the currently streaming assistant text.
    private var streamingTextItemID: UUID?

    private let maxIterations = 40

    func attach(app: MainApp) {
        self.app = app
        self.tools = ClaudeToolExecutor(app: app)
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainAccessor.shared.removeObjectForKey(for: Self.apiKeyKeychainID)
        } else {
            KeychainAccessor.shared.storeObject(for: Self.apiKeyKeychainID, value: trimmed)
        }
        objectWillChange.send()
    }

    func newConversation() {
        stop()
        transcript.removeAll()
        messages.removeAll()
        totalInputTokens = 0
        totalOutputTokens = 0
        usageSummary = ""
    }

    /// Called when the user opens another folder; old context no longer applies.
    func workspaceChanged() {
        newConversation()
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        if let pending = pendingApproval {
            pendingApproval = nil
            pending.resume(false)
        }
        isRunning = false
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        input = ""
        transcript.append(.init(kind: .user(text)))
        messages.append(["role": "user", "content": userContent(for: text)])

        isRunning = true
        runTask = Task { [weak self] in
            await self?.runLoop()
            self?.repairHistory()
            self?.isRunning = false
        }
    }

    // MARK: - Agent loop

    private func runLoop() async {
        guard let tools else { return }
        guard let apiKey, !apiKey.isEmpty else {
            transcript.append(.init(kind: .error(ClaudeAPIError.missingAPIKey.localizedDescription)))
            return
        }

        for _ in 0..<maxIterations {
            if Task.isCancelled { return }

            streamingTextItemID = nil

            let result: ClaudeTurnResult
            do {
                result = try await client.streamMessage(
                    apiKey: apiKey,
                    model: model.rawValue,
                    maxTokens: maxTokens,
                    system: systemPrompt(),
                    tools: ClaudeToolDefinitions.all,
                    messages: messages,
                    onEvent: { [weak self] event in
                        self?.handle(event)
                    })
            } catch is CancellationError {
                return
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                transcript.append(.init(kind: .error(error.localizedDescription)))
                return
            }

            totalInputTokens += result.inputTokens
            totalOutputTokens += result.outputTokens
            usageSummary = "\(totalInputTokens / 1000)k in · \(totalOutputTokens / 1000)k out"

            guard !result.contentBlocks.isEmpty else { return }
            messages.append(["role": "assistant", "content": result.contentBlocks])

            guard result.stopReason == "tool_use" else {
                if result.stopReason == "max_tokens" {
                    transcript.append(
                        .init(kind: .error("Response was cut off (max tokens). Ask Claude to continue.")))
                }
                return
            }

            var toolResults: [[String: Any]] = []
            for call in result.toolUses {
                var output = "Cancelled by the user."
                var isError = true
                if !Task.isCancelled {
                    (output, isError) = await execute(
                        name: call.name, input: call.input, tools: tools)
                }
                toolResults.append([
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": output,
                    "is_error": isError,
                ])
            }
            messages.append(["role": "user", "content": toolResults])
        }

        transcript.append(.init(kind: .error("Stopped after \(maxIterations) steps.")))
    }

    private func handle(_ event: ClaudeStreamEvent) {
        switch event {
        case .textDelta(let delta):
            if let id = streamingTextItemID,
                let index = transcript.firstIndex(where: { $0.id == id }),
                case .assistant(let existing) = transcript[index].kind
            {
                transcript[index].kind = .assistant(existing + delta)
            } else {
                let item = ClaudeTranscriptItem(kind: .assistant(delta))
                streamingTextItemID = item.id
                transcript.append(item)
            }
        case .toolUseStarted:
            // Text after a tool call starts a new bubble.
            streamingTextItemID = nil
        }
    }

    /// After a cancel or error, make sure every tool_use has a matching tool_result,
    /// otherwise the next request would be rejected by the API.
    private func repairHistory() {
        guard let last = messages.last, last["role"] as? String == "assistant",
            let blocks = last["content"] as? [[String: Any]]
        else { return }
        let ids = blocks.compactMap { block -> String? in
            block["type"] as? String == "tool_use" ? block["id"] as? String : nil
        }
        guard !ids.isEmpty else { return }
        messages.append([
            "role": "user",
            "content": ids.map {
                [
                    "type": "tool_result", "tool_use_id": $0,
                    "content": "Cancelled by the user.", "is_error": true,
                ] as [String: Any]
            },
        ])
    }

    private func execute(name: String, input: [String: Any], tools: ClaudeToolExecutor) async
        -> (String, Bool)
    {
        let item = ClaudeTranscriptItem(
            kind: .tool(name: name, summary: describe(name: name, input: input), status: .running))
        transcript.append(item)

        func setStatus(_ status: ClaudeTranscriptItem.ToolStatus, summary: String? = nil) {
            guard let index = transcript.firstIndex(where: { $0.id == item.id }),
                case .tool(let n, let s, _) = transcript[index].kind
            else { return }
            transcript[index].kind = .tool(name: n, summary: summary ?? s, status: status)
        }

        do {
            if ClaudeToolDefinitions.mutatingTools.contains(name) {
                let change = try await tools.proposeChange(name: name, input: input)
                setStatus(.running, summary: change.summary)

                if requireApproval {
                    let approved = await requestApproval(for: change)
                    guard approved else {
                        setStatus(.rejected)
                        return ("The user rejected this change. Ask how they would like to proceed.", true)
                    }
                }
                let output = try await tools.apply(change)
                setStatus(.done)
                return (output, false)
            } else {
                let output = try await tools.run(name: name, input: input)
                setStatus(.done)
                return (output, false)
            }
        } catch {
            setStatus(.failed(error.localizedDescription))
            return ("Error: \(error.localizedDescription)", true)
        }
    }

    private func requestApproval(for change: ClaudeFileChange) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingApproval = ClaudePendingApproval(change: change) { [weak self] approved in
                self?.pendingApproval = nil
                continuation.resume(returning: approved)
            }
        }
    }

    func resolveApproval(_ approved: Bool) {
        pendingApproval?.resume(approved)
    }

    // MARK: - Prompting

    private func describe(name: String, input: [String: Any]) -> String {
        let path = input["path"] as? String ?? "."
        switch name {
        case "list_directory": return "List \(path)"
        case "read_file": return "Read \(path)"
        case "search_files": return "Search “\(input["query"] as? String ?? "")” in \(path)"
        case "write_file": return "Write \(path)"
        case "edit_file": return "Edit \(path)"
        default: return name
        }
    }

    /// Kept stable across turns so it can be prompt-cached.
    private func systemPrompt() -> String {
        let root = tools?.rootURL
        let location: String
        switch root?.scheme {
        case "file", nil: location = "a local folder on the user's iPad"
        default: location = "a remote \(root?.scheme?.uppercased() ?? "") server"
        }
        return """
            You are Claude, a coding assistant embedded in Code App, a code editor for iPad.
            The user's workspace is \(location), named "\(root?.lastPathComponent ?? "workspace")".
            All paths you pass to tools are relative to the workspace root.

            You can list, read, search, create and edit files with the provided tools. You cannot run \
            shell commands, build, or execute code; when that is needed, tell the user what to run \
            in the terminal.

            Guidelines:
            - Read a file before editing it. Prefer edit_file with small, unique old_string snippets \
            over rewriting whole files.
            - Keep changes focused on what the user asked for.
            - The user may reject a change; if so, ask how to proceed instead of retrying the same edit.
            - Be concise. The panel is narrow, so prefer short paragraphs and small code snippets.
            """
    }

    /// Adds editor context (active file) in front of the user's message.
    private func userContent(for text: String) -> String {
        guard let tools, let app, let editor = app.activeTextEditor else { return text }
        let path = tools.relativePath(editor.url)
        return "<context>Active file in the editor: \(path)</context>\n\n\(text)"
    }
}
