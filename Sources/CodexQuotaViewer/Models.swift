import Foundation

enum RefreshIntervalPreset: String, Codable, CaseIterable {
    case manual
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    var displayName: String {
        switch self {
        case .manual:
            return AppLocalization.localized(en: "Manual", zh: "手动")
        case .oneMinute:
            return AppLocalization.localized(en: "1 minute", zh: "1 分钟")
        case .fiveMinutes:
            return AppLocalization.localized(en: "5 minutes", zh: "5 分钟")
        case .fifteenMinutes:
            return AppLocalization.localized(en: "15 minutes", zh: "15 分钟")
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .manual:
            return nil
        case .oneMinute:
            return 60
        case .fiveMinutes:
            return 300
        case .fifteenMinutes:
            return 900
        }
    }
}

enum StatusItemStyle: String, Codable, CaseIterable {
    case meter
    case text

    var displayName: String {
        switch self {
        case .meter:
            return AppLocalization.localized(en: "Meter", zh: "仪表")
        case .text:
            return AppLocalization.localized(en: "Text", zh: "文字")
        }
    }
}

enum QuotaWorkPlanHourMode: String, Codable, CaseIterable, Equatable, Sendable {
    case paused
    case normal
    case intensive

    var relativeWeight: Double {
        switch self {
        case .paused:
            return 0
        case .normal, .intensive:
            return 1
        }
    }

    var displayName: String {
        switch self {
        case .paused:
            return AppLocalization.localized(en: "Off", zh: "停用")
        case .normal, .intensive:
            return AppLocalization.localized(en: "Usable", zh: "可用")
        }
    }

    var menuDescription: String {
        switch self {
        case .paused:
            return AppLocalization.localized(en: "off", zh: "停用")
        case .normal, .intensive:
            return AppLocalization.localized(en: "usable", zh: "可用")
        }
    }
}

struct QuotaWorkPlanPeriod: Codable, Equatable, Sendable {
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int

    init(startMinuteOfDay: Int, endMinuteOfDay: Int) {
        self.startMinuteOfDay = Self.normalizedMinute(startMinuteOfDay)
        self.endMinuteOfDay = Self.normalizedMinute(endMinuteOfDay)
    }

    var isEmpty: Bool {
        startMinuteOfDay == endMinuteOfDay
    }

    func contains(minuteOfDay: Int) -> Bool {
        guard !isEmpty else {
            return false
        }

        let minute = Self.normalizedMinute(minuteOfDay)
        if startMinuteOfDay < endMinuteOfDay {
            return minute >= startMinuteOfDay && minute < endMinuteOfDay
        }
        return minute >= startMinuteOfDay || minute < endMinuteOfDay
    }

    static func normalizedMinute(_ minute: Int) -> Int {
        ((minute % 1_440) + 1_440) % 1_440
    }
}

struct QuotaWorkPlanSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var offPeriods: [QuotaWorkPlanPeriod]

    init(
        isEnabled: Bool = false,
        offPeriods: [QuotaWorkPlanPeriod] = [],
        hourlyModes: [QuotaWorkPlanHourMode]? = nil
    ) {
        self.isEnabled = isEnabled
        self.offPeriods = if let hourlyModes {
            Self.offPeriods(fromHourlyModes: hourlyModes)
        } else {
            Self.normalized(offPeriods)
        }
    }

    func mode(forHour hour: Int) -> QuotaWorkPlanHourMode {
        let normalizedHour = ((hour % 24) + 24) % 24
        return isOff(minuteOfDay: normalizedHour * 60) ? .paused : .normal
    }

    func mode(at date: Date, calendar: Calendar = .current) -> QuotaWorkPlanHourMode {
        isOff(at: date, calendar: calendar) ? .paused : .normal
    }

    var effectiveHourlyModes: [QuotaWorkPlanHourMode] {
        (0..<24).map(mode(forHour:))
    }

    var dailyRelativeWeight: Double {
        Double(availableMinutesPerDay)
    }

    var dailyShareDescription: String {
        let usableMinutes = availableMinutesPerDay
        let offMinutes = 1_440 - usableMinutes
        return AppLocalization.localized(
            en: "\(Self.timeSpanText(minutes: offMinutes)) off / \(Self.timeSpanText(minutes: usableMinutes)) usable; daily budget stays fixed.",
            zh: "\(Self.timeSpanText(minutes: offMinutes)) 停用 / \(Self.timeSpanText(minutes: usableMinutes)) 可用；每日总份额固定。"
        )
    }

    func expectedRemainingPercent(
        startDate: Date,
        resetDate: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Double {
        guard isEnabled else {
            let total = resetDate.timeIntervalSince(startDate)
            guard total > 0 else { return 100 }
            return min(100, max(0, resetDate.timeIntervalSince(now) / total * 100))
        }

        guard resetDate > startDate else {
            return 100
        }

        if now <= startDate {
            return 100
        }

        let targetDate = dailyTargetDate(at: now, calendar: calendar) ?? now
        let clampedNow = min(max(targetDate, startDate), resetDate)
        let totalWeight = weightedSeconds(from: startDate, to: resetDate, calendar: calendar)
        guard totalWeight > 0 else {
            return 100
        }

        let elapsedWeight = weightedSeconds(from: startDate, to: clampedNow, calendar: calendar)
        let expectedUsed = min(100, max(0, elapsedWeight / totalWeight * 100))
        return min(100, max(0, 100 - expectedUsed))
    }

    func isOff(at date: Date, calendar: Calendar = .current) -> Bool {
        isOff(minuteOfDay: minuteOfDay(at: date, calendar: calendar))
    }

    func isOff(minuteOfDay: Int) -> Bool {
        Self.normalized(offPeriods).contains { $0.contains(minuteOfDay: minuteOfDay) }
    }

    var availableMinutesPerDay: Int {
        let available = (0..<1_440).filter { !isOff(minuteOfDay: $0) }.count
        return available > 0 ? available : 1_440
    }

    private func dailyTargetDate(at date: Date, calendar: Calendar) -> Date? {
        guard !Self.normalized(offPeriods).isEmpty else {
            return nil
        }

        if isOff(at: date, calendar: calendar) {
            return currentOffPeriodStart(at: date, calendar: calendar)
        }

        return nextOffPeriodStart(after: date, calendar: calendar)
    }

    private func currentOffPeriodStart(at date: Date, calendar: Calendar) -> Date? {
        guard isOff(at: date, calendar: calendar) else {
            return nil
        }

        var cursor = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        for _ in 0..<(1_440 * 2 + 2) {
            let previous = cursor.addingTimeInterval(-60)
            if !isOff(at: previous, calendar: calendar) {
                return cursor
            }
            cursor = previous
        }
        return nil
    }

    private func nextOffPeriodStart(after date: Date, calendar: Calendar) -> Date? {
        var cursor = date
        for _ in 0..<(1_440 * 2 + 2) {
            let nextMinute = calendar.nextDate(
                after: cursor,
                matching: DateComponents(second: 0, nanosecond: 0),
                matchingPolicy: .nextTime,
                direction: .forward
            ) ?? cursor.addingTimeInterval(60)
            if isOff(at: nextMinute, calendar: calendar) {
                return currentOffPeriodStart(at: nextMinute, calendar: calendar) ?? nextMinute
            }
            cursor = nextMinute
        }
        return nil
    }

    private func weightedSeconds(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar
    ) -> Double {
        guard endDate > startDate else {
            return 0
        }

        var cursor = startDate
        var total = 0.0
        while cursor < endDate {
            let nextMinute = calendar.nextDate(
                after: cursor,
                matching: DateComponents(second: 0, nanosecond: 0),
                matchingPolicy: .nextTime,
                direction: .forward
            ) ?? endDate
            let segmentEnd = min(nextMinute, endDate)
            let relativeWeight = isOff(at: cursor, calendar: calendar) ? 0.0 : 1.0
            total += max(0, segmentEnd.timeIntervalSince(cursor)) * relativeWeight
            cursor = segmentEnd
        }
        return total
    }

    private func minuteOfDay(at date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func normalized(_ periods: [QuotaWorkPlanPeriod]) -> [QuotaWorkPlanPeriod] {
        periods
            .map { QuotaWorkPlanPeriod(startMinuteOfDay: $0.startMinuteOfDay, endMinuteOfDay: $0.endMinuteOfDay) }
            .filter { !$0.isEmpty }
            .sorted {
                if $0.startMinuteOfDay == $1.startMinuteOfDay {
                    return $0.endMinuteOfDay < $1.endMinuteOfDay
                }
                return $0.startMinuteOfDay < $1.startMinuteOfDay
            }
    }

    private static func normalizedHourlyModes(_ modes: [QuotaWorkPlanHourMode]) -> [QuotaWorkPlanHourMode] {
        let prefix = Array(modes.prefix(24))
        if prefix.count == 24 {
            return prefix.map { $0 == .intensive ? .normal : $0 }
        }
        return (prefix + Array(repeating: .normal, count: 24 - prefix.count))
            .map { $0 == .intensive ? .normal : $0 }
    }

    private static func offPeriods(fromHourlyModes modes: [QuotaWorkPlanHourMode]) -> [QuotaWorkPlanPeriod] {
        let modes = normalizedHourlyModes(modes)
        guard modes.contains(.paused),
              modes.contains(where: { $0 != .paused }) else {
            return []
        }

        var periods: [QuotaWorkPlanPeriod] = []
        var startHour: Int?
        for hour in 0..<24 {
            if modes[hour] == .paused {
                if startHour == nil {
                    startHour = hour
                }
            } else if let start = startHour {
                periods.append(
                    QuotaWorkPlanPeriod(startMinuteOfDay: start * 60, endMinuteOfDay: hour * 60)
                )
                startHour = nil
            }
        }

        if let start = startHour {
            periods.append(QuotaWorkPlanPeriod(startMinuteOfDay: start * 60, endMinuteOfDay: 0))
        }

        if periods.count >= 2,
           let first = periods.first,
           let last = periods.last,
           first.startMinuteOfDay == 0,
           last.endMinuteOfDay == 0 {
            var merged = periods
            merged.removeFirst()
            merged.removeLast()
            merged.append(
                QuotaWorkPlanPeriod(
                    startMinuteOfDay: last.startMinuteOfDay,
                    endMinuteOfDay: first.endMinuteOfDay
                )
            )
            return normalized(merged)
        }

        return normalized(periods)
    }

    private static func timeSpanText(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return AppLocalization.localized(en: "\(hours)h", zh: "\(hours) 小时")
        }
        return AppLocalization.localized(en: "\(hours)h \(remainder)m", zh: "\(hours) 小时 \(remainder) 分钟")
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case offPeriods
        case hourlyModes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        if let periods = try container.decodeIfPresent([QuotaWorkPlanPeriod].self, forKey: .offPeriods) {
            offPeriods = Self.normalized(periods)
        } else if let modes = try container.decodeIfPresent([QuotaWorkPlanHourMode].self, forKey: .hourlyModes) {
            offPeriods = Self.offPeriods(fromHourlyModes: modes)
        } else {
            offPeriods = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(Self.normalized(offPeriods), forKey: .offPeriods)
    }
}

enum ProfileHealthStatus: String, Codable, Equatable, Sendable {
    case healthy
    case readFailure
    case needsLogin
    case expired

    var label: String {
        switch self {
        case .healthy:
            return AppLocalization.localized(en: "Healthy", zh: "正常")
        case .readFailure:
            return AppLocalization.localized(en: "Read failed", zh: "读取失败")
        case .needsLogin:
            return AppLocalization.localized(en: "Sign in required", zh: "需要登录")
        case .expired:
            return AppLocalization.localized(en: "Expired", zh: "已过期")
        }
    }

    var isHealthy: Bool {
        self == .healthy
    }
}

enum QuotaFailureDisposition: String, Codable, Equatable, Sendable {
    case transient
    case terminal
}

struct AppSettings: Codable, Equatable {
    var refreshIntervalPreset: RefreshIntervalPreset
    var launchAtLoginEnabled: Bool
    var statusItemStyle: StatusItemStyle
    var appLanguage: AppLanguage
    var lastResolvedLanguage: ResolvedAppLanguage?
    var preferredAccountID: String?
    var quotaWorkPlan: QuotaWorkPlanSettings

    init(
        refreshIntervalPreset: RefreshIntervalPreset = .fiveMinutes,
        launchAtLoginEnabled: Bool = false,
        statusItemStyle: StatusItemStyle = .meter,
        appLanguage: AppLanguage = .system,
        lastResolvedLanguage: ResolvedAppLanguage? = nil,
        preferredAccountID: String? = nil,
        quotaWorkPlan: QuotaWorkPlanSettings = QuotaWorkPlanSettings()
    ) {
        self.refreshIntervalPreset = refreshIntervalPreset
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.statusItemStyle = statusItemStyle
        self.appLanguage = appLanguage
        self.lastResolvedLanguage = lastResolvedLanguage
        self.preferredAccountID = preferredAccountID
        self.quotaWorkPlan = quotaWorkPlan
    }

    private enum CodingKeys: String, CodingKey {
        case refreshIntervalPreset
        case launchAtLoginEnabled
        case statusItemStyle
        case appLanguage
        case lastResolvedLanguage
        case preferredAccountID
        case quotaWorkPlan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalPreset = try container.decodeIfPresent(
            RefreshIntervalPreset.self,
            forKey: .refreshIntervalPreset
        ) ?? .fiveMinutes
        launchAtLoginEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .launchAtLoginEnabled
        ) ?? false
        statusItemStyle = try container.decodeIfPresent(
            StatusItemStyle.self,
            forKey: .statusItemStyle
        ) ?? .meter
        appLanguage = try container.decodeIfPresent(
            AppLanguage.self,
            forKey: .appLanguage
        ) ?? .system
        lastResolvedLanguage = try container.decodeIfPresent(
            ResolvedAppLanguage.self,
            forKey: .lastResolvedLanguage
        )
        preferredAccountID = try container.decodeIfPresent(
            String.self,
            forKey: .preferredAccountID
        )
        quotaWorkPlan = try container.decodeIfPresent(
            QuotaWorkPlanSettings.self,
            forKey: .quotaWorkPlan
        ) ?? QuotaWorkPlanSettings()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refreshIntervalPreset, forKey: .refreshIntervalPreset)
        try container.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try container.encode(statusItemStyle, forKey: .statusItemStyle)
        try container.encode(appLanguage, forKey: .appLanguage)
        try container.encodeIfPresent(lastResolvedLanguage, forKey: .lastResolvedLanguage)
        try container.encodeIfPresent(preferredAccountID, forKey: .preferredAccountID)
        try container.encode(quotaWorkPlan, forKey: .quotaWorkPlan)
    }
}

struct CodexSnapshot: Codable, Equatable, Sendable {
    let account: CodexAccount
    let rateLimits: RateLimitSnapshot
    let fetchedAt: Date
}

struct APIQuotaFetchResult: Equatable, Sendable {
    let snapshot: CodexSnapshot
    let poolSnapshots: [CPAPoolQuotaSnapshot]

    init(snapshot: CodexSnapshot, poolSnapshots: [CPAPoolQuotaSnapshot] = []) {
        self.snapshot = snapshot
        self.poolSnapshots = poolSnapshots
    }
}

struct CPAPoolQuotaSnapshot: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let authFile: String?
    let authIndex: String?
    let sourceHint: String?
    let isCurrentRoute: Bool
    let isRoutePreferred: Bool
    let isLatestRequestRoute: Bool
    let snapshot: CodexSnapshot
    let model: String?
    let reasoningEffort: String?
    let statusCode: Int?
    let failed: Bool?
    let requestID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case authFile
        case authIndex
        case sourceHint
        case isCurrentRoute
        case isRoutePreferred
        case isLatestRequestRoute
        case snapshot
        case model
        case reasoningEffort
        case statusCode
        case failed
        case requestID
    }

    init(
        id: String,
        displayName: String,
        authFile: String?,
        authIndex: String?,
        sourceHint: String?,
        isCurrentRoute: Bool,
        isRoutePreferred: Bool = false,
        isLatestRequestRoute: Bool = false,
        snapshot: CodexSnapshot,
        model: String?,
        reasoningEffort: String?,
        statusCode: Int?,
        failed: Bool?,
        requestID: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.authFile = authFile
        self.authIndex = authIndex
        self.sourceHint = sourceHint
        self.isCurrentRoute = isCurrentRoute
        self.isRoutePreferred = isRoutePreferred
        self.isLatestRequestRoute = isLatestRequestRoute
        self.snapshot = snapshot
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.statusCode = statusCode
        self.failed = failed
        self.requestID = requestID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        authFile = try container.decodeIfPresent(String.self, forKey: .authFile)
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex)
        sourceHint = try container.decodeIfPresent(String.self, forKey: .sourceHint)
        isCurrentRoute = try container.decode(Bool.self, forKey: .isCurrentRoute)
        isRoutePreferred = try container.decodeIfPresent(Bool.self, forKey: .isRoutePreferred) ?? false
        isLatestRequestRoute = try container.decodeIfPresent(Bool.self, forKey: .isLatestRequestRoute) ?? false
        snapshot = try container.decode(CodexSnapshot.self, forKey: .snapshot)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    }
}

struct CodexAccount: Codable, Equatable, Sendable {
    let type: String
    let email: String?
    let planType: String?
}

struct RateLimitSnapshot: Codable, Equatable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let planType: String?
}

struct RateLimitWindow: Codable, Equatable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

struct QuotaDisplayWindow: Equatable {
    let label: String
    let window: RateLimitWindow
}

enum QuotaPaceState: Equatable {
    case onPace
    case withinGuard
    case overGuard
}

struct QuotaPaceComparison: Equatable {
    let expectedRemainingPercent: Double
    let overspendPercent: Double
    let state: QuotaPaceState
}

extension CodexAccount {
    var displayLabel: String {
        if let email, !email.isEmpty {
            return email
        }
        return type == "apiKey"
            ? AppLocalization.localized(en: "API Key", zh: "API 密钥")
            : AppLocalization.localized(en: "Not signed in", zh: "未登录")
    }
}

extension RateLimitWindow {
    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    func remainingPercent(at now: Date) -> Double {
        if resetIsExpired(at: now) {
            return 100
        }
        return remainingPercent
    }

    var remainingPercentText: String {
        "\(Int(remainingPercent.rounded()))%"
    }

    func remainingPercentText(at now: Date) -> String {
        "\(Int(remainingPercent(at: now).rounded()))%"
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }

    func resetIsExpired(at now: Date) -> Bool {
        guard let resetDate else { return false }
        return resetDate < now
    }

    func displayWindow(at now: Date) -> RateLimitWindow {
        guard resetIsExpired(at: now) else {
            return self
        }
        return RateLimitWindow(
            usedPercent: 0,
            windowDurationMins: windowDurationMins,
            resetsAt: resetsAt
        )
    }

    func paceComparison(
        at now: Date,
        guardPercent: Double = 5.0,
        workPlan: QuotaWorkPlanSettings = QuotaWorkPlanSettings()
    ) -> QuotaPaceComparison? {
        guard let windowDurationMins,
              windowDurationMins > 0,
              let resetDate else {
            return nil
        }

        if resetIsExpired(at: now) {
            return QuotaPaceComparison(
                expectedRemainingPercent: 100,
                overspendPercent: 0,
                state: .onPace
            )
        }

        let durationSeconds = TimeInterval(windowDurationMins * 60)
        guard durationSeconds > 0 else {
            return nil
        }

        let startDate = resetDate.addingTimeInterval(-durationSeconds)
        let expectedRemaining = workPlan.expectedRemainingPercent(
            startDate: startDate,
            resetDate: resetDate,
            now: now
        )
        let overspend = expectedRemaining - remainingPercent(at: now)
        let state: QuotaPaceState
        if overspend <= 0 {
            state = .onPace
        } else if overspend <= guardPercent {
            state = .withinGuard
        } else {
            state = .overGuard
        }

        return QuotaPaceComparison(
            expectedRemainingPercent: expectedRemaining,
            overspendPercent: max(0, overspend),
            state: state
        )
    }
}

func quotaDisplayWindows(from snapshot: CodexSnapshot?) -> [QuotaDisplayWindow] {
    guard let snapshot else {
        return []
    }

    return quotaDisplayWindows(from: snapshot.rateLimits)
}

func quotaDisplayWindows(from snapshot: CodexSnapshot?, now: Date) -> [QuotaDisplayWindow] {
    guard let snapshot else {
        return []
    }

    return quotaDisplayWindows(from: snapshot.rateLimits, now: now)
}

func quotaDisplayWindows(from rateLimits: RateLimitSnapshot) -> [QuotaDisplayWindow] {
    let rawWindows = [
        (index: 0, window: rateLimits.primary),
        (index: 1, window: rateLimits.secondary),
    ]
    .compactMap { entry -> (index: Int, window: RateLimitWindow)? in
        guard let window = entry.window else {
            return nil
        }
        return (index: entry.index, window: window)
    }
    .sorted { lhs, rhs in
        let lhsDuration = lhs.window.windowDurationMins ?? Int.max
        let rhsDuration = rhs.window.windowDurationMins ?? Int.max
        if lhsDuration != rhsDuration {
            return lhsDuration < rhsDuration
        }
        return lhs.index < rhs.index
    }

    return rawWindows.enumerated().map { offset, entry in
        QuotaDisplayWindow(
            label: quotaWindowLabel(
                durationMins: entry.window.windowDurationMins,
                position: offset,
                total: rawWindows.count
            ),
            window: entry.window
        )
    }
}

func quotaDisplayWindows(from rateLimits: RateLimitSnapshot, now: Date) -> [QuotaDisplayWindow] {
    quotaDisplayWindows(from: rateLimits).map {
        QuotaDisplayWindow(label: $0.label, window: $0.window.displayWindow(at: now))
    }
}

private func quotaWindowLabel(
    durationMins: Int?,
    position: Int,
    total: Int
) -> String {
    guard let durationMins, durationMins > 0 else {
        if total == 1 {
            return AppLocalization.localized(en: "quota", zh: "额度")
        }
        return AppLocalization.localized(en: "quota \(position + 1)", zh: "额度 \(position + 1)")
    }

    if durationMins % 10_080 == 0 {
        return "\(durationMins / 10_080)w"
    }
    if durationMins % 1_440 == 0 {
        return "\(durationMins / 1_440)d"
    }
    if durationMins % 60 == 0 {
        return "\(durationMins / 60)h"
    }
    return "\(durationMins)m"
}

func classifyProfileHealth(from error: Error) -> ProfileHealthStatus {
    if let rpcError = error as? CodexRPCError {
        switch rpcError {
        case .notLoggedIn:
            return .needsLogin
        case .rpc(let message), .invalidResponse(let message):
            let lowered = message.lowercased()
            if lowered.contains("expired") || lowered.contains("session expired") || lowered.contains("token expired") {
                return .expired
            }
            if lowered.contains("401")
                || lowered.contains("unauthorized")
                || lowered.contains("forbidden")
                || lowered.contains("login")
                || lowered.contains("sign in") {
                return .needsLogin
            }
            return .readFailure
        case .timeout, .missingExecutable:
            return .readFailure
        }
    }

    return .readFailure
}

func classifyQuotaFailureDisposition(from error: Error) -> QuotaFailureDisposition? {
    guard classifyProfileHealth(from: error) == .readFailure else {
        return nil
    }

    if let cpaError = error as? CPAQuotaSnapshotError {
        switch cpaError {
        case .commandFailed, .noQuotaRecord:
            return .transient
        case .missingRateLimitHeaders:
            return .terminal
        case .unsupportedAccount:
            return nil
        }
    }

    if let rpcError = error as? CodexRPCError {
        switch rpcError {
        case .timeout:
            return .transient
        case .rpc(let message):
            let lowered = message.lowercased()
            if lowered.contains("app-server failed to start")
                || lowered.contains("app-server exited early") {
                return .transient
            }
            return .terminal
        case .missingExecutable, .invalidResponse:
            return .terminal
        case .notLoggedIn:
            return nil
        }
    }

    return .terminal
}
