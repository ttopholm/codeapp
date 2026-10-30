//
//  ClaudeTools.swift
//  Code
//
//  Workspace tools exposed to Claude. All file access goes through
//  WorkSpaceStorage, so the tools work for local folders as well as
//  SFTP/FTP (and any future FileSystemProvider, e.g. SMB).
//

import Foundation

struct ClaudeToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A proposed change to a file that may need user approval before being written.
struct ClaudeFileChange {
    let url: URL
    let displayPath: String
    let oldContent: String?
    let newContent: String
    let summary: String
}

enum ClaudeToolDefinitions {
    static let all: [[String: Any]] = [
        [
            "name": "list_directory",
            "description":
                "List the entries of a directory in the workspace. Directories end with '/'. Paths are relative to the workspace root; use '.' for the root.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Directory path relative to the workspace root."]
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "read_file",
            "description":
                "Read a text file from the workspace. Returns the content with 1-based line numbers. Use offset/limit for large files.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "offset": ["type": "integer", "description": "1-based line to start from."],
                    "limit": ["type": "integer", "description": "Maximum number of lines to return (default 2000)."],
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "search_files",
            "description":
                "Search for a case-insensitive substring in text files under a directory. Skips .git, node_modules and binary files. Returns path:line: text matches.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "path": ["type": "string", "description": "Directory to search in (default '.')."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "write_file",
            "description":
                "Create a new file or completely overwrite an existing file. Parent directories are created. Prefer edit_file for changes to existing files.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "content": ["type": "string"],
                ],
                "required": ["path", "content"],
            ],
        ],
        [
            "name": "edit_file",
            "description":
                "Replace an exact string in an existing file. old_string must match exactly (including whitespace) and be unique unless replace_all is true. Read the file first.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "old_string": ["type": "string"],
                    "new_string": ["type": "string"],
                    "replace_all": ["type": "boolean"],
                ],
                "required": ["path", "old_string", "new_string"],
            ],
        ],
    ]

    static let mutatingTools: Set<String> = ["write_file", "edit_file"]
}

/// Executes tool calls against the current workspace.
@MainActor
final class ClaudeToolExecutor {
    private weak var app: MainApp?

    private let maxReadLines = 2000
    private let maxSearchFiles = 2000
    private let maxSearchMatches = 200
    private let maxFileBytesForSearch = 1_000_000
    private let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "build", "__pycache__", ".venv", "venv"]

    init(app: MainApp) {
        self.app = app
    }

    var rootURL: URL? {
        guard let app else { return nil }
        return URL(string: app.workSpaceStorage.currentDirectory.url)?.standardized
    }

    private var storage: WorkSpaceStorage {
        get throws {
            guard let app else { throw ClaudeToolError("App is not available.") }
            return app.workSpaceStorage
        }
    }

    // MARK: - Path handling

    func resolve(_ rawPath: String?) throws -> URL {
        guard let root = rootURL else { throw ClaudeToolError("No workspace folder is open.") }
        var path = (rawPath ?? ".").trimmingCharacters(in: .whitespacesAndNewlines)

        // Accept absolute paths inside the workspace as well as relative ones.
        if path.hasPrefix(root.path) {
            path = String(path.dropFirst(root.path.count))
        }
        while path.hasPrefix("/") { path.removeFirst() }

        let url = (path.isEmpty || path == ".") ? root : root.appendingPathComponent(path).standardized
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(rootPath) else {
            throw ClaudeToolError("Path '\(rawPath ?? "")' is outside the workspace.")
        }
        return url
    }

    func relativePath(_ url: URL) -> String {
        guard let root = rootURL else { return url.path }
        let rel = url.standardized.path.dropFirst(root.path.count)
        let trimmed = rel.hasPrefix("/") ? String(rel.dropFirst()) : String(rel)
        return trimmed.isEmpty ? "." : trimmed
    }

    // MARK: - Read-only tools

    func run(name: String, input: [String: Any]) async throws -> String {
        switch name {
        case "list_directory":
            return try await listDirectory(path: input["path"] as? String)
        case "read_file":
            return try await readFile(
                path: input["path"] as? String,
                offset: input["offset"] as? Int,
                limit: input["limit"] as? Int)
        case "search_files":
            guard let query = input["query"] as? String, !query.isEmpty else {
                throw ClaudeToolError("query is required.")
            }
            return try await searchFiles(query: query, path: input["path"] as? String)
        default:
            throw ClaudeToolError("Unknown tool: \(name)")
        }
    }

    /// File system providers return directory URLs with a trailing slash
    /// (the explorer relies on this too), so no extra round-trip is needed.
    private func isDirectory(_ url: URL) -> Bool {
        url.hasDirectoryPath
    }

    private func listDirectory(path: String?) async throws -> String {
        let url = try resolve(path)
        let entries = try await storage.contentsOfDirectory(at: url)
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        if entries.isEmpty { return "(empty directory)" }

        var lines: [String] = []
        for entry in entries.prefix(500) {
            let name = entry.lastPathComponent
            lines.append(isDirectory(entry) ? name + "/" : name)
        }
        if entries.count > 500 {
            lines.append("… \(entries.count - 500) more entries")
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the current text of a file, preferring an open editor's buffer.
    func currentText(of url: URL) async throws -> String {
        if let editor = openEditor(for: url) {
            return editor.content
        }
        let data = try await storage.contents(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClaudeToolError("\(relativePath(url)) is not a UTF-8 text file.")
        }
        return text
    }

    private func readFile(path: String?, offset: Int?, limit: Int?) async throws -> String {
        let url = try resolve(path)
        let text = try await currentText(of: url)
        let lines = text.components(separatedBy: "\n")
        let start = max(1, offset ?? 1)
        let count = min(max(1, limit ?? maxReadLines), maxReadLines)
        guard start <= lines.count else {
            return "(file has \(lines.count) lines; offset \(start) is past the end)"
        }
        let end = min(lines.count, start + count - 1)
        var output = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
        if end < lines.count {
            output += "\n… (\(lines.count - end) more lines, use offset to continue)"
        }
        return output
    }

    private func searchFiles(query: String, path: String?) async throws -> String {
        let start = try resolve(path)
        let needle = query.lowercased()
        var matches: [String] = []
        var queue: [URL] = [start]
        var scannedFiles = 0

        while let dir = queue.first, matches.count < maxSearchMatches, scannedFiles < maxSearchFiles {
            queue.removeFirst()
            guard let entries = try? await storage.contentsOfDirectory(at: dir) else { continue }
            for entry in entries {
                if matches.count >= maxSearchMatches || scannedFiles >= maxSearchFiles { break }
                let name = entry.lastPathComponent
                if isDirectory(entry) {
                    if !skippedDirectories.contains(name) { queue.append(entry) }
                    continue
                }
                scannedFiles += 1
                guard let data = try? await storage.contents(at: entry),
                    data.count <= maxFileBytesForSearch,
                    !data.prefix(1024).contains(0),
                    let text = String(data: data, encoding: .utf8)
                else { continue }

                for (index, line) in text.components(separatedBy: "\n").enumerated()
                where line.lowercased().contains(needle) {
                    let snippet = line.trimmingCharacters(in: .whitespaces).prefix(200)
                    matches.append("\(relativePath(entry)):\(index + 1): \(snippet)")
                    if matches.count >= maxSearchMatches { break }
                }
            }
        }

        if matches.isEmpty { return "No matches for '\(query)' (scanned \(scannedFiles) files)." }
        var output = matches.joined(separator: "\n")
        if matches.count >= maxSearchMatches || scannedFiles >= maxSearchFiles {
            output += "\n… (results truncated; narrow the search path)"
        }
        return output
    }

    // MARK: - Mutating tools

    /// Computes the change a mutating tool would make, without writing anything.
    func proposeChange(name: String, input: [String: Any]) async throws -> ClaudeFileChange {
        let url = try resolve(input["path"] as? String)
        let display = relativePath(url)

        if let editor = openEditor(for: url), !editor.isSaved {
            throw ClaudeToolError(
                "\(display) has unsaved changes in the editor. Ask the user to save or discard them first."
            )
        }

        switch name {
        case "write_file":
            guard let content = input["content"] as? String else {
                throw ClaudeToolError("content is required.")
            }
            let existing = try? await currentText(of: url)
            return ClaudeFileChange(
                url: url, displayPath: display, oldContent: existing, newContent: content,
                summary: existing == nil ? "Create \(display)" : "Overwrite \(display)")

        case "edit_file":
            guard let old = input["old_string"] as? String,
                let new = input["new_string"] as? String
            else { throw ClaudeToolError("old_string and new_string are required.") }
            guard !old.isEmpty else { throw ClaudeToolError("old_string must not be empty.") }
            let replaceAll = input["replace_all"] as? Bool ?? false
            let text = try await currentText(of: url)
            let occurrences = text.components(separatedBy: old).count - 1
            if occurrences == 0 {
                throw ClaudeToolError("old_string was not found in \(display).")
            }
            if occurrences > 1 && !replaceAll {
                throw ClaudeToolError(
                    "old_string occurs \(occurrences) times in \(display). Add more context or set replace_all."
                )
            }
            let updated = text.replacingOccurrences(of: old, with: new)
            return ClaudeFileChange(
                url: url, displayPath: display, oldContent: text, newContent: updated,
                summary: "Edit \(display) (\(occurrences) replacement\(occurrences == 1 ? "" : "s"))")

        default:
            throw ClaudeToolError("Unknown tool: \(name)")
        }
    }

    func apply(_ change: ClaudeFileChange) async throws -> String {
        let storage = try self.storage
        let parent = change.url.deletingLastPathComponent()
        if !((try? await storage.fileExists(at: parent)) ?? false) {
            try await storage.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try await storage.write(
            at: change.url, content: Data(change.newContent.utf8), atomically: true, overwrite: true)
        await syncOpenEditor(url: change.url, content: change.newContent)
        if change.oldContent == nil {
            app?.reloadDirectory()
        }
        return "\(change.summary): done."
    }

    // MARK: - Editor integration

    private func openEditor(for url: URL) -> TextEditorInstance? {
        app?.textEditors.first { $0.url.standardized == url.standardized }
    }

    /// Keeps an already-open editor tab in sync with what Claude wrote to disk.
    private func syncOpenEditor(url: URL, content: String) async {
        guard let app, let editor = openEditor(for: url) else { return }
        editor.content = content
        await app.monacoInstance.setValueForModel(url: editor.url.absoluteString, value: content)
        let attributes = try? await app.workSpaceStorage.attributesOfItem(at: url)
        editor.lastSavedDate = attributes?[.modificationDate] as? Date ?? Date()

        // Monaco reports the content change (and bumps currentVersionId) asynchronously.
        // Wait for it, then mark the buffer as saved since it matches what's on disk.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if editor.content == content, editor.currentVersionId != editor.lastSavedVersionId {
                break
            }
        }
        if editor.content == content {
            editor.lastSavedVersionId = editor.currentVersionId
        }
    }
}
