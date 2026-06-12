import Darwin
import Foundation

private enum RPCFrameFormat {
    case contentLength
    case jsonLines
}

enum CodexTaskStatusClientError: LocalizedError {
    case proxyUnavailable(String)
    case protocolMismatch(String)
    case appServerError(String)

    var errorDescription: String? {
        switch self {
        case .proxyUnavailable(let detail):
            if detail.contains("failed to connect to socket") || detail.contains("No such file or directory") {
                return "Codex app-server 未运行"
            }
            if detail.contains("command not found") {
                return "找不到 codex CLI"
            }
            return detail.isEmpty ? "Codex app-server 未运行" : detail
        case .protocolMismatch(let detail):
            return detail
        case .appServerError(let detail):
            return detail
        }
    }
}

final class CodexTaskStatusClient {
    private let unreadReader = CodexUnreadStateReader()
    private let appServerClient = CodexAppServerTaskClient()
    private let localRuntimeReader = CodexLocalRuntimeReader()

    func fetch() async -> TaskStatusSnapshot {
        let unreadIDs = unreadReader.readUnreadThreadIDs()
        let refreshedAt = Date()

        do {
            let threads = try await appServerClient.fetchThreads()
            let waitingThreads = await localRuntimeReader.fetchWaitingReplyThreads(unreadThreadIDs: unreadIDs)
            let summaryThreads = await localRuntimeReader.fetchThreadSummaries(
                threadIDs: unreadIDs.union(threads.map(\.id))
            )
            let mergedThreads = Self.merged(primary: threads, supplemental: waitingThreads)
            let decoratedThreads = Self.applyingSummaries(to: mergedThreads, summaries: summaryThreads)
            let snapshotThreads = Self.appendingMissing(
                existing: decoratedThreads,
                supplemental: summaryThreads.filter { unreadIDs.contains($0.id) }
            )
            return TaskStatusMapper.makeSnapshot(
                threads: snapshotThreads,
                unreadThreadIDs: unreadIDs,
                refreshedAt: refreshedAt,
                sourceState: .available
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let localThreads = await localRuntimeReader.fetchActiveThreads()
            let waitingThreads = await localRuntimeReader.fetchWaitingReplyThreads(unreadThreadIDs: unreadIDs)
            let summaryThreads = await localRuntimeReader.fetchThreadSummaries(
                threadIDs: unreadIDs.union(localThreads.map(\.id))
            )
            let mergedThreads = Self.merged(primary: localThreads, supplemental: waitingThreads)
            let decoratedThreads = Self.applyingSummaries(to: mergedThreads, summaries: summaryThreads)
            let threads = Self.appendingMissing(
                existing: decoratedThreads,
                supplemental: summaryThreads.filter { unreadIDs.contains($0.id) }
            )
            return TaskStatusMapper.makeSnapshot(
                threads: threads,
                unreadThreadIDs: unreadIDs,
                refreshedAt: refreshedAt,
                sourceState: threads.isEmpty ? .unavailable(message) : .available
            )
        }
    }

    private static func merged(primary: [CodexThreadDTO], supplemental: [CodexThreadDTO]) -> [CodexThreadDTO] {
        guard !supplemental.isEmpty else {
            return primary
        }

        let supplementalByID = Dictionary(uniqueKeysWithValues: supplemental.map { ($0.id, $0) })
        let primaryIDs = Set(primary.map(\.id))
        let mergedPrimary = primary.map { thread in
            guard let supplemental = supplementalByID[thread.id] else {
                return thread
            }
            if hasReminderFlag(supplemental.status), thread.status.type != "systemError" {
                return CodexThreadDTO(
                    id: thread.id,
                    preview: thread.preview,
                    cwd: thread.cwd,
                    updatedAt: thread.updatedAt,
                    status: supplemental.status,
                    name: thread.name
                )
            }

            switch thread.status.type {
            case "idle", "notLoaded":
                return CodexThreadDTO(
                    id: thread.id,
                    preview: thread.preview,
                    cwd: thread.cwd,
                    updatedAt: thread.updatedAt,
                    status: supplemental.status,
                    name: thread.name
                )
            default:
                return thread
            }
        }

        return mergedPrimary + supplemental.filter { !primaryIDs.contains($0.id) }
    }

    private static func applyingSummaries(to threads: [CodexThreadDTO], summaries: [CodexThreadDTO]) -> [CodexThreadDTO] {
        guard !summaries.isEmpty else {
            return threads
        }

        var summariesByID: [String: CodexThreadDTO] = [:]
        for summary in summaries where summariesByID[summary.id] == nil {
            summariesByID[summary.id] = summary
        }
        return threads.map { thread in
            guard let summary = summariesByID[thread.id] else {
                return thread
            }
            return CodexThreadDTO(
                id: thread.id,
                preview: usefulText(summary.preview) ?? thread.preview,
                cwd: summary.cwd ?? thread.cwd,
                updatedAt: thread.updatedAt ?? summary.updatedAt,
                status: thread.status,
                name: usefulText(summary.name) ?? thread.name
            )
        }
    }

    private static func appendingMissing(existing: [CodexThreadDTO], supplemental: [CodexThreadDTO]) -> [CodexThreadDTO] {
        guard !supplemental.isEmpty else {
            return existing
        }

        let existingIDs = Set(existing.map(\.id))
        return existing + supplemental.filter { !existingIDs.contains($0.id) }
    }

    private static func usefulText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed == "Codex 对话" ? nil : trimmed
    }

    private static func hasReminderFlag(_ status: CodexThreadDTO.RuntimeStatus) -> Bool {
        let flags = Set(status.activeFlags ?? [])
        return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
    }
}

final class CodexUnreadStateReader {
    private let stateURL: URL

    init(
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
    ) {
        self.stateURL = stateURL
    }

    func readUnreadThreadIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL) else {
            return []
        }
        return Self.unreadThreadIDs(from: data)
    }

    static func unreadThreadIDs(from data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        return unreadIDs(in: root) ?? []
    }

    private static func unreadIDs(in value: Any) -> Set<String>? {
        if let dictionary = value as? [String: Any] {
            if let byHost = dictionary["unread-thread-ids-by-host-v1"] as? [String: Any] {
                let ids = byHost.values.reduce(into: Set<String>()) { partial, hostValue in
                    if let hostIDs = hostValue as? [String] {
                        partial.formUnion(hostIDs)
                    }
                }
                if !ids.isEmpty {
                    return ids
                }
            }

            for nested in dictionary.values {
                if let ids = unreadIDs(in: nested) {
                    return ids
                }
            }
        }

        if let array = value as? [Any] {
            for nested in array {
                if let ids = unreadIDs(in: nested) {
                    return ids
                }
            }
        }

        return nil
    }
}

private final class CodexLocalRuntimeReader {
    private struct TailAnalysis {
        let activeFlags: [String]
    }

    private struct WaitingReplyAnalysis {
        let activeFlags: [String]
    }

    private struct SessionMetadata {
        let id: String
        let cwd: String?
        let preview: String?
    }

    private let sessionsURL: URL
    private let archivedSessionsURL: URL
    private let activeWindow: TimeInterval
    private let pendingCallWindow: TimeInterval
    private let waitingReplyWindow: TimeInterval
    private let summaryWindow: TimeInterval
    private let maxTailBytes: UInt64
    private let maxFiles: Int

    init(
        sessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions"),
        archivedSessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/archived_sessions"),
        activeWindow: TimeInterval = 10 * 60,
        pendingCallWindow: TimeInterval = 60 * 60,
        waitingReplyWindow: TimeInterval = 24 * 60 * 60,
        summaryWindow: TimeInterval = 7 * 24 * 60 * 60,
        maxTailBytes: UInt64 = 512 * 1024,
        maxFiles: Int = 40
    ) {
        self.sessionsURL = sessionsURL
        self.archivedSessionsURL = archivedSessionsURL
        self.activeWindow = activeWindow
        self.pendingCallWindow = pendingCallWindow
        self.waitingReplyWindow = waitingReplyWindow
        self.summaryWindow = summaryWindow
        self.maxTailBytes = maxTailBytes
        self.maxFiles = maxFiles
    }

    func fetchActiveThreads() async -> [CodexThreadDTO] {
        await Task.detached(priority: .utility) {
            self.fetchActiveThreadsSynchronously(now: Date())
        }.value
    }

    func fetchThreadSummaries(threadIDs: Set<String>) async -> [CodexThreadDTO] {
        guard !threadIDs.isEmpty else {
            return []
        }
        return await Task.detached(priority: .utility) {
            self.fetchThreadSummariesSynchronously(threadIDs: threadIDs, now: Date())
        }.value
    }

    func fetchWaitingReplyThreads(unreadThreadIDs: Set<String>) async -> [CodexThreadDTO] {
        return await Task.detached(priority: .utility) {
            self.fetchWaitingReplyThreadsSynchronously(unreadThreadIDs: unreadThreadIDs, now: Date())
        }.value
    }

    private func fetchActiveThreadsSynchronously(now: Date) -> [CodexThreadDTO] {
        recentSessionFiles(now: now).compactMap { file in
            guard
                let tail = readTailLines(from: file.url),
                let analysis = analyzeTail(tail, modifiedAt: file.modifiedAt, now: now)
            else {
                return nil
            }

            let metadata = readMetadata(from: file.url)
            let id = metadata?.id ?? threadID(from: file.url) ?? file.url.deletingPathExtension().lastPathComponent
            let preview = latestUserPreview(from: tail) ?? metadata?.preview ?? "运行中的 Codex 任务"
            return CodexThreadDTO(
                id: id,
                preview: preview,
                cwd: metadata?.cwd,
                updatedAt: file.modifiedAt.timeIntervalSince1970,
                status: .init(type: "active", activeFlags: analysis.activeFlags.isEmpty ? nil : analysis.activeFlags),
                name: shortTitle(from: preview)
            )
        }
    }

    private func fetchWaitingReplyThreadsSynchronously(unreadThreadIDs: Set<String>, now: Date) -> [CodexThreadDTO] {
        let liveThreads = waitingReplyThreads(
            from: recentConversationFiles(now: now, maxAge: waitingReplyWindow, roots: [sessionsURL]),
            unreadThreadIDs: unreadThreadIDs,
            requiresUnread: false
        )
        let archivedThreads = waitingReplyThreads(
            from: recentConversationFiles(now: now, maxAge: waitingReplyWindow, roots: [archivedSessionsURL]),
            unreadThreadIDs: unreadThreadIDs,
            requiresUnread: true
        )
        return Self.deduplicated(liveThreads + archivedThreads)
    }

    private func fetchThreadSummariesSynchronously(threadIDs: Set<String>, now: Date) -> [CodexThreadDTO] {
        recentConversationFiles(now: now, maxAge: summaryWindow, roots: [sessionsURL, archivedSessionsURL])
            .compactMap { file in
                guard let metadata = readMetadata(from: file.url) else {
                    return nil
                }
                guard threadIDs.contains(metadata.id) else {
                    return nil
                }
                let preview = readTailLines(from: file.url).flatMap(latestUserPreview) ?? metadata.preview ?? "Codex 对话"
                return CodexThreadDTO(
                    id: metadata.id,
                    preview: preview,
                    cwd: metadata.cwd,
                    updatedAt: file.modifiedAt.timeIntervalSince1970,
                    status: .init(type: "idle", activeFlags: nil),
                    name: preview == "Codex 对话" ? nil : shortTitle(from: preview)
                )
            }
    }

    private func waitingReplyThreads(
        from files: [(url: URL, modifiedAt: Date)],
        unreadThreadIDs: Set<String>,
        requiresUnread: Bool
    ) -> [CodexThreadDTO] {
        files
            .compactMap { file in
                let metadata = readMetadata(from: file.url)
                let id = metadata?.id ?? threadID(from: file.url) ?? file.url.deletingPathExtension().lastPathComponent
                guard !requiresUnread || unreadThreadIDs.contains(id) else {
                    return nil
                }
                guard
                    let tail = readTailLines(from: file.url),
                    let analysis = analyzeWaitingReplyTail(tail)
                else {
                    return nil
                }

                let preview = latestUserPreview(from: tail) ?? metadata?.preview ?? "等待回复的 Codex 任务"
                return CodexThreadDTO(
                    id: id,
                    preview: preview,
                    cwd: metadata?.cwd,
                    updatedAt: file.modifiedAt.timeIntervalSince1970,
                    status: .init(type: "idle", activeFlags: analysis.activeFlags),
                    name: shortTitle(from: preview)
                )
            }
    }

    private static func deduplicated(_ threads: [CodexThreadDTO]) -> [CodexThreadDTO] {
        var seen = Set<String>()
        var result: [CodexThreadDTO] = []
        for thread in threads {
            guard !seen.contains(thread.id) else {
                continue
            }
            seen.insert(thread.id)
            result.append(thread)
        }
        return result
    }

    private func recentSessionFiles(now: Date) -> [(url: URL, modifiedAt: Date)] {
        recentConversationFiles(now: now, maxAge: pendingCallWindow, roots: [sessionsURL])
    }

    private func recentConversationFiles(now: Date, maxAge: TimeInterval, roots: [URL]) -> [(url: URL, modifiedAt: Date)] {
        var files: [(URL, Date)] = []
        for root in roots {
            files.append(contentsOf: recentConversationFiles(now: now, maxAge: maxAge, root: root))
        }

        return files
            .sorted { $0.1 > $1.1 }
            .prefix(maxFiles)
            .map { $0 }
    }

    private func recentConversationFiles(now: Date, maxAge: TimeInterval, root: URL) -> [(url: URL, modifiedAt: Date)] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else {
                continue
            }
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate,
                now.timeIntervalSince(modifiedAt) <= maxAge
            else {
                continue
            }
            files.append((url, modifiedAt))
        }

        return files
    }

    private func readTailLines(from url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxTailBytes ? size - maxTailBytes : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd() else {
                return []
            }
            var text = String(data: data, encoding: .utf8) ?? ""
            if start > 0, let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            return text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        } catch {
            return nil
        }
    }

    private func analyzeTail(_ lines: [String], modifiedAt: Date, now: Date) -> TailAnalysis? {
        guard !lines.isEmpty else {
            return nil
        }

        var lastUserIndex = -1
        var lastTerminalIndex = -1
        var sawRuntimeEvent = false
        var pendingCalls: [String: (name: String, arguments: String)] = [:]

        for (index, line) in lines.enumerated() {
            guard let object = jsonDictionary(from: line) else {
                continue
            }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String
            let phase = payload?["phase"] as? String

            if type == "response_item" || type == "event_msg" {
                sawRuntimeEvent = true
            }

            if type == "response_item", payloadType == "message" {
                let role = payload?["role"] as? String
                if role == "user", messageText(from: payload?["content"])?.contains("<turn_aborted>") == true {
                    lastTerminalIndex = index
                    pendingCalls.removeAll()
                } else if role == "user" {
                    lastUserIndex = index
                } else if role == "assistant", phase == "final_answer" || phase == "final" {
                    lastTerminalIndex = index
                }
            }

            if type == "event_msg", payloadType == "user_message" {
                lastUserIndex = index
            }

            if type == "event_msg", payloadType == "task_complete" {
                lastTerminalIndex = index
            }

            if type == "event_msg", payloadType == "turn_aborted" {
                lastTerminalIndex = index
                pendingCalls.removeAll()
            }

            if type == "event_msg", payloadType == "agent_message", phase == "final_answer" || phase == "final" {
                lastTerminalIndex = index
            }

            if type == "response_item", payloadType == "function_call" {
                if let callID = payload?["call_id"] as? String {
                    pendingCalls[callID] = (
                        name: payload?["name"] as? String ?? "",
                        arguments: payload?["arguments"] as? String ?? ""
                    )
                }
            }

            if type == "response_item", payloadType == "function_call_output" {
                if let callID = payload?["call_id"] as? String {
                    pendingCalls.removeValue(forKey: callID)
                }
                if (payload?["output"] as? String)?.contains("aborted by user") == true {
                    lastTerminalIndex = index
                    pendingCalls.removeAll()
                }
            }
        }

        let age = now.timeIntervalSince(modifiedAt)
        let isRecent = age <= activeWindow
        let hasPendingCall = !pendingCalls.isEmpty && age <= pendingCallWindow
        let hasOpenTurn = lastUserIndex > lastTerminalIndex
        let hasNoTerminalMarker = lastTerminalIndex < 0
        guard isRecent || hasPendingCall, sawRuntimeEvent, hasOpenTurn || hasNoTerminalMarker else {
            return nil
        }

        var flags: [String] = []
        if pendingCalls.values.contains(where: { $0.name == "request_user_input" }) {
            flags.append("waitingOnUserInput")
        }
        if pendingCalls.values.contains(where: { call in
            call.name == "request_plugin_install"
                || call.arguments.contains("\"sandbox_permissions\":\"require_escalated\"")
                || call.arguments.contains("\"sandbox_permissions\": \"require_escalated\"")
        }) {
            flags.append("waitingOnApproval")
        }

        return TailAnalysis(activeFlags: flags)
    }

    private func analyzeWaitingReplyTail(_ lines: [String]) -> WaitingReplyAnalysis? {
        guard !lines.isEmpty else {
            return nil
        }

        var lastUserIndex = -1
        var lastPlanPromptIndex = -1

        for (index, line) in lines.enumerated() {
            guard let object = jsonDictionary(from: line) else {
                continue
            }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String

            if type == "response_item", payloadType == "message", payload?["role"] as? String == "user" {
                lastUserIndex = index
            }
            if type == "event_msg", payloadType == "user_message" {
                lastUserIndex = index
            }

            if type == "event_msg", payloadType == "item_completed" {
                let item = payload?["item"] as? [String: Any]
                if item?["type"] as? String == "Plan" {
                    lastPlanPromptIndex = index
                }
            }

            if type == "response_item", payloadType == "message", payload?["role"] as? String == "assistant" {
                if messageText(from: payload?["content"])?.contains("<proposed_plan>") == true {
                    lastPlanPromptIndex = index
                }
            }
        }

        guard lastPlanPromptIndex > lastUserIndex else {
            return nil
        }
        return WaitingReplyAnalysis(activeFlags: ["waitingOnUserInput"])
    }

    private func readMetadata(from url: URL) -> SessionMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let data = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var id = threadID(from: url)
        var cwd: String?
        var preview: String?

        for line in text.split(whereSeparator: \.isNewline).prefix(120) {
            guard let object = jsonDictionary(from: String(line)) else {
                continue
            }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String

            if type == "session_meta" {
                id = (payload?["id"] as? String) ?? id
                cwd = payload?["cwd"] as? String
            }

            if type == "response_item", payloadType == "message", payload?["role"] as? String == "user" {
                if let candidate = messagePreview(from: payload?["content"]) {
                    preview = candidate
                    break
                }
            }

            if type == "event_msg", payloadType == "user_message" {
                if let message = payload?["message"] as? String, let candidate = userPreview(from: message) {
                    preview = candidate
                    break
                }
            }
        }

        guard let resolvedID = id else {
            return nil
        }
        return SessionMetadata(id: resolvedID, cwd: cwd, preview: preview)
    }

    private func latestUserPreview(from lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let object = jsonDictionary(from: line) else {
                continue
            }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String

            if type == "event_msg", payloadType == "user_message" {
                if let message = payload?["message"] as? String, let candidate = userPreview(from: message) {
                    return candidate
                }
            }

            if type == "response_item", payloadType == "message", payload?["role"] as? String == "user" {
                if let candidate = messagePreview(from: payload?["content"]) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func jsonDictionary(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func threadID(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else {
            return nil
        }
        let suffix = String(name.suffix(36))
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        return suffix.range(of: pattern, options: .regularExpression) == nil ? nil : suffix
    }

    private func messageText(from content: Any?) -> String? {
        rawMessageText(from: content).flatMap(normalizedPreview)
    }

    private func messagePreview(from content: Any?) -> String? {
        rawMessageText(from: content).flatMap(userPreview)
    }

    private func rawMessageText(from content: Any?) -> String? {
        if let text = content as? String {
            return text
        }
        guard let parts = content as? [[String: Any]] else {
            return nil
        }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func userPreview(from text: String) -> String? {
        var candidate = text
        if let requestRange = candidate.range(of: "## My request for Codex:") {
            candidate = String(candidate[requestRange.upperBound...])
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isInjectedUserContext(trimmed) else {
            return nil
        }

        let cleaned = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("# Files mentioned by the user:")
                    && !line.hasPrefix("## My request for Codex:")
                    && !line.hasPrefix("<image ")
                    && !line.hasPrefix("</image")
            }
            .joined(separator: " ")
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        return normalizedPreview(cleaned)
    }

    private func isInjectedUserContext(_ text: String) -> Bool {
        text.isEmpty
            || text.hasPrefix("# AGENTS.md instructions")
            || text.hasPrefix("# Files mentioned by the user:")
            || text.hasPrefix("<environment_context>")
            || text.hasPrefix("<permissions instructions>")
            || text.hasPrefix("<app-context>")
            || text.hasPrefix("<collaboration_mode>")
            || text.hasPrefix("========= MEMORY_SUMMARY BEGINS")
            || text.contains("<turn_aborted>")
    }

    private func normalizedPreview(_ text: String) -> String? {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return nil
        }
        if collapsed.count <= 120 {
            return collapsed
        }
        return String(collapsed.prefix(120)) + "..."
    }

    private func shortTitle(from preview: String) -> String {
        if preview.count <= 36 {
            return preview
        }
        return String(preview.prefix(36)) + "..."
    }
}

private final class CodexAppServerTaskClient {
    private struct ThreadListRPCResponse: Decodable {
        struct Result: Decodable {
            let data: [CodexThreadDTO]
        }

        struct ErrorBody: Decodable {
            let message: String
        }

        let id: RequestID?
        let result: Result?
        let error: ErrorBody?
    }

    private enum RequestID: Decodable, Equatable {
        case string(String)
        case int(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .int(value)
                return
            }
            self = .string(try container.decode(String.self))
        }
    }

    func fetchThreads() async throws -> [CodexThreadDTO] {
        try await Task.detached(priority: .utility) {
            try self.fetchThreadsSynchronously()
        }.value
    }

    private func fetchThreadsSynchronously() throws -> [CodexThreadDTO] {
        var lastError: Error?
        for format in [RPCFrameFormat.contentLength, .jsonLines] {
            do {
                let output = try runProxy(format: format)
                return try parseThreads(from: output)
            } catch CodexTaskStatusClientError.proxyUnavailable(let detail) {
                throw CodexTaskStatusClientError.proxyUnavailable(detail)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CodexTaskStatusClientError.protocolMismatch("无法读取 Codex app-server 响应")
    }

    private func runProxy(format: RPCFrameFormat) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "codex app-server proxy"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(makePayload(format: format))
        inputPipe.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.12)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if timedOut, !output.isEmpty {
            return output
        }
        if timedOut {
            throw CodexTaskStatusClientError.protocolMismatch("Codex app-server 响应超时")
        }

        guard process.terminationStatus == 0 else {
            throw CodexTaskStatusClientError.proxyUnavailable(errorText)
        }
        guard !output.isEmpty else {
            throw CodexTaskStatusClientError.protocolMismatch(errorText.isEmpty ? "Codex app-server 没有返回数据" : errorText)
        }
        return output
    }

    private func makePayload(format: RPCFrameFormat) -> Data {
        let messages: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-usage",
                        "title": "Codex Usage",
                        "version": "1.0"
                    ],
                    "capabilities": [
                        "experimentalApi": false,
                        "requestAttestation": false,
                        "optOutNotificationMethods": []
                    ]
                ]
            ],
            [
                "method": "initialized"
            ],
            [
                "id": 2,
                "method": "thread/list",
                "params": [
                    "limit": 100,
                    "sortKey": "updated_at",
                    "sortDirection": "desc",
                    "archived": false
                ]
            ]
        ]

        let encoded = messages.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        switch format {
        case .jsonLines:
            var data = Data()
            for message in encoded {
                data.append(message)
                data.append(0x0A)
            }
            return data
        case .contentLength:
            var data = Data()
            for message in encoded {
                let header = "Content-Length: \(message.count)\r\n\r\n"
                data.append(Data(header.utf8))
                data.append(message)
            }
            return data
        }
    }

    private func parseThreads(from data: Data) throws -> [CodexThreadDTO] {
        let messages = Self.decodeFrames(from: data)
        var serverError: String?

        for message in messages {
            guard let response = try? JSONDecoder().decode(ThreadListRPCResponse.self, from: message) else {
                continue
            }
            if let error = response.error {
                serverError = error.message
            }
            if response.id == .int(2) || response.id == .string("2") {
                if let error = response.error {
                    throw CodexTaskStatusClientError.appServerError(error.message)
                }
                if let result = response.result {
                    return result.data
                }
            }
        }

        if let serverError {
            throw CodexTaskStatusClientError.appServerError(serverError)
        }
        throw CodexTaskStatusClientError.protocolMismatch("Codex app-server 响应中没有 thread/list 结果")
    }

    static func decodeFrames(from data: Data) -> [Data] {
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.contains("Content-Length:") {
            return decodeContentLengthFrames(from: data)
        }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Data(trimmed.utf8)
            }
    }

    private static func decodeContentLengthFrames(from data: Data) -> [Data] {
        var frames: [Data] = []
        var cursor = data.startIndex

        while cursor < data.endIndex {
            guard let headerEnd = data[cursor...].firstRange(of: Data("\r\n\r\n".utf8)) else {
                break
            }
            let headerData = data[cursor..<headerEnd.lowerBound]
            guard
                let header = String(data: headerData, encoding: .utf8),
                let lengthLine = header
                    .split(separator: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                let length = Int(lengthLine.split(separator: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces))
            else {
                break
            }

            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.endIndex else {
                break
            }
            frames.append(data[bodyStart..<bodyEnd])
            cursor = bodyEnd
        }

        return frames
    }
}

@MainActor
final class TaskStatusStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case available
        case unavailable(String)
    }

    @Published private(set) var snapshot: TaskStatusSnapshot = .empty
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var animationFrame = 0

    private let client = CodexTaskStatusClient()
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var isRefreshing = false

    func startPolling() {
        guard pollTimer == nil else {
            return
        }
        refreshNow()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        animationTimer?.invalidate()
        animationTimer = nil
    }

    func refreshNow() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        if case .idle = state {
            state = .loading
        }

        Task {
            let next = await client.fetch()
            snapshot = next
            switch next.sourceState {
            case .idle:
                state = .idle
            case .available:
                state = .available
            case .unavailable(let message):
                state = .unavailable(message)
            }
            isRefreshing = false
            updateAnimationTimer()
        }
    }

    var lastUpdatedText: String {
        if case .loading = state {
            return "正在读取任务状态"
        }
        guard let refreshedAt = snapshot.refreshedAt else {
            return stateText
        }
        let seconds = Int(Date().timeIntervalSince(refreshedAt))
        if seconds < 60 {
            return stateText
        }
        return "\(seconds / 60) 分钟前读取任务"
    }

    var stateText: String {
        switch state {
        case .idle:
            return "等待读取任务"
        case .loading:
            return "正在读取任务"
        case .available:
            return snapshot.summaryText
        case .unavailable:
            return snapshot.hasVisibleStatus ? snapshot.summaryText : "任务状态不可读"
        }
    }

    private func updateAnimationTimer() {
        if snapshot.hasVisibleStatus {
            guard animationTimer == nil else {
                return
            }
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.animationFrame = ((self?.animationFrame ?? 0) + 1) % 12
                }
            }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            animationFrame = 0
        }
    }
}
