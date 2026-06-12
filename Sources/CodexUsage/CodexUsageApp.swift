import AppKit
import Combine
import Foundation
import SwiftUI

private enum SingleInstanceGuard {
    private static let lockPath = "/tmp/com.lifeibiji.codexusage.lock"
    private static var fileDescriptor: Int32 = -1

    static func acquire() -> Bool {
        fileDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            return true
        }
        return flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0
    }
}

private enum UsageError: LocalizedError {
    case missingCredentials
    case unsupportedAuthMode
    case malformedCredentials(String)
    case tokenStale
    case badResponse(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "未找到 Codex 登录信息"
        case .unsupportedAuthMode:
            return "Codex 不是 ChatGPT 登录模式"
        case .malformedCredentials(let detail):
            return detail
        case .tokenStale:
            return "Codex 登录可能已过期"
        case .badResponse(let status, let body):
            return "用量接口返回 HTTP \(status)：\(body)"
        case .invalidResponse:
            return "用量接口没有返回额度窗口"
        }
    }
}

private struct CodexAuth: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }

    let authMode: String?
    let tokens: Tokens?
    let lastRefresh: String?

    private enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

private struct CodexCredentials {
    let accessToken: String
    let accountId: String?
    let isPossiblyStale: Bool
}

private struct UsageAPIResponse: Decodable {
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        private enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAt: Int?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
    }

    let rateLimit: RateLimit?

    private enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

struct UsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let remainingPercent: Double
    let usedPercent: Double
    let resetAt: Date?
    let windowSeconds: Int?

    var remainingInt: Int {
        Int(remainingPercent.rounded())
    }

    var resetText: String {
        guard let resetAt else {
            return "暂无重置时间"
        }
        let interval = resetAt.timeIntervalSinceNow
        if interval <= 0 {
            return "即将重置"
        }
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "\(minutes) 分钟后重置"
        }
        let hours = minutes / 60
        let restMinutes = minutes % 60
        if hours < 24 {
            return "\(hours) 小时 \(restMinutes) 分钟后重置"
        }
        let days = hours / 24
        let restHours = hours % 24
        return "\(days) 天 \(restHours) 小时后重置"
    }

    var resetDetailText: String {
        guard let resetAt else {
            return "无时间戳"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "E HH:mm"
        return formatter.string(from: resetAt)
    }
}

struct ActivitySnapshot: Equatable, Sendable {
    let buckets: [Int]
    let totalTokens: Int
    let day: ActivityDay

    var hasData: Bool {
        totalTokens > 0 && buckets.contains { $0 > 0 }
    }

    var peak: Int {
        max(buckets.max() ?? 0, 1)
    }
}

enum ActivityDay: String, Equatable, Hashable, Sendable {
    case today
    case yesterday

    var title: String {
        switch self {
        case .today:
            return "今日消耗"
        case .yesterday:
            return "昨日消耗"
        }
    }

    var emptyText: String {
        switch self {
        case .today:
            return "今天暂无本机 Codex 活动"
        case .yesterday:
            return "昨天暂无本机 Codex 活动"
        }
    }

    var summaryPrefix: String {
        switch self {
        case .today:
            return "今天"
        case .yesterday:
            return "昨天"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Equatable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system:
            return "跟随"
        case .light:
            return "日间"
        case .dark:
            return "夜间"
        }
    }

    var icon: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }
}

private enum DashboardSection: String, CaseIterable {
    case usage
    case tasks

    var title: String {
        switch self {
        case .usage:
            return "用量"
        case .tasks:
            return "任务"
        }
    }

    var icon: String {
        switch self {
        case .usage:
            return "chart.bar.fill"
        case .tasks:
            return "figure.run"
        }
    }
}

private struct AppPalette {
    let isDark: Bool

    var visualMaterial: NSVisualEffectView.Material {
        isDark ? .hudWindow : .popover
    }

    var backgroundStart: Color {
        isDark ? Color(red: 0.06, green: 0.07, blue: 0.08).opacity(0.90) : Color(red: 0.97, green: 0.98, blue: 0.98).opacity(0.94)
    }

    var backgroundEnd: Color {
        isDark ? Color(red: 0.08, green: 0.10, blue: 0.11).opacity(0.94) : Color(red: 0.91, green: 0.94, blue: 0.95).opacity(0.94)
    }

    var primaryText: Color {
        isDark ? .white : Color(red: 0.08, green: 0.10, blue: 0.12)
    }

    var secondaryText: Color {
        isDark ? Color.white.opacity(0.62) : Color.black.opacity(0.58)
    }

    var mutedText: Color {
        isDark ? Color.white.opacity(0.42) : Color.black.opacity(0.40)
    }

    var faintText: Color {
        isDark ? Color.white.opacity(0.32) : Color.black.opacity(0.32)
    }

    var panel: Color {
        isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.72)
    }

    var panelSoft: Color {
        isDark ? Color.white.opacity(0.055) : Color.white.opacity(0.54)
    }

    var control: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.055)
    }

    var border: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    var divider: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    var barEmpty: Color {
        isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.12)
    }
}

private final class LocalUsageActivityClient {
    private struct SessionEvent: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable {
                struct TokenUsage: Decodable {
                    let totalTokens: Int?

                    private enum CodingKeys: String, CodingKey {
                        case totalTokens = "total_tokens"
                    }
                }

                let lastTokenUsage: TokenUsage?

                private enum CodingKeys: String, CodingKey {
                    case lastTokenUsage = "last_token_usage"
                }
            }

            let type: String?
            let info: Info?
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private let bucketCount = 24

    func loadSnapshots(days: [ActivityDay]) -> [ActivityDay: ActivitySnapshot] {
        Dictionary(uniqueKeysWithValues: days.map { ($0, loadSnapshot(day: $0)) })
    }

    private func loadSnapshot(day: ActivityDay) -> ActivitySnapshot {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let start = day == .today ? todayStart : calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        var buckets = Array(repeating: 0, count: bucketCount)
        var total = 0

        for fileURL in sessionFiles(from: start, to: end) {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                continue
            }
            defer { try? handle.close() }

            let data = handle.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                continue
            }

            for line in text.split(separator: "\n") {
                guard let eventData = line.data(using: .utf8),
                      let event = try? JSONDecoder().decode(SessionEvent.self, from: eventData),
                      event.type == "event_msg",
                      event.payload?.type == "token_count",
                      let tokenCount = event.payload?.info?.lastTokenUsage?.totalTokens,
                      tokenCount > 0,
                      let timestamp = event.timestamp,
                      let date = Self.parseDate(timestamp),
                      date >= start,
                      date < end
                else {
                    continue
                }

                let hour = calendar.component(.hour, from: date)
                let progress = Double(hour) / Double(bucketCount)
                let index = min(max(Int(progress * Double(bucketCount)), 0), bucketCount - 1)
                buckets[index] += tokenCount
                total += tokenCount
            }
        }

        return ActivitySnapshot(buckets: buckets, totalTokens: total, day: day)
    }

    private func sessionFiles(from start: Date, to end: Date) -> [URL] {
        let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }

        let paddedStart = start.addingTimeInterval(-24 * 60 * 60)
        let paddedEnd = end.addingTimeInterval(24 * 60 * 60)
        let matching = files.filter { $0.modified >= paddedStart && $0.modified <= paddedEnd }
        let source = matching.isEmpty ? files : matching

        return source
            .sorted { $0.modified > $1.modified }
            .prefix(300)
            .map(\.url)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private final class CodexUsageClient {
    func fetch() async throws -> [UsageWindow] {
        let credentials = try readCredentials()
        if credentials.isPossiblyStale {
            throw UsageError.tokenStale
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageError.badResponse(http.statusCode, String(body.prefix(240)))
        }

        let decoded = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        let windows = [
            decoded.rateLimit?.primaryWindow,
            decoded.rateLimit?.secondaryWindow
        ]
        .compactMap { $0 }
        .compactMap(makeUsageWindow)
        .sorted { lhs, rhs in
            let left = lhs.windowSeconds ?? Int.max
            let right = rhs.windowSeconds ?? Int.max
            return left < right
        }

        guard !windows.isEmpty else {
            throw UsageError.invalidResponse
        }
        return windows
    }

    private func makeUsageWindow(_ window: UsageAPIResponse.Window) -> UsageWindow? {
        guard let used = window.usedPercent else {
            return nil
        }
        let seconds = window.limitWindowSeconds
        let label = Self.label(for: seconds)
        let id = Self.id(for: seconds)
        let resetAt = window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let clampedUsed = min(max(used, 0), 100)
        return UsageWindow(
            id: id,
            label: label,
            remainingPercent: 100 - clampedUsed,
            usedPercent: clampedUsed,
            resetAt: resetAt,
            windowSeconds: seconds
        )
    }

    private func readCredentials() throws -> CodexCredentials {
        if let fromKeychain = readCredentialsFromKeychain() {
            return try parseCredentials(fromKeychain)
        }

        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw UsageError.missingCredentials
        }
        let data = try Data(contentsOf: authURL)
        return try parseCredentials(data)
    }

    private func readCredentialsFromKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Codex Auth", "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    private func parseCredentials(_ data: Data) throws -> CodexCredentials {
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        guard auth.authMode == "chatgpt" else {
            throw UsageError.unsupportedAuthMode
        }
        guard let token = auth.tokens?.accessToken, !token.isEmpty else {
            throw UsageError.malformedCredentials("缺少 Codex access token")
        }
        return CodexCredentials(
            accessToken: token,
            accountId: auth.tokens?.accountId,
            isPossiblyStale: isTokenPossiblyStale(auth.lastRefresh)
        )
    }

    private func isTokenPossiblyStale(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else {
            return false
        }
        return Date().timeIntervalSince(date) > 8 * 24 * 60 * 60
    }

    private static func id(for seconds: Int?) -> String {
        switch seconds {
        case 18_000:
            return "five_hour"
        case 604_800:
            return "seven_day"
        case .some(let value):
            return "window_\(value)"
        case .none:
            return "unknown"
        }
    }

    private static func label(for seconds: Int?) -> String {
        switch seconds {
        case 18_000:
            return "5h"
        case 604_800:
            return "7d"
        case .some(let value):
            let hours = value / 3_600
            if hours >= 24 {
                return "\(hours / 24)d"
            }
            return "\(max(hours, 1))h"
        case .none:
            return "额度"
        }
    }
}

private enum LaunchAtLoginManager {
    private static let label = "com.lifeibiji.codexusage"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        guard let executablePath = Bundle.main.executablePath else {
            throw UsageError.malformedCredentials("无法定位 App 可执行文件")
        }
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private static func uninstall() throws {
        guard isEnabled() else {
            return
        }
        try FileManager.default.removeItem(at: plistURL)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var windows: [UsageWindow] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var activitySnapshot = ActivitySnapshot(buckets: [], totalTokens: 0, day: .today)
    @Published private(set) var activityDay: ActivityDay = .today
    @Published private(set) var appearanceMode: AppearanceMode = AppearanceMode(
        rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
    ) ?? .system
    @Published private(set) var launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
    @Published private(set) var launchAtLoginError: String?

    private let client = CodexUsageClient()
    private var activitySnapshots: [ActivityDay: ActivitySnapshot] = [:]
    private var isRefreshing = false

    var fiveHour: UsageWindow? {
        windows.first { $0.id == "five_hour" } ?? windows.first
    }

    var sevenDay: UsageWindow? {
        windows.first { $0.id == "seven_day" } ?? windows.dropFirst().first
    }

    var lowestRemaining: Double? {
        windows.map(\.remainingPercent).min()
    }

    var statusTitle: String {
        switch state {
        case .loading where !windows.isEmpty:
            return usageStatusTitle
        case .idle, .loading:
            return "Codex ..."
        case .failed:
            return "Codex 检查"
        case .loaded:
            return usageStatusTitle
        }
    }

    var statusTone: StatusTone {
        switch state {
        case .loaded:
            return usageStatusTone
        case .loading:
            guard !windows.isEmpty else {
                return .loading
            }
            return usageStatusTone
        case .failed:
            return .offline
        case .idle:
            return .loading
        }
    }

    private var usageStatusTitle: String {
        let first = fiveHour.map { "5h \($0.remainingInt)%" }
        let second = sevenDay.map { "7d \($0.remainingInt)%" }
        let compact = [first, second].compactMap { $0 }.joined(separator: "  ")
        guard !compact.isEmpty else {
            return "Codex 检查"
        }
        if let lowest = lowestRemaining, lowest <= 10 {
            return "低 " + compact
        }
        return compact
    }

    private var usageStatusTone: StatusTone {
        guard let lowest = lowestRemaining else {
            return .offline
        }
        if lowest <= 10 {
            return .critical
        }
        if lowest <= 25 {
            return .warning
        }
        return .healthy
    }

    func refresh() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        state = .loading
        Task {
            defer {
                isRefreshing = false
            }
            do {
                let next = try await client.fetch()
                let snapshots = await Task.detached(priority: .utility) {
                    LocalUsageActivityClient().loadSnapshots(days: [.today, .yesterday])
                }.value
                windows = next
                activitySnapshots = snapshots
                activitySnapshot = snapshots[activityDay] ?? snapshots[.today] ?? ActivitySnapshot(buckets: [], totalTokens: 0, day: activityDay)
                lastUpdated = Date()
                state = .loaded
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                state = .failed(message)
            }
        }
    }

    func showActivity(day: ActivityDay) {
        guard activityDay != day else {
            return
        }
        activityDay = day
        if let cached = activitySnapshots[day] {
            activitySnapshot = cached
            return
        }
        activitySnapshot = ActivitySnapshot(buckets: [], totalTokens: 0, day: day)
        Task {
            let snapshots = await Task.detached(priority: .utility) {
                LocalUsageActivityClient().loadSnapshots(days: [.today, .yesterday])
            }.value
            activitySnapshots = snapshots
            activitySnapshot = snapshots[day] ?? ActivitySnapshot(buckets: [], totalTokens: 0, day: day)
        }
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
    }

    func toggleLaunchAtLogin() {
        let next = !launchAtLoginEnabled
        do {
            try LaunchAtLoginManager.setEnabled(next)
            launchAtLoginEnabled = next
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
        }
    }
}

enum StatusTone {
    case healthy
    case warning
    case critical
    case offline
    case loading

    var nsColor: NSColor {
        switch self {
        case .healthy:
            return NSColor(calibratedRed: 0.36, green: 0.86, blue: 0.58, alpha: 1)
        case .warning:
            return NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.28, alpha: 1)
        case .critical:
            return NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.32, alpha: 1)
        case .offline:
            return NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.70, alpha: 1)
        case .loading:
            return NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.95, alpha: 1)
        }
    }

    var swiftColor: Color {
        Color(nsColor)
    }

    var text: String {
        switch self {
        case .healthy:
            return "充足"
        case .warning:
            return "留意"
        case .critical:
            return "偏低"
        case .offline:
            return "离线"
        case .loading:
            return "同步中"
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private let taskStore = TaskStatusStore()
    private var statusItem: NSStatusItem!
    private var quotaStatusItem: NSStatusItem!
    private var popover: NSPopover!
    private var taskPickerPopover: NSPopover!
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleTaskStatusItemClick(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }

        quotaStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = quotaStatusItem.button {
            button.target = self
            button.action = #selector(handleQuotaStatusItemClick(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .noImage
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 548, height: 640)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                store: store,
                taskStore: taskStore,
                refresh: { [weak self] in self?.store.refresh() },
                quit: { NSApp.terminate(nil) }
            )
        )

        taskPickerPopover = NSPopover()
        taskPickerPopover.behavior = .transient
        taskPickerPopover.delegate = self

        observeStore()
        updateStatusItem()
        store.refresh()
        taskStore.startPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        taskStore.stopPolling()
    }

    private func observeStore() {
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
        .store(in: &cancellables)

        taskStore.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
        .store(in: &cancellables)
    }

    private func updateStatusItem() {
        if let button = statusItem.button {
            button.image = TaskStatusStripIcon.make(snapshot: taskStore.snapshot, frame: taskStore.animationFrame)
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = taskStore.snapshot.tooltipText
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        if let button = quotaStatusItem.button {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: store.statusTitle, attributes: attributes)
            button.toolTip = "Codex 用量：\(store.statusTone.text)"
        }
    }

    @objc private func handleTaskStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let shouldOpenFullPanel = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.option) == true
        if shouldOpenFullPanel {
            showFullPopoverFromQuota()
            return
        }

        let records = taskStore.snapshot.visibleRecords
        switch records.count {
        case 0:
            taskStore.refreshNow()
        case 1:
            openTask(records[0])
        default:
            toggleTaskPicker(records: records, relativeTo: sender)
        }
    }

    @objc private func handleQuotaStatusItemClick(_ sender: NSStatusBarButton) {
        toggleFullPopover(relativeTo: sender)
    }

    private func showFullPopoverFromQuota() {
        if let button = quotaStatusItem.button ?? statusItem.button {
            showFullPopover(relativeTo: button)
        }
    }

    private func toggleFullPopover(relativeTo button: NSStatusBarButton) {
        taskPickerPopover.performClose(nil)
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showFullPopover(relativeTo: button)
        }
    }

    private func showFullPopover(relativeTo button: NSStatusBarButton) {
        taskPickerPopover.performClose(nil)
        guard !popover.isShown else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleTaskPicker(records: [TaskRecord], relativeTo button: NSStatusBarButton) {
        popover.performClose(nil)
        if taskPickerPopover.isShown {
            taskPickerPopover.performClose(nil)
            return
        }

        let height = min(CGFloat(records.count) * 76 + 84, 420)
        taskPickerPopover.contentSize = NSSize(width: 360, height: height)
        taskPickerPopover.contentViewController = NSHostingController(
            rootView: TaskPickerView(
                records: records,
                height: height,
                openTask: { [weak self] record in
                    self?.openTask(record)
                },
                openFullPanel: { [weak self] in
                    guard let self else { return }
                    self.taskPickerPopover.performClose(nil)
                    self.showFullPopoverFromQuota()
                }
            )
        )
        taskPickerPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openTask(_ record: TaskRecord) {
        popover.performClose(nil)
        taskPickerPopover.performClose(nil)
        openCodexThread(threadID: record.id)
    }

    private func openCodexThread(threadID: String) {
        guard
            let encodedID = threadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "codex://threads/\(encodedID)")
        else {
            openCodexApp()
            return
        }

        if !NSWorkspace.shared.open(url) {
            openCodexApp()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.taskStore.refreshNow()
        }
    }

    private func openCodexApp() {
        let codexApp = URL(fileURLWithPath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: codexApp.path) {
            NSWorkspace.shared.open(codexApp)
        }
    }

    @objc private func togglePopover() {
        guard let button = quotaStatusItem.button ?? statusItem.button else {
            return
        }
        toggleFullPopover(relativeTo: button)
    }

}

private struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var taskStore: TaskStatusStore
    let refresh: () -> Void
    let quit: () -> Void
    @State private var selectedSection: DashboardSection = .usage
    @Environment(\.colorScheme) private var systemScheme

    private var isDarkMode: Bool {
        switch store.appearanceMode {
        case .system:
            return systemScheme == .dark
        case .light:
            return false
        case .dark:
            return true
        }
    }

    private var palette: AppPalette {
        AppPalette(isDark: isDarkMode)
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: palette.visualMaterial, blendingMode: .behindWindow)
                .ignoresSafeArea()
            LinearGradient(
                colors: [
                    palette.backgroundStart,
                    palette.backgroundEnd
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                sectionSwitch
                Divider().overlay(palette.divider)
                content
                Divider().overlay(palette.divider)
                footer
            }
            .foregroundStyle(palette.primaryText)
        }
        .frame(width: 548, height: 640)
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(palette.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(store.statusTone.swiftColor.opacity(0.55), lineWidth: 1)
                    )
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(store.statusTone.swiftColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 工作台")
                    .font(.system(size: 15, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()

            HStack(spacing: 8) {
                StatusBadge(tone: store.statusTone, palette: palette)
                IconButton(systemName: "arrow.clockwise", palette: palette, action: refreshCurrentSection)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var sectionSwitch: some View {
        HStack(spacing: 6) {
            ForEach(DashboardSection.allCases, id: \.rawValue) { section in
                Button {
                    selectedSection = section
                    if section == .tasks {
                        taskStore.refreshNow()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(section == selectedSection ? Color.black.opacity(0.84) : palette.secondaryText)
                    .background(
                        section == selectedSection
                            ? Color(red: 0.36, green: 0.86, blue: 0.58)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .padding(4)
        .background(palette.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
        .padding(.horizontal, 34)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .usage:
            usageContent
        case .tasks:
            tasksContent
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        switch store.state {
        case .idle:
            usageLoading
        case .loading:
            if store.windows.isEmpty {
                usageLoading
            } else {
                usageSnapshot
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(red: 0.96, green: 0.72, blue: 0.28))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂时无法获取用量")
                            .font(.system(size: 18, weight: .semibold))
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(4)
                    }
                }
                ActionRow(systemName: "arrow.clockwise", title: "重新检查", palette: palette, action: refresh)
                Spacer()
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
        case .loaded:
            usageSnapshot
        }
    }

    private var usageLoading: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("正在检查 Codex 额度")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var usageSnapshot: some View {
        VStack(spacing: 16) {
            quotaGrid
            rhythm
            privacyNote
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
    }

    private var tasksContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            taskOverview
            taskStatusNote
            taskList
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .onAppear {
            taskStore.refreshNow()
        }
    }

    private var taskOverview: some View {
        HStack(spacing: 8) {
            let visibleKinds = TaskStatusKind.menuOrder.filter { taskStore.snapshot.count(for: $0) > 0 }
            if visibleKinds.isEmpty {
                TaskStatBlock(
                    title: "空闲",
                    value: "0",
                    kind: .idle,
                    palette: palette
                )
            } else {
                ForEach(visibleKinds, id: \.rawValue) { kind in
                    TaskStatBlock(
                        title: kind.shortTitle,
                        value: "\(taskStore.snapshot.count(for: kind))",
                        kind: kind,
                        palette: palette
                    )
                }
            }
        }
    }

    private var taskStatusNote: some View {
        HStack(spacing: 9) {
            Image(systemName: taskStatusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(taskStatusColor)
            Text(taskStore.stateText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
            Spacer()
            if let refreshedAt = taskStore.snapshot.refreshedAt {
                Text(relativeTimeText(refreshedAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.mutedText)
            }
        }
        .padding(11)
        .background(palette.panelSoft, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
    }

    private var taskList: some View {
        Group {
            if taskStore.snapshot.visibleRecords.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(palette.mutedText)
                    Text(taskStore.snapshot.sourceState.isUnavailable ? "暂时读不到运行状态" : "没有需要盯着的任务")
                        .font(.system(size: 14, weight: .semibold))
                    Text(taskStore.snapshot.sourceState.isUnavailable ? "Codex app-server 不在线时，额度显示不会受影响。" : "运行、完成未读、确认或回复请求出现时会在这里列出来。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    ActionRow(systemName: "terminal.fill", title: "打开 Codex", palette: palette) {
                        openCodexApp()
                    }
                    .frame(width: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(taskStore.snapshot.visibleRecords) { task in
                            TaskRow(record: task, palette: palette)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var quotaGrid: some View {
        HStack(spacing: 12) {
            if let fiveHour = store.fiveHour {
                QuotaBlock(window: fiveHour, accent: Color(red: 0.36, green: 0.86, blue: 0.58), palette: palette)
            }
            if let sevenDay = store.sevenDay {
                QuotaBlock(window: sevenDay, accent: Color(red: 0.42, green: 0.78, blue: 0.95), palette: palette)
            }
        }
    }

    private var capacityAdvice: some View {
        HStack(spacing: 12) {
            Image(systemName: adviceIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.statusTone.swiftColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(adviceTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(adviceSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var rhythm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.activityDay.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(activitySummaryText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.mutedText)
            }

            HStack(spacing: 6) {
                ActivityDayButton(title: "今日", isSelected: store.activityDay == .today, palette: palette) {
                    store.showActivity(day: .today)
                }
                ActivityDayButton(title: "昨日", isSelected: store.activityDay == .yesterday, palette: palette) {
                    store.showActivity(day: .yesterday)
                }
                Spacer()
                Text("0-23 点")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.mutedText)
            }

            if store.activitySnapshot.hasData {
                VStack(spacing: 7) {
                    activityBarRow(range: 0..<12)
                    activityBarRow(range: 12..<24)
                }
                .frame(height: 64)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.mutedText)
                    Text(store.activityDay.emptyText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                }
                .frame(height: 64)
            }
        }
        .padding(12)
        .background(palette.panelSoft, in: RoundedRectangle(cornerRadius: 8))
    }

    private func activityBarRow(range: Range<Int>) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(range), id: \.self) { index in
                let value = index < store.activitySnapshot.buckets.count ? store.activitySnapshot.buckets[index] : 0
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(activityBarColor(index: index, value: value))
                        .frame(width: 20, height: activityBarHeight(value))
                    if index == range.lowerBound || index == range.upperBound - 1 {
                        Text("\(index)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(palette.faintText)
                            .frame(height: 8)
                    } else {
                        Color.clear.frame(width: 20, height: 8)
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.58))
            Text("只读查询；Token 和会话日志只留在本机。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            AppearanceModePicker(mode: store.appearanceMode, palette: palette) { mode in
                store.setAppearanceMode(mode)
            }
            LaunchAtLoginButton(isEnabled: store.launchAtLoginEnabled, palette: palette) {
                store.toggleLaunchAtLogin()
            }
            Spacer()
            QuitButton(palette: palette, action: quit)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 16)
    }

    private var headerSubtitle: String {
        switch selectedSection {
        case .usage:
            return lastUpdatedText
        case .tasks:
            return taskStore.lastUpdatedText
        }
    }

    private func refreshCurrentSection() {
        switch selectedSection {
        case .usage:
            refresh()
        case .tasks:
            taskStore.refreshNow()
        }
    }

    private var lastUpdatedText: String {
        if case .loading = store.state {
            return "正在同步"
        }
        guard let lastUpdated = store.lastUpdated else {
            return "等待首次同步"
        }
        let seconds = Int(Date().timeIntervalSince(lastUpdated))
        if seconds < 60 {
            return "刚刚更新"
        }
        return "\(seconds / 60) 分钟前更新"
    }

    private var adviceIcon: String {
        switch store.statusTone {
        case .healthy:
            return "checkmark.seal.fill"
        case .warning:
            return "clock.badge.exclamationmark"
        case .critical:
            return "bolt.trianglebadge.exclamationmark.fill"
        case .offline:
            return "wifi.slash"
        case .loading:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var adviceTitle: String {
        switch store.statusTone {
        case .healthy:
            return "适合开始长任务"
        case .warning:
            return "建议保持任务聚焦"
        case .critical:
            return "额度偏低，留给关键任务"
        case .offline:
            return "开始前先检查登录"
        case .loading:
            return "正在刷新额度"
        }
    }

    private var adviceSubtitle: String {
        if let lowest = store.lowestRemaining {
            return "最低剩余额度：\(Int(lowest.rounded()))%"
        }
        return "还没有实时额度快照"
    }

    private var activitySummaryText: String {
        guard store.activitySnapshot.hasData else {
            return store.activityDay.summaryPrefix
        }
        return "\(store.activityDay.summaryPrefix) \(formatTokenCount(store.activitySnapshot.totalTokens)) tokens"
    }

    private func activityBarHeight(_ value: Int) -> CGFloat {
        guard value > 0 else {
            return 4
        }
        let ratio = Double(value) / Double(store.activitySnapshot.peak)
        return CGFloat(5 + ratio * 22)
    }

    private func activityBarColor(index: Int, value: Int) -> Color {
        guard value > 0 else {
            return palette.barEmpty
        }
        if value == store.activitySnapshot.peak {
            return Color(red: 0.42, green: 0.78, blue: 0.95)
        }
        return index % 2 == 0 ? Color(red: 0.36, green: 0.86, blue: 0.58) : palette.secondaryText.opacity(0.58)
    }

    private func formatTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private var taskStatusIcon: String {
        switch taskStore.state {
        case .idle, .loading:
            return "arrow.triangle.2.circlepath"
        case .available:
            return taskStore.snapshot.hasVisibleStatus ? "bolt.fill" : "checkmark.circle.fill"
        case .unavailable:
            return "wifi.slash"
        }
    }

    private var taskStatusColor: Color {
        switch taskStore.state {
        case .idle, .loading:
            return Color(red: 0.42, green: 0.78, blue: 0.95)
        case .available:
            return taskStore.snapshot.hasVisibleStatus ? Color(red: 0.36, green: 0.86, blue: 0.58) : palette.mutedText
        case .unavailable:
            return Color(red: 0.96, green: 0.72, blue: 0.28)
        }
    }

    private func relativeTimeText(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "刚刚"
        }
        return "\(seconds / 60) 分钟前"
    }

    private func openCodexApp() {
        let codexApp = URL(fileURLWithPath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: codexApp.path) {
            NSWorkspace.shared.open(codexApp)
        }
    }
}

private struct TaskPickerView: View {
    let records: [TaskRecord]
    let height: CGFloat
    let openTask: (TaskRecord) -> Void
    let openFullPanel: () -> Void
    @Environment(\.colorScheme) private var systemScheme

    private var palette: AppPalette {
        AppPalette(isDark: systemScheme == .dark)
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: palette.visualMaterial, blendingMode: .behindWindow)
                .ignoresSafeArea()
            LinearGradient(
                colors: [palette.backgroundStart, palette.backgroundEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.58))
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("选择 Codex 任务")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(records.count) 个任务状态")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().overlay(palette.divider)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(records) { record in
                            TaskPickerRow(record: record, palette: palette) {
                                openTask(record)
                            }
                        }
                    }
                    .padding(12)
                }

                Divider().overlay(palette.divider)

                Button(action: openFullPanel) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.grid.1x2.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("打开完整面板")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.faintText)
                    }
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(palette.primaryText)
        }
        .frame(width: 360, height: height)
    }
}

private struct TaskPickerRow: View {
    let record: TaskRecord
    let palette: AppPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(record.kind.swiftColor.opacity(palette.isDark ? 0.16 : 0.13))
                    Image(systemName: record.kind.popoverIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(record.kind.swiftColor)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(record.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(record.kind.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(record.kind.swiftColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(record.kind.swiftColor.opacity(palette.isDark ? 0.16 : 0.11), in: RoundedRectangle(cornerRadius: 5))
                    }

                    HStack(spacing: 6) {
                        Text(record.displaySubtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let updatedAt = record.updatedAt {
                            Text(relativeTimeText(updatedAt))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(palette.faintText)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.mutedText)
            }
            .padding(10)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(record.cwd ?? record.displaySubtitle)
    }

    private func relativeTimeText(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "刚刚"
        }
        if seconds < 3_600 {
            return "\(seconds / 60) 分钟前"
        }
        return "\(seconds / 3_600) 小时前"
    }
}

private struct TaskStatBlock: View {
    let title: String
    let value: String
    let kind: TaskStatusKind
    let palette: AppPalette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.popoverIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.swiftColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.mutedText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(kind.swiftColor.opacity(palette.isDark ? 0.12 : 0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind.swiftColor.opacity(0.20), lineWidth: 1))
    }
}

private struct TaskRow: View {
    let record: TaskRecord
    let palette: AppPalette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(record.kind.swiftColor.opacity(palette.isDark ? 0.16 : 0.13))
                Image(systemName: record.kind.popoverIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(record.kind.swiftColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(record.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(record.kind.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(record.kind.swiftColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(record.kind.swiftColor.opacity(palette.isDark ? 0.16 : 0.11), in: RoundedRectangle(cornerRadius: 5))
                }

                Text(record.displaySubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let updatedAt = record.updatedAt {
                    Text(relativeTimeText(updatedAt))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(palette.faintText)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
        .help(record.cwd ?? record.displaySubtitle)
    }

    private func relativeTimeText(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "刚刚更新"
        }
        if seconds < 3_600 {
            return "\(seconds / 60) 分钟前更新"
        }
        return "\(seconds / 3_600) 小时前更新"
    }
}

private extension TaskStatusKind {
    var swiftColor: Color {
        switch self {
        case .error:
            return Color(red: 1.0, green: 0.35, blue: 0.32)
        case .needsConfirmation:
            return Color(red: 0.96, green: 0.72, blue: 0.28)
        case .needsReply:
            return Color(red: 0.52, green: 0.63, blue: 1.0)
        case .running:
            return Color(red: 0.28, green: 0.72, blue: 0.98)
        case .completedUnread:
            return Color(red: 0.36, green: 0.86, blue: 0.58)
        case .idle, .unknown:
            return Color.gray.opacity(0.72)
        }
    }

    var popoverIcon: String {
        switch self {
        case .error:
            return "exclamationmark.circle.fill"
        case .needsConfirmation:
            return "hand.tap.fill"
        case .needsReply:
            return "bubble.left.and.text.bubble.right.fill"
        case .running:
            return "figure.run"
        case .completedUnread:
            return "figure.2.arms.open"
        case .idle:
            return "figure.stand"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

private struct QuotaBlock: View {
    let window: UsageWindow
    let accent: Color
    let palette: AppPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(window.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text(window.resetDetailText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.mutedText)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(window.remainingInt)")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.control)
                    Capsule()
                        .fill(accent)
                        .frame(width: proxy.size.width * max(0, min(window.remainingPercent / 100, 1)))
                }
            }
            .frame(height: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(window.resetText)
                    .font(.system(size: 11, weight: .semibold))
                Text("已用 \(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.mutedText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
    }
}

private struct StatusBadge: View {
    let tone: StatusTone
    let palette: AppPalette

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.swiftColor)
                .frame(width: 6, height: 6)
            Text(tone.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(palette.control, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActivityDayButton: View {
    let title: String
    let isSelected: Bool
    let palette: AppPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black.opacity(0.82) : unselectedText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    isSelected
                        ? Color(red: 0.36, green: 0.86, blue: 0.58)
                        : unselectedBackground,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? Color.clear : unselectedBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var unselectedText: Color {
        palette.isDark ? Color.white.opacity(0.62) : Color.black.opacity(0.68)
    }

    private var unselectedBackground: Color {
        palette.isDark ? palette.control : Color.black.opacity(0.055)
    }

    private var unselectedBorder: Color {
        palette.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
    }
}

private struct IconButton: View {
    let systemName: String
    let palette: AppPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondaryText)
        .background(palette.control, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActionRow: View {
    let systemName: String
    let title: String
    let palette: AppPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.faintText)
            }
            .padding(12)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct AppearanceModePicker: View {
    let mode: AppearanceMode
    let palette: AppPalette
    let onSelect: (AppearanceMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppearanceMode.allCases, id: \.rawValue) { item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(item == mode ? Color.black.opacity(0.82) : pickerUnselectedText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(
                        item == mode
                            ? Color(red: 0.36, green: 0.86, blue: 0.58)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(palette.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
    }

    private var pickerUnselectedText: Color {
        palette.isDark ? palette.secondaryText : Color.black.opacity(0.64)
    }
}

private struct LaunchAtLoginButton: View {
    let isEnabled: Bool
    let palette: AppPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "poweron")
                    .font(.system(size: 11, weight: .semibold))
                Text("开机启动")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? Color.black.opacity(0.82) : palette.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .background(
                isEnabled
                    ? Color(red: 0.36, green: 0.86, blue: 0.58)
                    : palette.control,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(isEnabled ? "已开启开机自动启动" : "点击开启开机自动启动")
    }
}

private struct QuitButton: View {
    let palette: AppPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .bold))
                Text("退出")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(palette.isDark ? Color(red: 1.0, green: 0.72, blue: 0.70) : Color(red: 0.72, green: 0.14, blue: 0.13))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                palette.isDark
                    ? Color(red: 1.0, green: 0.35, blue: 0.32).opacity(0.13)
                    : Color(red: 1.0, green: 0.35, blue: 0.32).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(red: 1.0, green: 0.35, blue: 0.32).opacity(palette.isDark ? 0.24 : 0.20), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

@main
private struct CodexUsageLauncher {
    @MainActor
    static func main() {
        guard SingleInstanceGuard.acquire() else {
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
