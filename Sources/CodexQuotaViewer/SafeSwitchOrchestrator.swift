import Foundation

struct OfficialRepairSummary: Codable, Equatable {
    let createdThreads: Int
    let updatedThreads: Int
    let updatedSessionIndexEntries: Int
    let removedBrokenThreads: Int
    let hiddenSnapshotOnlySessions: Int
}

struct SwitchOperationPreview: Equatable {
    let targetProfile: ProviderProfile
    let targetProviderID: String
    let filesToBackup: [URL]
    let rolloutFilesToUpdate: [URL]
    let codexWasRunning: Bool
}

struct SwitchOperationResult: Equatable {
    let targetProfileID: String
    let restorePoint: RestorePointManifest
    let updatedRolloutCount: Int
    let repairSummary: OfficialRepairSummary
}

struct RepairOperationResult: Equatable {
    let restorePoint: RestorePointManifest
    let repairSummary: OfficialRepairSummary
}

enum SwitchOrchestratorError: LocalizedError {
    case missingRuntimeConfig(String)
    case missingProviderIdentifier(String)
    case automaticRollbackFailed

    var errorDescription: String? {
        switch self {
        case .missingRuntimeConfig(let name):
            return AppLocalization.localized(
                en: "The target profile “\(name)” does not have enough runtime config to switch safely.",
                zh: "目标账号“\(name)”缺少足够的运行时配置，无法安全切换。"
            )
        case .missingProviderIdentifier(let name):
            return AppLocalization.localized(
                en: "The target profile “\(name)” is missing a model provider identifier.",
                zh: "目标账号“\(name)”缺少 model provider 标识。"
            )
        case .automaticRollbackFailed:
            return AppLocalization.localized(
                en: "The operation failed and the automatic rollback could not be completed. Use the latest restore point to roll back manually.",
                zh: "操作失败，且自动回滚未能完成。请使用最新还原点手动回滚。"
            )
        }
    }
}

@MainActor
final class SwitchOrchestrator {
    private let store: ProfileStore
    private let backupManager: BackupManager
    private let rolloutSynchronizer: RolloutProviderSynchronizer
    private let threadProviderRelabeler: LocalThreadProviderRelabeler
    private let threadTitlePreserver: LocalThreadTitlePreserver
    private let repairClient: OfficialThreadRepairing
    private let desktopController: CodexDesktopControlling
    private let quotaChannelInvalidator: CodexRPCChannelInvalidating

    init(
        store: ProfileStore,
        backupManager: BackupManager,
        rolloutSynchronizer: RolloutProviderSynchronizer,
        repairClient: OfficialThreadRepairing,
        desktopController: CodexDesktopControlling,
        quotaChannelInvalidator: CodexRPCChannelInvalidating
    ) {
        self.store = store
        self.backupManager = backupManager
        self.rolloutSynchronizer = rolloutSynchronizer
        threadProviderRelabeler = LocalThreadProviderRelabeler()
        threadTitlePreserver = LocalThreadTitlePreserver()
        self.repairClient = repairClient
        self.desktopController = desktopController
        self.quotaChannelInvalidator = quotaChannelInvalidator
    }

    func preview(targetProfile: ProviderProfile) throws -> SwitchOperationPreview {
        let effectiveConfig = try effectiveTargetConfigData(for: targetProfile)
        let targetProviderID = try resolveTargetProviderID(
            for: targetProfile,
            effectiveConfigData: effectiveConfig
        )
        let rolloutFilesToUpdate: [URL] = []
        let filesToBackup = deduplicatedStandardizedFileURLs(
            store.runtimeSwitchFileURLs(
                additionalFiles: targetProfile.managedFileURLs
            )
        )

        return SwitchOperationPreview(
            targetProfile: targetProfile,
            targetProviderID: targetProviderID,
            filesToBackup: filesToBackup,
            rolloutFilesToUpdate: rolloutFilesToUpdate,
            codexWasRunning: desktopController.isRunning
        )
    }

    func perform(targetProfile: ProviderProfile) async throws -> SwitchOperationResult {
        let userVisibleTitles = captureUserVisibleThreadTitles()
        let previouslyRunning = try await desktopController.closeIfRunning()
        var restorePoint: RestorePointManifest?

        do {
            let latestPreview = try preview(targetProfile: targetProfile)
            let createdRestorePoint = try backupManager.createRestorePoint(
                reason: "safe-switch",
                summary: "Switch to \(targetProfile.displayName)",
                files: latestPreview.filesToBackup,
                codexWasRunning: previouslyRunning
            )
            restorePoint = createdRestorePoint
            preserveUserVisibleThreadTitles(userVisibleTitles, reason: "post-backup")
            let writer = ProtectedFileMutationContext(restorePoint: createdRestorePoint)
            let targetConfigData = try effectiveTargetConfigData(for: targetProfile)
            let targetConfigSummary = parseRuntimeConfig(targetConfigData)
            let mergedConfig = try mergeRuntimeConfig(
                currentConfigData: try store.currentConfigData(),
                targetConfigData: targetConfigData,
                preserveExistingProviderSections: targetProfile.authMode != .chatgpt
                    && !targetConfigSummary.usesOpenAICompatibilityProvider
            )

            try writer.write(targetProfile.runtimeMaterial.authData, to: store.currentAuthURL)
            try writer.write(mergedConfig, to: store.currentConfigURL)
            let rolloutResult = try rolloutSynchronizer.syncProviders(
                in: [store.sessionsRootURL, store.archivedSessionsRootURL],
                targetProvider: latestPreview.targetProviderID
            )
            _ = try threadProviderRelabeler.relabel(
                databaseURL: store.stateDatabaseURL,
                targetProvider: latestPreview.targetProviderID
            )
            let repairSummary = try await repairClient.rescanAndRepair()

            await quotaChannelInvalidator.invalidateAllReusableChannels()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)

            return SwitchOperationResult(
                targetProfileID: targetProfile.id,
                restorePoint: createdRestorePoint,
                updatedRolloutCount: rolloutResult.updatedFiles.count,
                repairSummary: repairSummary
            )
        } catch {
            if let restorePoint {
                do {
                    try backupManager.restoreRestorePoint(restorePoint)
                    try? resyncThreadsToCurrentRuntime()
                } catch {
                    try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
                    throw SwitchOrchestratorError.automaticRollbackFailed
                }
            }
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }

    func repairCurrentThreads() async throws -> RepairOperationResult {
        let filesToBackup = deduplicatedStandardizedFileURLs(store.protectedMutationFileURLs())
        let userVisibleTitles = captureUserVisibleThreadTitles()
        let previouslyRunning = try await desktopController.closeIfRunning()
        var restorePoint: RestorePointManifest?

        do {
            let createdRestorePoint = try backupManager.createRestorePoint(
                reason: "repair-local-threads",
                summary: "Repair local thread metadata",
                files: filesToBackup,
                codexWasRunning: previouslyRunning
            )
            restorePoint = createdRestorePoint
            preserveUserVisibleThreadTitles(userVisibleTitles, reason: "repair-post-backup")
            let repairSummary = try await repairClient.rescanAndRepair()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            return RepairOperationResult(
                restorePoint: createdRestorePoint,
                repairSummary: repairSummary
            )
        } catch {
            if let restorePoint {
                do {
                    try backupManager.restoreRestorePoint(restorePoint)
                } catch {
                    try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
                    throw SwitchOrchestratorError.automaticRollbackFailed
                }
            }
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }

    private func effectiveTargetConfigData(for targetProfile: ProviderProfile) throws -> Data? {
        if let configData = targetProfile.runtimeMaterial.configData,
           let raw = String(data: configData, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summary = parseRuntimeConfig(configData)
            if summary.usesOpenAICompatibilityProvider {
                return synthesizedOpenAICompatibleConfig(from: summary)
            }
            return configData
        }

        if targetProfile.authMode == .chatgpt {
            return Data("model_provider = \"openai\"\n".utf8)
        }

        if let threadProviderID = targetProfile.threadProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !threadProviderID.isEmpty {
            return Data("model_provider = \"\(threadProviderID)\"\n".utf8)
        }

        if let providerID = targetProfile.providerID,
           !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Data("model_provider = \"\(providerID)\"\n".utf8)
        }

        throw SwitchOrchestratorError.missingRuntimeConfig(targetProfile.displayName)
    }
    private func resolveTargetProviderID(
        for targetProfile: ProviderProfile,
        effectiveConfigData: Data?
    ) throws -> String {
        let configSummary = parseRuntimeConfig(effectiveConfigData)
        if let providerID = configSummary.threadProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return providerID
        }

        if let providerID = targetProfile.threadProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return providerID
        }

        if targetProfile.authMode == .chatgpt {
            return "openai"
        }

        throw SwitchOrchestratorError.missingProviderIdentifier(targetProfile.displayName)
    }

    private func resyncThreadsToCurrentRuntime() throws {
        guard let providerID = try currentRuntimeProviderID() else {
            return
        }
        _ = try rolloutSynchronizer.syncProviders(
            in: [store.sessionsRootURL, store.archivedSessionsRootURL],
            targetProvider: providerID
        )
        _ = try threadProviderRelabeler.relabel(
            databaseURL: store.stateDatabaseURL,
            targetProvider: providerID
        )
    }

    private func currentRuntimeProviderID() throws -> String? {
        let summary = parseRuntimeConfig(try store.currentConfigData())
        if let providerID = summary.threadProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return providerID
        }

        if resolveAuthMode(authData: try store.currentAuthData()) == .chatgpt {
            return "openai"
        }

        return nil
    }

    private func captureUserVisibleThreadTitles() -> [LocalThreadTitleCandidate] {
        do {
            return try threadTitlePreserver.captureCandidates(sessionIndexURL: store.sessionIndexURL)
        } catch {
            AppLog.safeSwitch.error("Failed to capture user-visible thread titles: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func preserveUserVisibleThreadTitles(
        _ candidates: [LocalThreadTitleCandidate],
        reason: String
    ) {
        do {
            let updatedCount = try threadTitlePreserver.preserveUserVisibleTitles(
                stateDatabaseURL: store.stateDatabaseURL,
                candidates: candidates
            )
            if updatedCount > 0 {
                AppLog.safeSwitch.info(
                    "Preserved user-visible thread titles count=\(updatedCount, privacy: .public) reason=\(reason, privacy: .public)"
                )
            }
        } catch {
            AppLog.safeSwitch.error("Failed to preserve user-visible thread titles reason=\(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

@MainActor
final class RollbackManager {
    private let backupManager: BackupManager
    private let desktopController: CodexDesktopControlling
    private let quotaChannelInvalidator: CodexRPCChannelInvalidating

    init(
        backupManager: BackupManager,
        desktopController: CodexDesktopControlling,
        quotaChannelInvalidator: CodexRPCChannelInvalidating
    ) {
        self.backupManager = backupManager
        self.desktopController = desktopController
        self.quotaChannelInvalidator = quotaChannelInvalidator
    }

    func rollbackLatest() async throws -> RestorePointManifest {
        let previouslyRunning = try await desktopController.closeIfRunning()

        do {
            let manifest = try backupManager.restoreLatestRestorePoint()
            await quotaChannelInvalidator.invalidateAllReusableChannels()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            return manifest
        } catch {
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }
}
