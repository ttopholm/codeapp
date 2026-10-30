//
//  ClaudeContainer.swift
//  Code
//
//  Sidebar UI for the Claude assistant.
//

import SwiftUI

struct ClaudeContainer: View {
    @EnvironmentObject var agent: ClaudeAgent
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            ClaudeHeader(showsSettings: $showsSettings)
            Divider()

            if !agent.hasAPIKey {
                ClaudeAPIKeySetup()
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ClaudeTranscriptView()
                if let pending = agent.pendingApproval {
                    Divider()
                    ClaudeApprovalCard(pending: pending)
                }
                Divider()
                ClaudeInputBar()
            }
        }
        .sheet(isPresented: $showsSettings) {
            ClaudeSettingsView()
                .environmentObject(agent)
        }
    }
}

// MARK: - Header

private struct ClaudeHeader: View {
    @EnvironmentObject var agent: ClaudeAgent
    @Binding var showsSettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Model", selection: $agent.model) {
                    ForEach(ClaudeModelOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text(agent.model.displayName)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.subheadline)
            }

            Spacer()

            if !agent.usageSummary.isEmpty {
                Text(agent.usageSummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button {
                agent.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New conversation")

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Claude settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Transcript

private struct ClaudeTranscriptView: View {
    @EnvironmentObject var agent: ClaudeAgent

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.transcript.isEmpty {
                        ClaudeEmptyState()
                    }
                    ForEach(agent.transcript) { item in
                        ClaudeTranscriptRow(item: item)
                            .id(item.id)
                    }
                    if agent.isRunning && agent.pendingApproval == nil {
                        ProgressView()
                            .padding(.leading, 4)
                            .id("progress")
                    }
                }
                .padding(12)
            }
            .onChange(of: agent.transcript.last.map(transcriptSignature)) { _ in
                guard let lastID = agent.transcript.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    /// Changes whenever the last item is added or grows while streaming.
    private func transcriptSignature(_ item: ClaudeTranscriptItem) -> String {
        switch item.kind {
        case .assistant(let text): return "\(item.id)-\(text.count)"
        default: return "\(item.id)"
        }
    }
}

private struct ClaudeEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask Claude about this workspace")
                .font(.headline)
            Text(
                "Claude can read, search and edit files in the open folder — local or remote. Changes are shown for approval before they are written."
            )
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct ClaudeTranscriptRow: View {
    let item: ClaudeTranscriptItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            Text(text)
                .font(.subheadline)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.15))
                .cornerRadius(10)

        case .assistant(let text):
            Text(markdown(text))
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .tool(let name, let summary, let status):
            HStack(alignment: .top, spacing: 6) {
                statusIcon(status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .font(.caption)
                        .lineLimit(2)
                    if case .failed(let message) = status {
                        Text(message)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(3)
                    }
                }
            }
            .foregroundColor(.secondary)
            .help(name)

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ClaudeTranscriptItem.ToolStatus) -> some View {
        switch status {
        case .running:
            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle").font(.caption)
        case .failed:
            Image(systemName: "xmark.circle").font(.caption).foregroundColor(.red)
        case .rejected:
            Image(systemName: "hand.raised").font(.caption).foregroundColor(.orange)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// MARK: - Approval

private struct ClaudeApprovalCard: View {
    @EnvironmentObject var agent: ClaudeAgent
    let pending: ClaudePendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(pending.change.summary, systemImage: "doc.badge.ellipsis")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            ScrollView {
                ClaudeDiffView(
                    old: pending.change.oldContent ?? "", new: pending.change.newContent)
            }
            .frame(maxHeight: 220)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)

            HStack {
                Button(role: .destructive) {
                    agent.resolveApproval(false)
                } label: {
                    Text("Reject").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    agent.resolveApproval(true)
                } label: {
                    Text("Apply").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(12)
    }
}

/// A compact line diff (removed/added lines only, with a little context).
struct ClaudeDiffView: View {
    let old: String
    let new: String

    private struct Line: Identifiable {
        let id: Int
        let prefix: String
        let text: String
    }

    private var lines: [Line] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let difference = newLines.difference(from: oldLines)

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Walk both files in parallel, emitting changed lines plus 2 lines of context.
        var result: [Line] = []
        var o = 0
        var n = 0
        var pendingContext: [String] = []
        var trailingContext = 0
        let maxLines = 400

        func emit(_ prefix: String, _ text: String) {
            guard result.count < maxLines else { return }
            result.append(Line(id: result.count, prefix: prefix, text: text))
        }

        while o < oldLines.count || n < newLines.count {
            if o < oldLines.count, removed.contains(o) {
                pendingContext.forEach { emit(" ", $0) }
                pendingContext.removeAll()
                emit("-", oldLines[o])
                o += 1
                trailingContext = 2
            } else if n < newLines.count, inserted.contains(n) {
                pendingContext.forEach { emit(" ", $0) }
                pendingContext.removeAll()
                emit("+", newLines[n])
                n += 1
                trailingContext = 2
            } else {
                let text = n < newLines.count ? newLines[n] : ""
                if trailingContext > 0 {
                    emit(" ", text)
                    trailingContext -= 1
                } else {
                    if pendingContext.count == 2, result.last?.prefix != "⋯", !result.isEmpty {
                        emit("⋯", "")
                    }
                    pendingContext.append(text)
                    if pendingContext.count > 2 { pendingContext.removeFirst() }
                }
                o += 1
                n += 1
            }
        }
        if result.count >= maxLines {
            result.append(Line(id: result.count, prefix: "⋯", text: "diff truncated"))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(verbatim: "\(line.prefix) \(line.text)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(color(for: line.prefix))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: line.prefix))
            }
        }
        .padding(6)
        .textSelection(.enabled)
    }

    private func color(for prefix: String) -> Color {
        switch prefix {
        case "+": return .green
        case "-": return .red
        default: return .secondary
        }
    }

    private func background(for prefix: String) -> Color {
        switch prefix {
        case "+": return Color.green.opacity(0.12)
        case "-": return Color.red.opacity(0.12)
        default: return .clear
        }
    }
}

// MARK: - Input

private struct ClaudeInputBar: View {
    @EnvironmentObject var agent: ClaudeAgent
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Claude…", text: $agent.input, axis: .vertical)
                .lineLimit(1...8)
                .font(.subheadline)
                .focused($focused)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .onSubmit { agent.send() }

            if agent.isRunning {
                Button {
                    agent.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .help("Stop")
            } else {
                Button {
                    agent.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(agent.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send (⌘↩)")
            }
        }
        .padding(10)
    }
}

// MARK: - API key & settings

private struct ClaudeAPIKeySetup: View {
    @EnvironmentObject var agent: ClaudeAgent
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect Claude")
                .font(.headline)
            Text(
                "Paste an Anthropic API key from console.anthropic.com. It is stored in the iOS Keychain on this device."
            )
            .font(.footnote)
            .foregroundColor(.secondary)
            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save key") {
                agent.setAPIKey(key)
                key = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }
}

private struct ClaudeSettingsView: View {
    @EnvironmentObject var agent: ClaudeAgent
    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Model") {
                    Picker("Model", selection: $agent.model) {
                        ForEach(ClaudeModelOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
                Section {
                    Toggle("Ask before changing files", isOn: $agent.requireApproval)
                } footer: {
                    Text("When off, Claude writes edits directly. Open editor tabs are updated either way.")
                }
                Section("API key") {
                    SecureField(agent.hasAPIKey ? "Replace key…" : "sk-ant-…", text: $newKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save key") {
                        agent.setAPIKey(newKey)
                        newKey = ""
                    }
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if agent.hasAPIKey {
                        Button("Remove key", role: .destructive) {
                            agent.setAPIKey("")
                        }
                    }
                }
            }
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SwiftUI.ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
