import Foundation

enum TaskStatusKind: String, CaseIterable, Sendable {
    case error
    case needsConfirmation
    case needsReply
    case running
    case completedUnread
    case idle
    case unknown

    static let menuOrder: [TaskStatusKind] = [
        .error,
        .needsConfirmation,
        .needsReply,
        .running,
        .completedUnread
    ]

    var title: String {
        switch self {
        case .error:
            return "错误"
        case .needsConfirmation:
            return "需要确认"
        case .needsReply:
            return "需要回复"
        case .running:
            return "运行中"
        case .completedUnread:
            return "完成未读"
        case .idle:
            return "空闲"
        case .unknown:
            return "未知"
        }
    }

    var shortTitle: String {
        switch self {
        case .error:
            return "错"
        case .needsConfirmation:
            return "确认"
        case .needsReply:
            return "回复"
        case .running:
            return "运行"
        case .completedUnread:
            return "完成"
        case .idle:
            return "空闲"
        case .unknown:
            return "未知"
        }
    }
}

enum TaskStatusSourceState: Equatable, Sendable {
    case idle
    case available
    case unavailable(String)

    var message: String {
        switch self {
        case .idle:
            return "等待读取 Codex 任务"
        case .available:
            return "任务状态已同步"
        case .unavailable(let detail):
            return detail
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self {
            return true
        }
        return false
    }
}

struct TaskRecord: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let cwd: String?
    let updatedAt: Date?
    let kind: TaskStatusKind

    var displaySubtitle: String {
        if !subtitle.isEmpty {
            return subtitle
        }
        if let cwd, !cwd.isEmpty {
            return cwd
        }
        return "Codex 对话"
    }
}

struct TaskStatusSnapshot: Equatable, Sendable {
    let records: [TaskRecord]
    let unreadThreadIDs: Set<String>
    let refreshedAt: Date?
    let sourceState: TaskStatusSourceState

    static let empty = TaskStatusSnapshot(
        records: [],
        unreadThreadIDs: [],
        refreshedAt: nil,
        sourceState: .idle
    )

    var menuSegments: [(kind: TaskStatusKind, count: Int)] {
        TaskStatusKind.menuOrder.compactMap { kind in
            let count = count(for: kind)
            return count > 0 ? (kind, count) : nil
        }
    }

    var visibleRecords: [TaskRecord] {
        records.filter { TaskStatusKind.menuOrder.contains($0.kind) }
    }

    var hasVisibleStatus: Bool {
        !menuSegments.isEmpty
    }

    var totalVisibleCount: Int {
        menuSegments.reduce(0) { $0 + $1.count }
    }

    func count(for kind: TaskStatusKind) -> Int {
        records.filter { $0.kind == kind }.count
    }

    var summaryText: String {
        let parts = menuSegments.map { "\($0.kind.title) \($0.count)" }
        if parts.isEmpty {
            return sourceState.isUnavailable ? "任务状态不可读" : "暂无运行或未读完成任务"
        }
        return parts.joined(separator: "，")
    }

    var tooltipText: String {
        "Codex 任务：\(summaryText)"
    }
}

struct CodexThreadDTO: Decodable, Equatable, Sendable {
    struct RuntimeStatus: Decodable, Equatable, Sendable {
        let type: String
        let activeFlags: [String]?
    }

    let id: String
    let preview: String
    let cwd: String?
    let updatedAt: Double?
    let status: RuntimeStatus
    let name: String?

    init(
        id: String,
        preview: String,
        cwd: String?,
        updatedAt: Double?,
        status: RuntimeStatus,
        name: String?
    ) {
        self.id = id
        self.preview = preview
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.status = status
        self.name = name
    }
}

enum TaskStatusMapper {
    static func makeSnapshot(
        threads: [CodexThreadDTO],
        unreadThreadIDs: Set<String>,
        refreshedAt: Date,
        sourceState: TaskStatusSourceState
    ) -> TaskStatusSnapshot {
        var records: [TaskRecord] = []
        var representedThreadIDs = Set<String>()

        for thread in threads {
            representedThreadIDs.insert(thread.id)
            let kind = kind(for: thread, unreadThreadIDs: unreadThreadIDs)
            guard TaskStatusKind.menuOrder.contains(kind) else {
                continue
            }
            records.append(record(from: thread, kind: kind))
        }

        for id in unreadThreadIDs.subtracting(representedThreadIDs) {
            records.append(
                TaskRecord(
                    id: id,
                    title: "完成未读任务",
                    subtitle: String(id.prefix(8)),
                    cwd: nil,
                    updatedAt: nil,
                    kind: .completedUnread
                )
            )
        }

        return TaskStatusSnapshot(
            records: sorted(records),
            unreadThreadIDs: unreadThreadIDs,
            refreshedAt: refreshedAt,
            sourceState: sourceState
        )
    }

    static func kind(for thread: CodexThreadDTO, unreadThreadIDs: Set<String>) -> TaskStatusKind {
        let flags = Set(thread.status.activeFlags ?? [])
        if flags.contains("waitingOnApproval") {
            return .needsConfirmation
        }
        if flags.contains("waitingOnUserInput") {
            return .needsReply
        }

        switch thread.status.type {
        case "active":
            return .running
        case "systemError":
            return .error
        case "idle", "notLoaded":
            return unreadThreadIDs.contains(thread.id) ? .completedUnread : .idle
        default:
            return unreadThreadIDs.contains(thread.id) ? .completedUnread : .unknown
        }
    }

    private static func record(from thread: CodexThreadDTO, kind: TaskStatusKind) -> TaskRecord {
        let title = preferredTitle(for: thread)
        let subtitle = thread.cwd.map(shortPath) ?? thread.preview
        return TaskRecord(
            id: thread.id,
            title: title,
            subtitle: subtitle,
            cwd: thread.cwd,
            updatedAt: thread.updatedAt.map { Date(timeIntervalSince1970: $0) },
            kind: kind
        )
    }

    private static func preferredTitle(for thread: CodexThreadDTO) -> String {
        if let name = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let preview = thread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            return preview
        }
        return "Codex 任务"
    }

    private static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func sorted(_ records: [TaskRecord]) -> [TaskRecord] {
        let order = Dictionary(uniqueKeysWithValues: TaskStatusKind.menuOrder.enumerated().map { ($0.element, $0.offset) })
        return records.sorted { lhs, rhs in
            let leftOrder = order[lhs.kind] ?? Int.max
            let rightOrder = order[rhs.kind] ?? Int.max
            if leftOrder != rightOrder {
                return leftOrder < rightOrder
            }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }
}
