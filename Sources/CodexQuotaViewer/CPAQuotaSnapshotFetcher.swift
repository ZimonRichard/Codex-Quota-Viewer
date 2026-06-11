import Foundation

enum CPAQuotaSnapshotError: LocalizedError, Equatable {
    case unsupportedAccount
    case commandFailed(String)
    case noQuotaRecord
    case missingRateLimitHeaders

    var errorDescription: String? {
        switch self {
        case .unsupportedAccount:
            return AppLocalization.localized(
                en: "CPA quota is only available for local OpenAI-compatible API accounts.",
                zh: "CPA 额度仅适用于本地 OpenAI 兼容 API 账号。"
            )
        case .commandFailed(let message):
            return message
        case .noQuotaRecord:
            return AppLocalization.localized(
                en: "No CPA usage record is available yet.",
                zh: "暂无 CPA 使用记录。"
            )
        case .missingRateLimitHeaders:
            return AppLocalization.localized(
                en: "CPA usage record has no Codex quota headers.",
                zh: "CPA 使用记录中没有 Codex 额度响应头。"
            )
        }
    }
}

struct CPAQuotaSnapshotFetcher: Sendable {
    typealias BridgeCommandRunner = @Sendable (_ sshHost: String, _ remoteCommand: String, _ timeout: TimeInterval) async throws -> Data

    static let defaultRemoteCommand = "sudo -n /home/ubuntu/Qin/ops/cpa/show-cpa-pool-quota.py --json 300"
    static let defaultTimeout: TimeInterval = 75

    private struct ScriptResponse: Decodable {
        let recordsSaved: Int?
        let current: CPAUsageRecord?
        let latest: [CPAUsageRecord]
        let accounts: [CPAPoolAccountRecord]?

        private enum CodingKeys: String, CodingKey {
            case recordsSaved = "records_saved"
            case current
            case latest
            case accounts
        }
    }

    private struct CPAPoolAccountRecord: Decodable {
        let id: String
        let displayName: String
        let authFile: String?
        let authIndex: String?
        let sourceHint: String?
        let isCurrentRoute: Bool?
        let isRoutePreferred: Bool?
        let isLatestRequestRoute: Bool?
        let latest: CPAUsageRecord?
        let quotaGuard: CPAQuotaGuardRecord?
        let refreshSkipped: Bool?
        let skipReason: String?
        let accountStats: CPAAccountStatsRecord?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case authFile = "auth_file"
            case authIndex = "auth_index"
            case sourceHint = "source_hint"
            case isCurrentRoute = "is_current_route"
            case isRoutePreferred = "is_route_preferred"
            case isLatestRequestRoute = "is_latest_request_route"
            case latest
            case quotaGuard = "quota_guard"
            case refreshSkipped = "refresh_skipped"
            case skipReason = "skip_reason"
            case accountStats = "account_stats"
        }
    }

    private struct CPAUsageRecord: Decodable {
        let timestamp: String?
        let authIndex: String?
        let authFile: String?
        let sourceHint: String?
        let model: String?
        let alias: String?
        let reasoningEffort: String?
        let requestID: String?
        let failed: Bool?
        let statusCode: Int?
        let stale: Bool?
        let refreshSkipped: Bool?
        let skipReason: String?
        let quotaGuard: CPAQuotaGuardRecord?
        let codexHeaders: [String: [String]]

        private enum CodingKeys: String, CodingKey {
            case timestamp
            case authIndex = "auth_index"
            case authFile = "auth_file"
            case sourceHint = "source_hint"
            case model
            case alias
            case reasoningEffort = "reasoning_effort"
            case requestID = "request_id"
            case failed
            case statusCode = "status_code"
            case stale
            case refreshSkipped = "refresh_skipped"
            case skipReason = "skip_reason"
            case quotaGuard = "quota_guard"
            case codexHeaders = "codex_headers"
        }
    }

    private struct CPAQuotaGuardRecord: Decodable {
        let state: String?
        let reason: String?
    }

    private struct CPAAccountStatsRecord: Decodable {
        let sampleCount: Int?
        let primary: CPAAccountStatsCapacity?
        let secondary: CPAAccountStatsCapacity?

        private enum CodingKeys: String, CodingKey {
            case sampleCount = "sample_count"
            case primary
            case secondary
        }
    }

    private struct CPAAccountStatsCapacity: Decodable {
        let estimatedRemainingSuccesses: Int?

        private enum CodingKeys: String, CodingKey {
            case estimatedRemainingSuccesses = "estimated_remaining_successes"
        }
    }

    private let sshHost: String
    private let remoteCommand: String
    private let timeout: TimeInterval
    private let bridgeCommandRunner: BridgeCommandRunner

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bridgeCommandRunner: BridgeCommandRunner? = nil
    ) {
        let host = environment["CODEX_QUOTA_VIEWER_CPA_SSH_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sshHost = host?.isEmpty == false ? host! : "qin-server"

        let command = environment["CODEX_QUOTA_VIEWER_CPA_QUOTA_COMMAND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        remoteCommand = command?.isEmpty == false
            ? command!
            : Self.defaultRemoteCommand

        let timeoutValue = environment["CODEX_QUOTA_VIEWER_CPA_TIMEOUT_SECONDS"]
            .flatMap(Double.init)
        timeout = max(2, timeoutValue ?? Self.defaultTimeout)
        self.bridgeCommandRunner = bridgeCommandRunner ?? Self.runBridgeCommand
    }

    func canFetch(runtimeMaterial: ProfileRuntimeMaterial) -> Bool {
        guard resolveAuthMode(authData: runtimeMaterial.authData) == .apiKey else {
            return false
        }

        let summary = parseRuntimeConfig(runtimeMaterial.configData)
        guard let baseURL = summary.baseURL,
              let components = URLComponents(string: baseURL),
              let host = components.host?.lowercased() else {
            return false
        }

        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return true
        }

        return false
    }

    func fetchSnapshot(
        runtimeMaterial: ProfileRuntimeMaterial,
        displayName: String?,
        timeout overrideTimeout: TimeInterval? = nil
    ) async throws -> CodexSnapshot {
        try await fetchResult(
            runtimeMaterial: runtimeMaterial,
            displayName: displayName,
            timeout: overrideTimeout
        ).snapshot
    }

    func fetchResult(
        runtimeMaterial: ProfileRuntimeMaterial,
        displayName: String?,
        timeout overrideTimeout: TimeInterval? = nil
    ) async throws -> APIQuotaFetchResult {
        guard canFetch(runtimeMaterial: runtimeMaterial) else {
            throw CPAQuotaSnapshotError.unsupportedAccount
        }

        let data = try await bridgeCommandRunner(sshHost, remoteCommand, overrideTimeout ?? timeout)
        let response = try JSONDecoder().decode(ScriptResponse.self, from: data)
        let poolSnapshots = response.accounts?
            .compactMap { poolSnapshot(from: $0) } ?? []
        let currentPoolSnapshot = poolSnapshots.first(where: \.isCurrentRoute)
        let preferredPoolSnapshot = poolSnapshots.first(where: \.isRoutePreferred)
        let firstQuotaBearingPoolSnapshot = poolSnapshots.first {
            !quotaDisplayWindows(from: $0.snapshot).isEmpty
        }

        if let parentPoolSnapshot = currentPoolSnapshot
            ?? preferredPoolSnapshot
            ?? firstQuotaBearingPoolSnapshot {
            return APIQuotaFetchResult(
                snapshot: snapshotByApplyingDisplayName(
                    parentPoolSnapshot.snapshot,
                    displayName: displayName
                ),
                poolSnapshots: poolSnapshots
            )
        }

        guard poolSnapshots.isEmpty else {
            return APIQuotaFetchResult(
                snapshot: placeholderSnapshot(displayName: displayName),
                poolSnapshots: poolSnapshots
            )
        }

        let fallbackRecord = response.current ?? response.latest.first
        if let record = fallbackRecord {
            do {
                let snapshot = try snapshot(from: record, displayName: displayName)
                return APIQuotaFetchResult(snapshot: snapshot, poolSnapshots: poolSnapshots)
            } catch CPAQuotaSnapshotError.missingRateLimitHeaders where !poolSnapshots.isEmpty {
                return APIQuotaFetchResult(
                    snapshot: placeholderSnapshot(displayName: displayName),
                    poolSnapshots: poolSnapshots
                )
            }
        }

        guard !poolSnapshots.isEmpty else {
            throw CPAQuotaSnapshotError.noQuotaRecord
        }

        return APIQuotaFetchResult(
            snapshot: placeholderSnapshot(displayName: displayName),
            poolSnapshots: poolSnapshots
        )
    }

    private func snapshot(from record: CPAUsageRecord, displayName: String?) throws -> CodexSnapshot {
        let primary = rateLimitWindow(
            from: record.codexHeaders,
            prefix: "X-Codex-Primary"
        )
        let secondary = rateLimitWindow(
            from: record.codexHeaders,
            prefix: "X-Codex-Secondary"
        )

        guard primary != nil || secondary != nil else {
            throw CPAQuotaSnapshotError.missingRateLimitHeaders
        }

        let account = CodexAccount(
            type: "apiKey",
            email: trimmedNonEmptyDisplayName(displayName),
            planType: headerValue(record.codexHeaders, "X-Codex-Plan-Type")
        )
        let rateLimits = RateLimitSnapshot(
            limitId: headerValue(record.codexHeaders, "X-Codex-Active-Limit"),
            limitName: nil,
            primary: primary,
            secondary: secondary,
            planType: headerValue(record.codexHeaders, "X-Codex-Plan-Type")
        )
        return CodexSnapshot(
            account: account,
            rateLimits: rateLimits,
            fetchedAt: parsedRecordTimestamp(record.timestamp) ?? Date()
        )
    }

    private func poolSnapshot(from account: CPAPoolAccountRecord) -> CPAPoolQuotaSnapshot? {
        guard account.authFile != nil else {
            return nil
        }

        let latest = account.latest
        let resolvedSnapshot = latest.flatMap { record in
            try? snapshot(
                from: record,
                displayName: account.displayName
            )
        } ?? placeholderSnapshot(
            displayName: account.displayName,
            latest: latest
        )

        return CPAPoolQuotaSnapshot(
            id: trimmedNonEmptyDisplayName(account.id)
                ?? trimmedNonEmptyDisplayName(account.authFile)
                ?? trimmedNonEmptyDisplayName(account.authIndex)
                ?? UUID().uuidString,
            displayName: account.displayName,
            authFile: account.authFile,
            authIndex: account.authIndex ?? latest?.authIndex,
            sourceHint: account.sourceHint ?? latest?.sourceHint,
            isCurrentRoute: account.isCurrentRoute ?? false,
            isRoutePreferred: account.isRoutePreferred ?? false,
            isLatestRequestRoute: account.isLatestRequestRoute ?? false,
            snapshot: resolvedSnapshot,
            model: latest?.model ?? latest?.alias,
            reasoningEffort: latest?.reasoningEffort,
            statusCode: latest?.statusCode,
            failed: latest?.failed,
            requestID: latest?.requestID,
            isStale: latest?.stale ?? false,
            refreshSkipped: account.refreshSkipped ?? latest?.refreshSkipped ?? false,
            skipReason: account.skipReason ?? latest?.skipReason,
            quotaGuardState: account.quotaGuard?.state ?? latest?.quotaGuard?.state,
            quotaGuardReason: account.quotaGuard?.reason ?? latest?.quotaGuard?.reason,
            statsSampleCount: account.accountStats?.sampleCount,
            estimatedRemainingSuccesses: estimatedRemainingSuccesses(from: account.accountStats)
        )
    }

    private func estimatedRemainingSuccesses(from stats: CPAAccountStatsRecord?) -> Int? {
        let values = [
            stats?.primary?.estimatedRemainingSuccesses,
            stats?.secondary?.estimatedRemainingSuccesses
        ].compactMap { $0 }
        return values.min()
    }

    private func placeholderSnapshot(
        displayName: String?,
        latest: CPAUsageRecord? = nil
    ) -> CodexSnapshot {
        let planType = latest.flatMap { headerValue($0.codexHeaders, "X-Codex-Plan-Type") }
        return CodexSnapshot(
            account: CodexAccount(
                type: "apiKey",
                email: trimmedNonEmptyDisplayName(displayName),
                planType: planType
            ),
            rateLimits: RateLimitSnapshot(
                limitId: latest.flatMap { headerValue($0.codexHeaders, "X-Codex-Active-Limit") },
                limitName: nil,
                primary: nil,
                secondary: nil,
                planType: planType
            ),
            fetchedAt: latest.flatMap { parsedRecordTimestamp($0.timestamp) } ?? Date()
        )
    }

    private func snapshotByApplyingDisplayName(
        _ snapshot: CodexSnapshot,
        displayName: String?
    ) -> CodexSnapshot {
        let trimmedDisplayName = trimmedNonEmptyDisplayName(displayName)
        guard trimmedDisplayName != nil else {
            return snapshot
        }
        return CodexSnapshot(
            account: CodexAccount(
                type: snapshot.account.type,
                email: trimmedDisplayName,
                planType: snapshot.account.planType
            ),
            rateLimits: snapshot.rateLimits,
            fetchedAt: snapshot.fetchedAt
        )
    }

    private func rateLimitWindow(
        from headers: [String: [String]],
        prefix: String
    ) -> RateLimitWindow? {
        guard let usedPercent = headerValue(headers, "\(prefix)-Used-Percent")
            .flatMap(Double.init) else {
            return nil
        }

        let windowDurationMins = headerValue(headers, "\(prefix)-Window-Minutes")
            .flatMap(Int.init)
        let resetsAt = headerValue(headers, "\(prefix)-Reset-At")
            .flatMap(Int.init)
        return RateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: windowDurationMins,
            resetsAt: resetsAt
        )
    }

    private func headerValue(_ headers: [String: [String]], _ key: String) -> String? {
        headers[key]?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmedNonEmptyDisplayName(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func parsedRecordTimestamp(_ rawValue: String?) -> Date? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: rawValue) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: rawValue) {
            return date
        }
        return nil
    }

    private static func runBridgeCommand(
        sshHost: String,
        remoteCommand: String,
        timeout: TimeInterval
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try runProcess(
                    executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                    arguments: [
                        "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=\(max(1, Int(timeout.rounded())))",
                        sshHost,
                        remoteCommand,
                    ]
                )
            }
            group.addTask {
                try await sleepForCPAQuotaTimeout(timeout)
                throw CodexRPCError.timeout
            }

            guard let result = try await group.next() else {
                throw CPAQuotaSnapshotError.noQuotaRecord
            }
            group.cancelAll()
            return result
        }
    }
}

private func runProcess(
    executableURL: URL,
    arguments: [String]
) throws -> Data {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

    guard process.terminationStatus == 0 else {
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw CPAQuotaSnapshotError.commandFailed(
            message?.isEmpty == false
                ? message!
                : AppLocalization.localized(en: "CPA bridge command failed.", zh: "CPA 桥接命令执行失败。")
        )
    }

    return output
}

private func sleepForCPAQuotaTimeout(_ timeout: TimeInterval) async throws {
    let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
}
