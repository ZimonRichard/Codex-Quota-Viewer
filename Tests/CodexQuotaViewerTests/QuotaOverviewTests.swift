import Foundation
import Testing

@testable import CodexQuotaViewer

actor ConcurrentRefreshTracker {
    private(set) var activeCount = 0
    private(set) var maxActiveCount = 0

    func begin() {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
    }

    func end() {
        activeCount -= 1
    }
}

actor FetchedKeyRecorder {
    private var keys: [String] = []

    func append(_ key: String) {
        keys.append(key)
    }

    func snapshot() -> [String] {
        keys
    }
}

@Test
func vaultQuotaCacheStorePersistsSnapshotRecords() throws {
    let harness = try makeHarness()
    let store = VaultQuotaCacheStore(cacheURL: harness.appSupportURL.appendingPathComponent("quota-cache.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let records = [
        VaultQuotaSnapshotRecord(
            accountID: "acct-chatgpt",
            snapshot: makeTestSnapshot(email: "primary@example.com", primaryRemaining: 72, secondaryRemaining: 61, fetchedAt: now),
            healthStatus: .healthy,
            errorSummary: nil,
            fetchedAt: now,
            authMode: .chatgpt,
            isCurrent: true
        ),
        VaultQuotaSnapshotRecord(
            accountID: "acct-api",
            snapshot: nil,
            healthStatus: .healthy,
            errorSummary: "Official quota unavailable",
            fetchedAt: now,
            authMode: .apiKey,
            isCurrent: false
        ),
    ]

    try store.save(records)
    let loaded = try store.load()

    #expect(loaded == records)
}

@Test
func vaultQuotaCacheStoreLoadsLegacyRecordsWithoutFailureDisposition() throws {
    let harness = try makeHarness()
    let cacheURL = harness.appSupportURL.appendingPathComponent("quota-cache.json")
    try Data(
        """
        [
          {
            "accountID": "acct-legacy",
            "authMode": "chatgpt",
            "errorSummary": "Timed out while reading quota.",
            "fetchedAt": "2027-01-01T00:00:00Z",
            "healthStatus": "readFailure",
            "isCurrent": false,
            "snapshot": null
          }
        ]
        """.utf8
    )
    .write(to: cacheURL, options: .atomic)

    let store = VaultQuotaCacheStore(cacheURL: cacheURL)
    let loaded = try store.load()

    #expect(loaded.count == 1)
    #expect(loaded.first?.accountID == "acct-legacy")
    #expect(loaded.first?.failureDisposition == nil)
}

@Test
func quotaOverviewStateOrdersBoardByCurrentThenRecentUsageAndLimitsOverviewToFiveRows() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleTime = now.addingTimeInterval(-1_000)
        let current = makeTestProviderProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "current@example.com", primaryRemaining: 84, secondaryRemaining: 74, fetchedAt: now),
            isCurrent: true,
            lastUsedAt: now
        )
        let needsLogin = makeTestProviderProfile(
            id: "needs-login",
            displayName: "needs-login@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            lastUsedAt: now.addingTimeInterval(-10),
            healthStatus: .needsLogin,
            errorMessage: "Sign in required"
        )
        let expired = makeTestProviderProfile(
            id: "expired",
            displayName: "expired@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            lastUsedAt: now.addingTimeInterval(-20),
            healthStatus: .expired,
            errorMessage: "Session expired"
        )
        let exhausted = makeTestProviderProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 44, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-30)
        )
        let stale = makeTestProviderProfile(
            id: "stale",
            displayName: "stale@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "stale@example.com", primaryRemaining: 65, secondaryRemaining: 58, fetchedAt: staleTime),
            lastUsedAt: now.addingTimeInterval(-40)
        )
        let healthyA = makeTestProviderProfile(
            id: "healthy-a",
            displayName: "healthy-a@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "healthy-a@example.com", primaryRemaining: 76, secondaryRemaining: 67, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-50)
        )
        let healthyB = makeTestProviderProfile(
            id: "healthy-b",
            displayName: "healthy-b@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "healthy-b@example.com", primaryRemaining: 92, secondaryRemaining: 88, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-60)
        )
        let healthyHidden = makeTestProviderProfile(
            id: "healthy-hidden",
            displayName: "healthy-hidden@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "healthy-hidden@example.com", primaryRemaining: 91, secondaryRemaining: 77, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-70)
        )
        let api = makeTestProviderProfile(
            id: "api",
            displayName: "api account",
            authMode: .apiKey,
            snapshot: nil,
            lastUsedAt: now.addingTimeInterval(-80),
            healthStatus: .healthy,
            errorMessage: nil
        )

        let state = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [needsLogin, expired, exhausted, stale, healthyA, healthyB, healthyHidden, api],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(state.chatGPTCount == 8)
        #expect(state.apiCount == 1)
        #expect(state.boardTiles.count == 5)
        #expect(state.boardTiles.map { $0.profile.id } == ["current", "needs-login", "expired", "exhausted", "stale"])
    }
}

@Test
func quotaOverviewStateKeepsCurrentAccountFirstBeforeMoreRecentProfiles() {
    let now = Date(timeIntervalSince1970: 1_800_000_020)
    let currentOfficial = makeTestProviderProfile(
        id: "official-current",
        displayName: "official@example.com",
        authMode: .chatgpt,
        snapshot: makeTestSnapshot(
            email: "official@example.com",
            primaryRemaining: 82,
            secondaryRemaining: 71,
            fetchedAt: now
        ),
        isCurrent: true,
        lastUsedAt: now.addingTimeInterval(-120)
    )
    let recentAPI = makeTestProviderProfile(
        id: "svip",
        displayName: "svip",
        authMode: .apiKey,
        snapshot: makeTestAPISnapshot(
            primaryRemaining: 51,
            secondaryRemaining: 55,
            fetchedAt: now
        ),
        lastUsedAt: now
    )
    let olderOfficial = makeTestProviderProfile(
        id: "older",
        displayName: "older@example.com",
        authMode: .chatgpt,
        snapshot: makeTestSnapshot(
            email: "older@example.com",
            primaryRemaining: 70,
            secondaryRemaining: 60,
            fetchedAt: now
        ),
        lastUsedAt: now.addingTimeInterval(-240)
    )

    let state = buildQuotaOverviewState(
        currentProfile: currentOfficial,
        vaultProfiles: [recentAPI, olderOfficial],
        refreshIntervalPreset: .fiveMinutes,
        now: now
    )

    #expect(state.boardTiles.map(\.profile.id) == ["official-current", "svip", "older"])
}

@Test
func quotaOverviewStateKeepsCurrentPlaceholderBeforeCPAPoolParent() {
    let now = Date(timeIntervalSince1970: 1_800_000_030)
    let currentOfficial = makeTestProviderProfile(
        id: "official-current",
        displayName: "official@example.com",
        authMode: .chatgpt,
        snapshot: nil,
        isCurrent: true,
        lastUsedAt: now.addingTimeInterval(-120),
        healthStatus: .readFailure,
        errorMessage: "Refresh failed"
    )
    let apiParent = makeTestProviderProfile(
        id: "svip",
        displayName: "svip",
        authMode: .apiKey,
        snapshot: makeTestAPISnapshot(
            primaryRemaining: 51,
            secondaryRemaining: 55,
            fetchedAt: now
        ),
        lastUsedAt: now
    )
    let poolMember = makeTestProviderProfile(
        id: "svip::cpa::codex_plus_2",
        displayName: "codex_plus_2",
        authMode: .apiKey,
        snapshot: makeTestAPISnapshot(
            primaryRemaining: 51,
            secondaryRemaining: 55,
            fetchedAt: now
        ),
        source: .cpaPoolMember,
        cpaPoolParentID: apiParent.id,
        cpaPoolParentDisplayName: apiParent.displayName,
        isCPAPoolCurrentRoute: true
    )

    let state = buildQuotaOverviewState(
        currentProfile: currentOfficial,
        vaultProfiles: [apiParent, poolMember],
        refreshIntervalPreset: .fiveMinutes,
        now: now
    )

    #expect(Array(state.boardTiles.map(\.profile.id).prefix(2)) == ["official-current", "svip"])
}

@Test
func quotaOverviewStateBuildsAllAccountsSections() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let current = makeTestProviderProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "current@example.com", primaryRemaining: 81, secondaryRemaining: 79, fetchedAt: now),
            isCurrent: true,
            lastUsedAt: now
        )
        let exhausted = makeTestProviderProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 20, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-10),
            healthStatus: .healthy,
            errorMessage: nil
        )
        let healthy = makeTestProviderProfile(
            id: "healthy",
            displayName: "healthy@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "healthy@example.com", primaryRemaining: 66, secondaryRemaining: 64, fetchedAt: now),
            lastUsedAt: now.addingTimeInterval(-20)
        )
        let api = makeTestProviderProfile(
            id: "api",
            displayName: "api account",
            authMode: .apiKey,
            snapshot: nil,
            lastUsedAt: now.addingTimeInterval(-30),
            healthStatus: .healthy,
            errorMessage: nil
        )

        let state = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [exhausted, healthy, api],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(state.sections.map { $0.title } == ["Available Quota", "Quota Exhausted", "API Accounts"])
        #expect(state.sections[0].profiles.map { $0.id } == ["current", "healthy"])
        #expect(state.sections[1].profiles.map { $0.id } == ["exhausted"])
        #expect(state.sections[2].profiles.map { $0.id } == ["api"])
    }
}

@Test
func quotaOverviewStateUsesCPAQuotaForCurrentAPIAccount() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_140)
        let apiRuntime = makeTestRuntimeMaterial(
            id: "local-cpa-api",
            authMode: .apiKey,
            apiBaseURL: "http://127.0.0.1:3001/v1",
            model: "gpt-5.5"
        )
        let current = makeTestProviderProfile(
            id: stableAccountRecordID(for: apiRuntime),
            displayName: "svip",
            authMode: .apiKey,
            snapshot: CodexSnapshot(
                account: CodexAccount(type: "apiKey", email: nil, planType: nil),
                rateLimits: RateLimitSnapshot(
                    limitId: nil,
                    limitName: nil,
                    primary: nil,
                    secondary: nil,
                    planType: nil
                ),
                fetchedAt: now
            ),
            source: .current,
            isCurrent: true,
            runtimeMaterial: apiRuntime,
            quotaFetchedAt: now
        )
        let savedWithCPAQuota = makeTestProviderProfile(
            id: stableAccountRecordID(for: apiRuntime),
            displayName: "svip",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 23,
                secondaryRemaining: 85,
                fetchedAt: now.addingTimeInterval(5)
            ),
            runtimeMaterial: apiRuntime,
            quotaFetchedAt: now.addingTimeInterval(5)
        )

        let state = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [savedWithCPAQuota],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(state.chatGPTCount == 0)
        #expect(state.apiCount == 1)
        #expect(state.boardTiles.map { $0.profile.id } == [current.id])
        #expect(state.boardTiles.first?.primaryText == "5h 23%")
        #expect(state.boardTiles.first?.secondaryText == "1w 85%")
        #expect(state.sections.map(\.title) == ["API Accounts"])
        #expect(state.sections.first?.profiles.first?.isCurrent == true)
        #expect(
            allAccountsMenuText(
                for: state.sections.first!.profiles.first!,
                refreshIntervalPreset: .fiveMinutes,
                now: now
            ) == "svip · 5h 23% · 1w 85%"
        )
    }
}

@Test
func quotaOverviewStateKeepsCPAPoolMembersNestedBelowAPIParent() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_160)
        let current = makeTestProviderProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(
                email: "current@example.com",
                primaryRemaining: 81,
                secondaryRemaining: 79,
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now
        )
        let apiParent = makeTestProviderProfile(
            id: "api-parent",
            displayName: "svip",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 51,
                secondaryRemaining: 8,
                fetchedAt: now
            ),
            lastUsedAt: now.addingTimeInterval(-10)
        )
        let exhaustedMember = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-1",
            displayName: "codex_plus_1",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 0,
                secondaryRemaining: 37,
                fetchedAt: now.addingTimeInterval(-30)
            ),
            source: .cpaPoolMember,
            lastUsedAt: now.addingTimeInterval(-30),
            cpaPoolParentID: apiParent.id,
            cpaPoolParentDisplayName: apiParent.displayName,
            isCPAPoolCurrentRoute: false,
            cpaPoolReasoningEffort: "xhigh",
            cpaPoolStatusCode: 429
        )
        let routedMember = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-2",
            displayName: "codex_plus_2",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 51,
                secondaryRemaining: 8,
                fetchedAt: now.addingTimeInterval(-20)
            ),
            source: .cpaPoolMember,
            lastUsedAt: now.addingTimeInterval(-20),
            cpaPoolParentID: apiParent.id,
            cpaPoolParentDisplayName: apiParent.displayName,
            isCPAPoolCurrentRoute: true,
            cpaPoolReasoningEffort: "xhigh",
            cpaPoolStatusCode: 200
        )

        let state = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [apiParent, exhaustedMember, routedMember],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(state.chatGPTCount == 1)
        #expect(state.apiCount == 1)
        #expect(state.boardTiles.map(\.profile.id) == ["current", "api-parent"])
        #expect(state.sections.map(\.title) == [
            "Available Quota",
            "API Accounts",
        ])
        #expect(state.sections[1].profiles.map(\.id) == ["api-parent"])
        let poolMembers = state.cpaPoolMembersByParentID["api-parent"] ?? []
        #expect(poolMembers.map(\.id) == [
            "api-parent::cpa::codex-plus-1",
            "api-parent::cpa::codex-plus-2",
        ])
        let primaryReset = makeTestTimeText(Date(timeIntervalSince1970: 1_800_000_360))
        let secondaryReset = makeTestMonthDayTimeText(Date(timeIntervalSince1970: 1_800_086_400))
        let routedUpdated = makeTestShortDateTimeText(now.addingTimeInterval(-20))
        let exhaustedUpdated = makeTestShortDateTimeText(now.addingTimeInterval(-30))
        #expect(
            allAccountsMenuText(
                for: poolMembers[0],
                refreshIntervalPreset: .fiveMinutes,
                now: now
            ) == "codex_plus_1 · standby · gpt-5.4 · xhigh · HTTP 429 · 5h 0% / \(primaryReset) · 1w 37% / \(secondaryReset) · updated \(exhaustedUpdated)"
        )
        #expect(
            allAccountsMenuText(
                for: poolMembers[1],
                refreshIntervalPreset: .fiveMinutes,
                now: now
            ) == "codex_plus_2 · current · gpt-5.4 · xhigh · HTTP 200 · 5h 51% / \(primaryReset) · 1w 8% / \(secondaryReset) · updated \(routedUpdated)"
        )
    }
}

@Test
func quotaOverviewStateShowsAPIParentWhenOnlyCPAPoolPlaceholdersExist() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        let emptySnapshot = CodexSnapshot(
            account: CodexAccount(type: "apiKey", email: nil, planType: nil),
            rateLimits: RateLimitSnapshot(
                limitId: nil,
                limitName: nil,
                primary: nil,
                secondary: nil,
                planType: nil
            ),
            fetchedAt: now
        )
        let apiParent = makeTestProviderProfile(
            id: "api-parent",
            displayName: "svip",
            authMode: .apiKey,
            snapshot: emptySnapshot,
            lastUsedAt: now
        )
        let firstMember = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-1",
            displayName: "codex_plus_1",
            authMode: .apiKey,
            snapshot: emptySnapshot,
            source: .cpaPoolMember,
            lastUsedAt: now,
            cpaPoolParentID: apiParent.id,
            cpaPoolParentDisplayName: apiParent.displayName
        )
        let secondMember = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-2",
            displayName: "codex_plus_2",
            authMode: .apiKey,
            snapshot: emptySnapshot,
            source: .cpaPoolMember,
            lastUsedAt: now,
            cpaPoolParentID: apiParent.id,
            cpaPoolParentDisplayName: apiParent.displayName
        )

        let state = buildQuotaOverviewState(
            currentProfile: nil,
            vaultProfiles: [apiParent, firstMember, secondMember],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(state.apiCount == 1)
        #expect(state.boardTiles.map(\.profile.id) == ["api-parent"])
        #expect(state.boardTiles.first?.primaryText == AppLocalization.quotaUnavailableLabel())
        #expect(state.sections.map(\.title) == ["API Accounts"])
        #expect(state.sections.first?.profiles.map(\.id) == ["api-parent"])
        #expect(state.cpaPoolMembersByParentID["api-parent"]?.map(\.id) == [
            "api-parent::cpa::codex-plus-1",
            "api-parent::cpa::codex-plus-2",
        ])
    }
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorRefreshesChatGPTAccountEvenIfCachedAsCurrent() async {
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let refreshedAt = now.addingTimeInterval(120)
    let currentRuntime = makeTestRuntimeMaterial(id: "current-runtime", authMode: .chatgpt)
    let staleRuntime = makeTestRuntimeMaterial(id: "stale-runtime", authMode: .chatgpt)
    let currentRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: currentRuntime),
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: currentRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let staleRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: staleRuntime),
            displayName: "stale@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: staleRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeTestSnapshot(
            email: "current@example.com",
            primaryRemaining: 81,
            secondaryRemaining: 79,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )

    var fetchCount = 0
    let coordinator = VaultQuotaRefreshCoordinator { runtimeMaterial, _ in
        fetchCount += 1
        #expect(stableAccountRecordID(for: runtimeMaterial) == staleRecord.id)
        return makeTestSnapshot(
            email: "refreshed@example.com",
            primaryRemaining: 68,
            secondaryRemaining: 55,
            fetchedAt: refreshedAt
        )
    }

    let finalRecords = await withCheckedContinuation { continuation in
        var didResume = false
        coordinator.requestRefresh(
            .init(
                currentProfile: currentProfile,
                vaultAccounts: [currentRecord, staleRecord],
                cachedRecords: [
                    VaultQuotaSnapshotRecord(
                        accountID: staleRecord.id,
                        snapshot: makeTestSnapshot(
                            email: "stale@example.com",
                            primaryRemaining: 10,
                            secondaryRemaining: 5,
                            fetchedAt: now.addingTimeInterval(-600)
                        ),
                        healthStatus: .healthy,
                        errorSummary: nil,
                        fetchedAt: now.addingTimeInterval(-600),
                        authMode: .chatgpt,
                        isCurrent: true
                    )
                ]
            )
        ) { records in
            guard !didResume,
                  let refreshed = records.first(where: {
                      $0.accountID == staleRecord.id && $0.snapshot?.account.email == "refreshed@example.com"
                  }) else {
                return
            }
            didResume = true
            continuation.resume(returning: records)
            #expect(refreshed.isCurrent == false)
        }
    }

    #expect(fetchCount == 1)
    #expect(finalRecords.map(\.accountID).sorted() == [currentRecord.id, staleRecord.id].sorted())
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorDropsCachedAccountsThatAreNoLongerSaved() async {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let currentRuntime = makeTestRuntimeMaterial(id: "current-runtime", authMode: .chatgpt)
    let currentRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: currentRuntime),
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: currentRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeTestSnapshot(
            email: "current@example.com",
            primaryRemaining: 81,
            secondaryRemaining: 79,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )
    let coordinator = VaultQuotaRefreshCoordinator { _, _ in
        Issue.record("snapshotFetcher should not run for the current-only request")
        return makeTestSnapshot(
            email: "unexpected@example.com",
            primaryRemaining: 0,
            secondaryRemaining: 0,
            fetchedAt: now
        )
    }

    let records = await withCheckedContinuation { continuation in
        var didResume = false
        coordinator.requestRefresh(
            .init(
                currentProfile: currentProfile,
                vaultAccounts: [currentRecord],
                cachedRecords: [
                    VaultQuotaSnapshotRecord(
                        accountID: "ghost-account",
                        snapshot: makeTestSnapshot(
                            email: "ghost@example.com",
                            primaryRemaining: 22,
                            secondaryRemaining: 18,
                            fetchedAt: now.addingTimeInterval(-300)
                        ),
                        healthStatus: .healthy,
                        errorSummary: nil,
                        fetchedAt: now.addingTimeInterval(-300),
                        authMode: .chatgpt,
                        isCurrent: false
                    )
                ]
            )
        ) { latest in
            guard !didResume, latest.count == 1 else {
                return
            }
            didResume = true
            continuation.resume(returning: latest)
        }
    }

    #expect(records.count == 1)
    #expect(records.first?.accountID == currentRecord.id)
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorCoalescesEquivalentRequestsWithoutSecondFetchRound() async {
    let now = Date(timeIntervalSince1970: 1_800_000_220)
    let runtimeMaterial = makeTestRuntimeMaterial(id: "coalesced-runtime", authMode: .chatgpt)
    let record = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: runtimeMaterial),
            displayName: "coalesced@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: runtimeMaterial
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    var fetchCount = 0
    let coordinator = VaultQuotaRefreshCoordinator { _, _ in
        fetchCount += 1
        try await Task.sleep(nanoseconds: 40_000_000)
        return makeTestSnapshot(
            email: "coalesced@example.com",
            primaryRemaining: 64,
            secondaryRemaining: 52,
            fetchedAt: now
        )
    }
    let request = VaultQuotaRefreshCoordinator.Request(
        currentProfile: nil,
        vaultAccounts: [record],
        cachedRecords: []
    )

    let records = await withCheckedContinuation { continuation in
        var resumed = false
        coordinator.requestRefresh(
            request,
            onUpdate: { _ in }
        ) { _ in
            Issue.record("The superseded completion handler should not fire.")
        }
        coordinator.requestRefresh(
            request,
            onUpdate: { _ in }
        ) { latest in
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: latest)
        }
    }

    #expect(fetchCount == 1)
    #expect(records.count == 1)
    #expect(records.first?.accountID == record.id)
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorCurrentOnlyScopePreservesCachedNonCurrentRecordsWithoutFetchingThem() async {
    let now = Date(timeIntervalSince1970: 1_800_000_240)
    let currentRuntime = makeTestRuntimeMaterial(id: "current-only-runtime", authMode: .chatgpt)
    let savedRuntime = makeTestRuntimeMaterial(id: "saved-runtime", authMode: .chatgpt)
    let currentRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: currentRuntime),
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: currentRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let savedRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: savedRuntime),
            displayName: "saved@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: savedRuntime
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeTestSnapshot(
            email: "current@example.com",
            primaryRemaining: 90,
            secondaryRemaining: 80,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )

    var fetchCount = 0
    let coordinator = VaultQuotaRefreshCoordinator { _, _ in
        fetchCount += 1
        return makeTestSnapshot(
            email: "unexpected@example.com",
            primaryRemaining: 0,
            secondaryRemaining: 0,
            fetchedAt: now
        )
    }

    let records = await withCheckedContinuation { continuation in
        var didResume = false
        coordinator.requestRefresh(
            .init(
                currentProfile: currentProfile,
                vaultAccounts: [currentRecord, savedRecord],
                cachedRecords: [
                    VaultQuotaSnapshotRecord(
                        accountID: savedRecord.id,
                        snapshot: makeTestSnapshot(
                            email: "saved@example.com",
                            primaryRemaining: 35,
                            secondaryRemaining: 25,
                            fetchedAt: now.addingTimeInterval(-600)
                        ),
                        healthStatus: .healthy,
                        errorSummary: nil,
                        fetchedAt: now.addingTimeInterval(-600),
                        authMode: .chatgpt,
                        isCurrent: false
                    )
                ],
                refreshPolicy: .currentOnly
            )
        ) { latest in
            guard !didResume, latest.count == 2 else {
                return
            }
            didResume = true
            continuation.resume(returning: latest)
        }
    }

    #expect(fetchCount == 0)
    #expect(records.first(where: { $0.accountID == currentRecord.id })?.snapshot?.account.email == "current@example.com")
    #expect(records.first(where: { $0.accountID == savedRecord.id })?.snapshot?.account.email == "saved@example.com")
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorBoundsConcurrentAllAccountsFetches() async {
    let now = Date(timeIntervalSince1970: 1_800_000_260)
    let tracker = ConcurrentRefreshTracker()
    let records = (1...4).map { index in
        makeTestVaultRecord(
            from: makeTestProviderProfile(
                id: "acct-\(index)",
                displayName: "account-\(index)@example.com",
                authMode: .chatgpt,
                snapshot: nil,
                runtimeMaterial: makeTestRuntimeMaterial(
                    id: "runtime-\(index)",
                    authMode: .chatgpt,
                    accountID: "acct-\(index)"
                )
            ),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
    let coordinator = VaultQuotaRefreshCoordinator(maxConcurrentChatGPTRefreshes: 2) { runtimeMaterial, _ in
        await tracker.begin()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await tracker.end()
        return makeTestSnapshot(
            email: "\(stableAccountRecordID(for: runtimeMaterial))@example.com",
            primaryRemaining: 60,
            secondaryRemaining: 50,
            fetchedAt: now
        )
    }

    let refreshed = await withCheckedContinuation { continuation in
        var didResume = false
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: records,
                cachedRecords: [],
                refreshPolicy: .manualFull
            )
        ) { latest in
            guard !didResume, latest.count == records.count, latest.allSatisfy({ $0.snapshot != nil }) else {
                return
            }
            didResume = true
            continuation.resume(returning: latest)
        }
    }

    #expect(refreshed.count == 4)
    #expect(await tracker.maxActiveCount <= 2)
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorMenuOpenSelectiveRefreshesOnlyStaleExpiredTransientAndUncachedAccounts() async {
    let now = Date(timeIntervalSince1970: 1_800_000_300)
    let staleRuntime = makeTestRuntimeMaterial(id: "stale", authMode: .chatgpt)
    let expiredRuntime = makeTestRuntimeMaterial(id: "expired", authMode: .chatgpt)
    let transientRuntime = makeTestRuntimeMaterial(id: "transient", authMode: .chatgpt)
    let uncachedRuntime = makeTestRuntimeMaterial(id: "uncached", authMode: .chatgpt)
    let healthyRuntime = makeTestRuntimeMaterial(id: "healthy", authMode: .chatgpt)
    let needsLoginRuntime = makeTestRuntimeMaterial(id: "login", authMode: .chatgpt)
    let terminalRuntime = makeTestRuntimeMaterial(id: "terminal", authMode: .chatgpt)
    let apiRuntime = makeTestRuntimeMaterial(id: "api", authMode: .apiKey)

    let records = [
        makeTestVaultRecord(from: makeTestProviderProfile(id: stableAccountRecordID(for: staleRuntime), displayName: "stale@example.com", authMode: .chatgpt, snapshot: nil, runtimeMaterial: staleRuntime), createdAt: now),
        makeTestVaultRecord(from: makeTestProviderProfile(id: stableAccountRecordID(for: expiredRuntime), displayName: "expired@example.com", authMode: .chatgpt, snapshot: nil, runtimeMaterial: expiredRuntime), createdAt: now),
        makeTestVaultRecord(from: makeTestProviderProfile(id: stableAccountRecordID(for: transientRuntime), displayName: "transient@example.com", authMode: .chatgpt, snapshot: nil, runtimeMaterial: transientRuntime), createdAt: now),
        makeTestVaultRecord(from: makeTestProviderProfile(id: stableAccountRecordID(for: uncachedRuntime), displayName: "uncached@example.com", authMode: .chatgpt, snapshot: nil, runtimeMaterial: uncachedRuntime), createdAt: now),
        makeTestVaultRecord(from: makeTestProviderProfile(id: stableAccountRecordID(for: healthyRuntime), displayName: "healthy@example.com", authMode: .chatgpt, snapshot: nil, runtimeMaterial: healthyRuntime), createdAt: now),
        makeTestVaultRecord(from: makeTestProviderProfile(id: stableAccountRecordID(for: needsLoginRuntime), displayName: "login@example.com", authMode: .chatgpt, snapshot: nil, runtimeMaterial: needsLoginRuntime), createdAt: now),
        makeTestVaultRecord(from: makeTestProviderProfile(id: stableAccountRecordID(for: terminalRuntime), displayName: "terminal@example.com", authMode: .chatgpt, snapshot: nil, runtimeMaterial: terminalRuntime), createdAt: now),
        makeTestVaultRecord(from: makeTestProviderProfile(id: stableAccountRecordID(for: apiRuntime), displayName: "api@example.com", authMode: .apiKey, snapshot: nil, runtimeMaterial: apiRuntime), createdAt: now),
    ]

    let staleFetchedAt = now.addingTimeInterval(-1_000)
    let freshFetchedAt = now.addingTimeInterval(-60)
    let fetchedKeys = FetchedKeyRecorder()
    let coordinator = VaultQuotaRefreshCoordinator(nowProvider: { now }) { runtimeMaterial, _ in
        await fetchedKeys.append(stableAccountRecordID(for: runtimeMaterial))
        return makeTestSnapshot(
            email: "\(stableAccountRecordID(for: runtimeMaterial))@example.com",
            primaryRemaining: 60,
            secondaryRemaining: 50,
            fetchedAt: now
        )
    }

    let finalRecords = await withCheckedContinuation { continuation in
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: records,
                cachedRecords: [
                    VaultQuotaSnapshotRecord(
                        accountID: stableAccountRecordID(for: staleRuntime),
                        snapshot: makeTestSnapshot(email: "stale@example.com", primaryRemaining: 70, secondaryRemaining: 60, fetchedAt: staleFetchedAt),
                        healthStatus: .healthy,
                        errorSummary: nil,
                        fetchedAt: staleFetchedAt,
                        authMode: .chatgpt,
                        isCurrent: false
                    ),
                    VaultQuotaSnapshotRecord(
                        accountID: stableAccountRecordID(for: expiredRuntime),
                        snapshot: nil,
                        healthStatus: .expired,
                        errorSummary: "Session expired",
                        fetchedAt: freshFetchedAt,
                        authMode: .chatgpt,
                        isCurrent: false
                    ),
                    VaultQuotaSnapshotRecord(
                        accountID: stableAccountRecordID(for: transientRuntime),
                        snapshot: nil,
                        healthStatus: .readFailure,
                        errorSummary: "Timed out while reading quota.",
                        failureDisposition: .transient,
                        fetchedAt: freshFetchedAt,
                        authMode: .chatgpt,
                        isCurrent: false
                    ),
                    VaultQuotaSnapshotRecord(
                        accountID: stableAccountRecordID(for: healthyRuntime),
                        snapshot: makeTestSnapshot(email: "healthy@example.com", primaryRemaining: 75, secondaryRemaining: 65, fetchedAt: freshFetchedAt),
                        healthStatus: .healthy,
                        errorSummary: nil,
                        fetchedAt: freshFetchedAt,
                        authMode: .chatgpt,
                        isCurrent: false
                    ),
                    VaultQuotaSnapshotRecord(
                        accountID: stableAccountRecordID(for: needsLoginRuntime),
                        snapshot: nil,
                        healthStatus: .needsLogin,
                        errorSummary: "Sign in required",
                        fetchedAt: freshFetchedAt,
                        authMode: .chatgpt,
                        isCurrent: false
                    ),
                    VaultQuotaSnapshotRecord(
                        accountID: stableAccountRecordID(for: terminalRuntime),
                        snapshot: nil,
                        healthStatus: .readFailure,
                        errorSummary: "Refresh failed",
                        failureDisposition: .terminal,
                        fetchedAt: freshFetchedAt,
                        authMode: .chatgpt,
                        isCurrent: false
                    ),
                ],
                refreshPolicy: .menuOpenSelective(staleAfter: staleThreshold(for: .fiveMinutes))
            )
        ) { _ in
        } onComplete: { latest in
            continuation.resume(returning: latest)
        }
    }

    let actualFetchedKeys = Set(await fetchedKeys.snapshot())
    let expectedFetchedKeys = Set([
        stableAccountRecordID(for: staleRuntime),
        stableAccountRecordID(for: expiredRuntime),
        stableAccountRecordID(for: transientRuntime),
        stableAccountRecordID(for: uncachedRuntime),
    ])
    #expect(actualFetchedKeys == expectedFetchedKeys)
    #expect(finalRecords.contains(where: { $0.accountID == stableAccountRecordID(for: uncachedRuntime) && $0.snapshot != nil }))
    #expect(finalRecords.first(where: { $0.accountID == stableAccountRecordID(for: apiRuntime) })?.snapshot == nil)
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorPublishesAPIPlaceholderBatchInSingleUpdate() async {
    let now = Date(timeIntervalSince1970: 1_800_000_350)
    let apiRuntimeA = makeTestRuntimeMaterial(id: "api-a", authMode: .apiKey)
    let apiRuntimeB = makeTestRuntimeMaterial(id: "api-b", authMode: .apiKey)
    let records = [
        makeTestVaultRecord(
            from: makeTestProviderProfile(
                id: stableAccountRecordID(for: apiRuntimeA),
                displayName: "api-a@example.com",
                authMode: .apiKey,
                snapshot: nil,
                runtimeMaterial: apiRuntimeA
            ),
            createdAt: now
        ),
        makeTestVaultRecord(
            from: makeTestProviderProfile(
                id: stableAccountRecordID(for: apiRuntimeB),
                displayName: "api-b@example.com",
                authMode: .apiKey,
                snapshot: nil,
                runtimeMaterial: apiRuntimeB
            ),
            createdAt: now
        ),
    ]
    let coordinator = VaultQuotaRefreshCoordinator(nowProvider: { now }) { _, _ in
        Issue.record("snapshotFetcher should not run for API-only placeholder refreshes")
        return makeTestSnapshot(
            email: "unexpected@example.com",
            primaryRemaining: 0,
            secondaryRemaining: 0,
            fetchedAt: now
        )
    }

    var updates: [[VaultQuotaSnapshotRecord]] = []
    let finalRecords = await withCheckedContinuation { continuation in
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: records,
                cachedRecords: [],
                refreshPolicy: .manualFull
            ),
            onUpdate: { latest in
                updates.append(latest)
            },
            onComplete: { latest in
                continuation.resume(returning: latest)
            }
        )
    }

    #expect(updates.count == 1)
    #expect(updates.first?.count == 2)
    #expect(Set(finalRecords.map(\.accountID)) == Set(records.map(\.id)))
    #expect(finalRecords.allSatisfy { $0.snapshot == nil && $0.authMode == .apiKey })
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorReadsAPIQuotaWhenFetcherIsAvailable() async {
    let now = Date(timeIntervalSince1970: 1_800_000_360)
    let apiRuntime = makeTestRuntimeMaterial(
        id: "cpa-api",
        authMode: .apiKey,
        apiBaseURL: "http://127.0.0.1:3001/v1"
    )
    let record = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: apiRuntime),
            displayName: "svip",
            authMode: .apiKey,
            snapshot: nil,
            runtimeMaterial: apiRuntime
        ),
        createdAt: now
    )
    var requestedDisplayName: String?
    var requestedTimeout: TimeInterval?
    let coordinator = VaultQuotaRefreshCoordinator(
        nowProvider: { now },
        snapshotFetcher: { _, _ in
            Issue.record("ChatGPT snapshot fetcher should not run for API quota refreshes.")
            return makeTestSnapshot(
                email: "unexpected@example.com",
                primaryRemaining: 0,
                secondaryRemaining: 0,
                fetchedAt: now
            )
        },
        apiQuotaSnapshotFetcher: { _, displayName, timeout in
            requestedDisplayName = displayName
            requestedTimeout = timeout
            let parentSnapshot = makeTestAPISnapshot(
                primaryRemaining: 31,
                secondaryRemaining: 88,
                fetchedAt: now
            )
            let poolSnapshot = CPAPoolQuotaSnapshot(
                id: "codex_plus_2.json",
                displayName: "codex_plus_2",
                authFile: "codex_plus_2.json",
                authIndex: "auth-index",
                sourceHint: nil,
                isCurrentRoute: true,
                snapshot: parentSnapshot,
                model: "gpt-5.5",
                reasoningEffort: "xhigh",
                statusCode: 200,
                failed: false,
                requestID: "abcd1234"
            )
            return APIQuotaFetchResult(snapshot: parentSnapshot, poolSnapshots: [poolSnapshot])
        }
    )

    let finalRecords = await withCheckedContinuation { continuation in
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: [record],
                cachedRecords: [],
                refreshPolicy: .manualFull
            )
        ) { _ in
        } onComplete: { latest in
            continuation.resume(returning: latest)
        }
    }

    #expect(requestedDisplayName == "svip")
    #expect(requestedTimeout == VaultQuotaRefreshCoordinator.RefreshPolicy.manualFull.apiQuotaTimeout)
    #expect(finalRecords.count == 1)
    #expect(finalRecords.first?.authMode == .apiKey)
    #expect(finalRecords.first?.snapshot?.account.type == "apiKey")
    #expect(finalRecords.first?.poolSnapshots.first?.displayName == "codex_plus_2")
    #expect(finalRecords.first?.poolSnapshots.first?.isCurrentRoute == true)
    #expect(quotaDisplayWindows(from: finalRecords.first?.snapshot).map(compactWindowSummary) == ["5h31%", "1w88%"])
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorMarksAPIQuotaFailureWithoutDiscardingCachedPool() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_385)
    let runtime = makeTestRuntimeMaterial(id: "api-quota-failure", authMode: .apiKey)
    let profile = makeTestProviderProfile(
        id: "api-account",
        displayName: "svip",
        authMode: .apiKey,
        snapshot: nil,
        runtimeMaterial: runtime
    )
    let record = makeTestVaultRecord(
        from: profile,
        source: .manualAPI,
        createdAt: now
    )
    let cachedSnapshot = makeTestAPISnapshot(
        primaryRemaining: 47,
        secondaryRemaining: 81,
        fetchedAt: now.addingTimeInterval(-60)
    )
    let cachedPoolSnapshot = CPAPoolQuotaSnapshot(
        id: "codex_plus_1.json",
        displayName: "codex_plus_1",
        authFile: "codex_plus_1.json",
        authIndex: "auth-index",
        sourceHint: nil,
        isCurrentRoute: true,
        snapshot: cachedSnapshot,
        model: "gpt-5.5",
        reasoningEffort: "xhigh",
        statusCode: 200,
        failed: false,
        requestID: "abcd1234"
    )
    let cachedRecord = VaultQuotaSnapshotRecord(
        accountID: record.id,
        snapshot: cachedSnapshot,
        poolSnapshots: [cachedPoolSnapshot],
        healthStatus: .healthy,
        errorSummary: nil,
        fetchedAt: cachedSnapshot.fetchedAt,
        authMode: .apiKey,
        isCurrent: false
    )
    let coordinator = VaultQuotaRefreshCoordinator(
        nowProvider: { now },
        snapshotFetcher: { _, _ in
            Issue.record("ChatGPT snapshot fetcher should not run for API quota refreshes.")
            return cachedSnapshot
        },
        apiQuotaSnapshotFetcher: { _, _, _ in
            throw CPAQuotaSnapshotError.commandFailed("CPA bridge command failed.")
        }
    )

    let finalRecords = await withCheckedContinuation { continuation in
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: [record],
                cachedRecords: [cachedRecord],
                refreshPolicy: .manualFull
            )
        ) { _ in
        } onComplete: { latest in
            continuation.resume(returning: latest)
        }
    }

    let finalRecord = try #require(finalRecords.first)
    #expect(finalRecord.healthStatus == .readFailure)
    #expect(finalRecord.failureDisposition == .transient)
    #expect(finalRecord.snapshot == cachedSnapshot)
    #expect(finalRecord.poolSnapshots == [cachedPoolSnapshot])
    #expect(finalRecord.errorSummary?.contains("CPA bridge") == true)
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorKeepsCachedPoolWhenCPAHasNoLiveQuotaRecord() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_390)
    let runtime = makeTestRuntimeMaterial(id: "api-no-live-quota", authMode: .apiKey)
    let profile = makeTestProviderProfile(
        id: "api-account",
        displayName: "svip",
        authMode: .apiKey,
        snapshot: nil,
        runtimeMaterial: runtime
    )
    let record = makeTestVaultRecord(
        from: profile,
        source: .manualAPI,
        createdAt: now
    )
    let cachedSnapshot = makeTestAPISnapshot(
        primaryRemaining: 47,
        secondaryRemaining: 81,
        fetchedAt: now.addingTimeInterval(-60)
    )
    let cachedPoolSnapshot = CPAPoolQuotaSnapshot(
        id: "codex_plus_1.json",
        displayName: "codex_plus_1",
        authFile: "codex_plus_1.json",
        authIndex: "auth-index",
        sourceHint: nil,
        isCurrentRoute: true,
        snapshot: cachedSnapshot,
        model: "gpt-5.5",
        reasoningEffort: "xhigh",
        statusCode: 200,
        failed: false,
        requestID: "abcd1234"
    )
    let cachedRecord = VaultQuotaSnapshotRecord(
        accountID: record.id,
        snapshot: cachedSnapshot,
        poolSnapshots: [cachedPoolSnapshot],
        healthStatus: .healthy,
        errorSummary: nil,
        fetchedAt: cachedSnapshot.fetchedAt,
        authMode: .apiKey,
        isCurrent: false
    )
    let coordinator = VaultQuotaRefreshCoordinator(
        nowProvider: { now },
        snapshotFetcher: { _, _ in
            Issue.record("ChatGPT snapshot fetcher should not run for API quota refreshes.")
            return cachedSnapshot
        },
        apiQuotaSnapshotFetcher: { _, _, _ in
            throw CPAQuotaSnapshotError.noQuotaRecord
        }
    )

    let finalRecords = await withCheckedContinuation { continuation in
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: [record],
                cachedRecords: [cachedRecord],
                refreshPolicy: .manualFull
            )
        ) { _ in
        } onComplete: { latest in
            continuation.resume(returning: latest)
        }
    }

    let finalRecord = try #require(finalRecords.first)
    #expect(finalRecord.healthStatus == .readFailure)
    #expect(finalRecord.failureDisposition == .transient)
    #expect(finalRecord.snapshot == cachedSnapshot)
    #expect(finalRecord.poolSnapshots == [cachedPoolSnapshot])
    #expect(finalRecord.errorSummary?.isEmpty == false)
}

@Test
func staleCPAPoolMemberKeepsRawQuotaInsteadOfResettingToFull() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_390)
        let member = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-1",
            displayName: "codex_plus_1",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 0,
                secondaryRemaining: 76,
                fetchedAt: now.addingTimeInterval(-300)
            ),
            source: .cpaPoolMember,
            lastUsedAt: now.addingTimeInterval(-300),
            healthStatus: .readFailure,
            errorMessage: "No live CPA quota record was found.",
            quotaFailureDisposition: .transient,
            cpaPoolParentID: "api-parent",
            cpaPoolParentDisplayName: "svip",
            isCPAPoolCurrentRoute: false,
            cpaPoolReasoningEffort: "xhigh",
            cpaPoolStatusCode: 200
        )

        let text = allAccountsMenuText(
            for: member,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(text.contains("stale data"))
        #expect(text.contains("5h 0%"))
        #expect(text.contains("5h 100%") == false)
        #expect(text.contains("1w 76%"))
    }
}

@Test
func cpaPoolMemberMenuHidesProbeInternalsAndHighlightsScheduledRoute() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        let member = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-2",
            displayName: "codex_plus_2",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 42,
                secondaryRemaining: 51,
                fetchedAt: now
            ),
            source: .cpaPoolMember,
            lastUsedAt: now,
            cpaPoolParentID: "api-parent",
            cpaPoolParentDisplayName: "svip",
            isCPAPoolRoutePreferred: true,
            cpaPoolReasoningEffort: "read-only",
            cpaPoolStatusCode: nil
        )

        let text = allAccountsMenuText(
            for: member,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(text.contains("scheduled route"))
        #expect(text.contains("5h 42%"))
        #expect(text.contains("1w 51%"))
        #expect(text.contains("quota-probe") == false)
        #expect(text.contains("read-only") == false)
        #expect(text.contains("HTTP --") == false)
        #expect(text.contains(" · --") == false)
    }
}

@Test
func cpaPoolMemberMenuDistinguishesLatestHitFromScheduledRoute() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_470)
        let member = makeTestProviderProfile(
            id: "api-parent::cpa::codex_plus_1",
            displayName: "codex_plus_1",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 42,
                secondaryRemaining: 88,
                fetchedAt: now
            ),
            source: .cpaPoolMember,
            cpaPoolParentID: "api-parent",
            cpaPoolParentDisplayName: "svip",
            isCPAPoolLatestRequestRoute: true
        )

        let text = allAccountsMenuText(
            for: member,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(text.contains("latest hit"))
        #expect(text.contains("current") == false)
    }
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorReportsProgressAcrossReusedPlaceholderAndFetchedAccounts() async {
    let now = Date(timeIntervalSince1970: 1_800_000_380)
    let currentRuntime = makeTestRuntimeMaterial(id: "progress-current", authMode: .chatgpt)
    let apiRuntime = makeTestRuntimeMaterial(id: "progress-api", authMode: .apiKey)
    let refreshRuntime = makeTestRuntimeMaterial(id: "progress-refresh", authMode: .chatgpt)

    let currentRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: currentRuntime),
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: currentRuntime
        ),
        createdAt: now
    )
    let apiRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: apiRuntime),
            displayName: "api@example.com",
            authMode: .apiKey,
            snapshot: nil,
            runtimeMaterial: apiRuntime
        ),
        createdAt: now
    )
    let refreshRecord = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: refreshRuntime),
            displayName: "refresh@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: refreshRuntime
        ),
        createdAt: now
    )
    let currentProfile = buildProviderProfile(
        id: currentRecord.id,
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeTestSnapshot(
            email: "current@example.com",
            primaryRemaining: 81,
            secondaryRemaining: 79,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )

    let coordinator = VaultQuotaRefreshCoordinator(nowProvider: { now }) { runtimeMaterial, _ in
        #expect(stableAccountRecordID(for: runtimeMaterial) == refreshRecord.id)
        return makeTestSnapshot(
            email: "refresh@example.com",
            primaryRemaining: 66,
            secondaryRemaining: 54,
            fetchedAt: now
        )
    }

    var progressUpdates: [RefreshProgress] = []
    let finalRecords = await withCheckedContinuation { continuation in
        coordinator.requestRefresh(
            .init(
                currentProfile: currentProfile,
                vaultAccounts: [currentRecord, apiRecord, refreshRecord],
                cachedRecords: [],
                refreshPolicy: .manualFull
            ),
            onProgress: { progress in
                progressUpdates.append(progress)
            },
            onUpdate: { _ in },
            onComplete: { latest in
                continuation.resume(returning: latest)
            }
        )
    }

    #expect(progressUpdates == [
        RefreshProgress(completedCount: 1, totalCount: 3),
        RefreshProgress(completedCount: 2, totalCount: 3),
        RefreshProgress(completedCount: 3, totalCount: 3),
    ])
    #expect(finalRecords.count == 3)
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorRetriesTransientFailuresOnceForMenuOpenSelective() async {
    let now = Date(timeIntervalSince1970: 1_800_000_400)
    let runtime = makeTestRuntimeMaterial(id: "retry-target", authMode: .chatgpt)
    let record = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: runtime),
            displayName: "retry@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: runtime
        ),
        createdAt: now
    )

    var timeouts: [TimeInterval] = []
    var attempts = 0
    let coordinator = VaultQuotaRefreshCoordinator { _, timeout in
        attempts += 1
        timeouts.append(timeout)
        if attempts == 1 {
            throw CodexRPCError.timeout
        }
        return makeTestSnapshot(
            email: "retry@example.com",
            primaryRemaining: 55,
            secondaryRemaining: 45,
            fetchedAt: now
        )
    }

    let refreshed = await withCheckedContinuation { continuation in
        var resumed = false
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: [record],
                cachedRecords: [],
                refreshPolicy: .menuOpenSelective(staleAfter: staleThreshold(for: .fiveMinutes))
            )
        ) { latest in
            guard !resumed, latest.first?.snapshot?.account.email == "retry@example.com" else {
                return
            }
            resumed = true
            continuation.resume(returning: latest)
        }
    }

    #expect(refreshed.count == 1)
    #expect(attempts == 2)
    #expect(timeouts == [6, 12])
}

@MainActor
@Test
func vaultQuotaRefreshCoordinatorDoesNotRetryTerminalFailures() async {
    let now = Date(timeIntervalSince1970: 1_800_000_450)
    let runtime = makeTestRuntimeMaterial(id: "terminal-target", authMode: .chatgpt)
    let record = makeTestVaultRecord(
        from: makeTestProviderProfile(
            id: stableAccountRecordID(for: runtime),
            displayName: "terminal@example.com",
            authMode: .chatgpt,
            snapshot: nil,
            runtimeMaterial: runtime
        ),
        createdAt: now
    )

    var attempts = 0
    let coordinator = VaultQuotaRefreshCoordinator { _, _ in
        attempts += 1
        throw CodexRPCError.invalidResponse("malformed")
    }

    let refreshed = await withCheckedContinuation { continuation in
        var resumed = false
        coordinator.requestRefresh(
            .init(
                currentProfile: nil,
                vaultAccounts: [record],
                cachedRecords: [],
                refreshPolicy: .menuOpenSelective(staleAfter: staleThreshold(for: .fiveMinutes))
            )
        ) { latest in
            guard !resumed,
                  let first = latest.first,
                  first.snapshot == nil,
                  first.failureDisposition == .terminal else {
                return
            }
            resumed = true
            continuation.resume(returning: latest)
        }
    }

    #expect(refreshed.count == 1)
    #expect(attempts == 1)
    #expect(refreshed.first?.failureDisposition == .terminal)
}

@Test
func exhaustedAccountMenuTextShowsResetScheduleInsteadOfPercentages() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let exhausted = makeTestProviderProfile(
            id: "exhausted",
            displayName: "exhausted@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(email: "exhausted@example.com", primaryRemaining: 0, secondaryRemaining: 20, fetchedAt: now),
            lastUsedAt: now,
            healthStatus: .healthy,
            errorMessage: nil
        )

        let text = allAccountsMenuText(
            for: exhausted,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        let timeFormatter = DateFormatter()
        timeFormatter.locale = AppLocalization.locale
        timeFormatter.dateFormat = "HH:mm"

        #expect(text.contains("5h \(timeFormatter.string(from: Date(timeIntervalSince1970: 1_800_000_360)))"))
        #expect(text.contains("1w \(makeTestMonthDayTimeText(Date(timeIntervalSince1970: 1_800_086_400)))"))
        #expect(text.contains("5h 0%") == false)
    }
}

@Test
func quotaOverviewDeduplicatesCurrentAndSavedProfilesByStableIdentity() {
    let now = Date(timeIntervalSince1970: 1_800_000_300)
    let currentRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","tokens":{"access_token":"token-current","account_id":"acct-identity-1"}}
            """.utf8
        ),
        configData: Data("model_provider = \"openai\"\n".utf8)
    )
    let savedRuntime = ProfileRuntimeMaterial(
        authData: Data(
            """
            {"auth_mode":"chatgpt","tokens":{"access_token":"token-saved","account_id":"acct-identity-1"}}
            """.utf8
        ),
        configData: Data(
            """
            model_provider = "custom"

            [model_providers.custom]
            name = "custom"
            requires_openai_auth = true
            base_url = "https://shell.wyzai.top/v1"
            """.utf8
        )
    )

    let current = buildProviderProfile(
        id: stableAccountRecordID(for: currentRuntime),
        fallbackDisplayName: "current@example.com",
        source: .current,
        runtimeMaterial: currentRuntime,
        snapshot: makeTestSnapshot(
            email: "current@example.com",
            primaryRemaining: 81,
            secondaryRemaining: 72,
            fetchedAt: now
        ),
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: true,
        quotaFetchedAt: now
    )
    let saved = buildProviderProfile(
        id: stableAccountRecordID(for: savedRuntime),
        fallbackDisplayName: "Kris Team",
        source: .vault,
        runtimeMaterial: savedRuntime,
        snapshot: nil,
        healthStatus: .healthy,
        errorMessage: nil,
        isCurrent: false,
        lastUsedAt: now.addingTimeInterval(-60),
        quotaFetchedAt: nil
    )

    let state = buildQuotaOverviewState(
        currentProfile: current,
        vaultProfiles: [saved],
        refreshIntervalPreset: .fiveMinutes,
        now: now
    )

    #expect(state.chatGPTCount == 1)
    #expect(state.boardTiles.map { $0.profile.id } == [stableAccountRecordID(for: currentRuntime)])
    #expect(state.sections.count == 1)
    #expect(state.sections[0].profiles.count == 1)
}

@Test
func freeWeeklyOnlyAccountUsesWeeklyLabelsAndExhaustedSection() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let free = makeTestProviderProfile(
            id: "free",
            displayName: "ai.krisxu@gmail.com",
            authMode: .chatgpt,
            snapshot: makeTestFreeWeeklySnapshot(
                email: "ai.krisxu@gmail.com",
                weeklyRemaining: 0,
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now,
            healthStatus: .healthy,
            errorMessage: nil
        )

        let state = buildQuotaOverviewState(
            currentProfile: free,
            vaultProfiles: [],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(quotaTileState(for: free, refreshIntervalPreset: .fiveMinutes, now: now) == .lowQuota)
        #expect(state.sections.map { $0.title } == ["Quota Exhausted"])
        #expect(state.sections[0].profiles.map { $0.id } == ["free"])
        #expect(state.boardTiles.map { $0.profile.id } == ["free"])
        #expect(state.boardTiles[0].primaryText == "1w 0%")
        #expect(state.boardTiles[0].secondaryText.contains("1w "))

        let text = allAccountsMenuText(
            for: free,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )
        #expect(text.contains("5h") == false)
        #expect(text.contains("1w") == true)
    }
}

@Test
func freeWeeklyOnlyAccountWithQuotaRemainsAvailable() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        let free = makeTestProviderProfile(
            id: "free",
            displayName: "ai.krisxu@gmail.com",
            authMode: .chatgpt,
            snapshot: makeTestFreeWeeklySnapshot(
                email: "ai.krisxu@gmail.com",
                weeklyRemaining: 63,
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now,
            healthStatus: .healthy,
            errorMessage: nil
        )

        let state = buildQuotaOverviewState(
            currentProfile: free,
            vaultProfiles: [],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        #expect(quotaTileState(for: free, refreshIntervalPreset: .fiveMinutes, now: now) == .healthy)
        #expect(state.sections.map { $0.title } == ["Available Quota"])
        #expect(state.sections[0].profiles.map { $0.id } == ["free"])
        #expect(state.boardTiles[0].primaryText == "1w 63%")
        #expect(state.boardTiles[0].secondaryText.isEmpty)

        let text = allAccountsMenuText(
            for: free,
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )
        #expect(text == "ai.krisxu@gmail.com · 1w 63%")
    }
}

@Test
func quotaWorkPlanKeepsDailyQuotaShareFixedWhenAllHoursHaveSameWeight() {
    let calendar = Calendar(identifier: .gregorian)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = start.addingTimeInterval(24 * 60 * 60)
    let halfway = start.addingTimeInterval(12 * 60 * 60)
    let allHeavy = QuotaWorkPlanSettings(
        isEnabled: true,
        hourlyModes: Array(repeating: .intensive, count: 24)
    )

    #expect(
        abs(
            allHeavy.expectedRemainingPercent(
                startDate: start,
                resetDate: reset,
                now: halfway,
                calendar: calendar
            ) - 50
        ) < 0.001
    )
}

@Test
func quotaWorkPlanUsesStopPointAsDailyTarget() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0))!
    let reset = start.addingTimeInterval(24 * 60 * 60)
    let modes = Array(repeating: QuotaWorkPlanHourMode.paused, count: 12)
        + Array(repeating: QuotaWorkPlanHourMode.normal, count: 12)
    let workPlan = QuotaWorkPlanSettings(isEnabled: true, hourlyModes: modes)
    let duringOffHours = start.addingTimeInterval(6 * 60 * 60)
    let halfActiveElapsed = start.addingTimeInterval(18 * 60 * 60)

    #expect(
        abs(
            workPlan.expectedRemainingPercent(
                startDate: start,
                resetDate: reset,
                now: duringOffHours,
                calendar: calendar
            ) - 100
        ) < 0.001
    )
    #expect(
        abs(
            workPlan.expectedRemainingPercent(
                startDate: start,
                resetDate: reset,
                now: halfActiveElapsed,
                calendar: calendar
            )
        ) < 0.001
    )
}

@Test
func quotaWorkPlanShowsUpcomingStopTargetDuringWorkPeriod() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
    let reset = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 11))!
    let windowStart = reset.addingTimeInterval(-7 * 24 * 60 * 60)
    let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 12))!
    let workPlan = QuotaWorkPlanSettings(
        isEnabled: true,
        offPeriods: [QuotaWorkPlanPeriod(startMinuteOfDay: 2 * 60, endMinuteOfDay: 10 * 60)]
    )
    let oneUsableHourBeforeReset = 100.0 / (7.0 * 16.0)

    #expect(
        abs(
            workPlan.expectedRemainingPercent(
                startDate: windowStart,
                resetDate: reset,
                now: now,
                calendar: calendar
            ) - oneUsableHourBeforeReset
        ) < 0.001
    )
}

@Test
func quotaWorkPlanFinalOffPeriodBeforeResetLeavesNoPlannedRemainingQuota() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let windowStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10))!
    let reset = calendar.date(from: DateComponents(year: 2026, month: 1, day: 8, hour: 10))!
    let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 8, hour: 2))!
    let workPlan = QuotaWorkPlanSettings(
        isEnabled: true,
        offPeriods: [QuotaWorkPlanPeriod(startMinuteOfDay: 2 * 60, endMinuteOfDay: 10 * 60)]
    )

    #expect(
        abs(
            workPlan.expectedRemainingPercent(
                startDate: windowStart,
                resetDate: reset,
                now: now,
                calendar: calendar
            )
        ) < 0.001
    )
}

@Test
func quotaWorkPlanTwentyThreeHourOffPeriodOnlyConsumesDuringUsableHour() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let windowStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10))!
    let reset = calendar.date(from: DateComponents(year: 2026, month: 1, day: 8, hour: 10))!
    let afterFifthUsableHour = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 11))!
    let workPlan = QuotaWorkPlanSettings(
        isEnabled: true,
        offPeriods: [QuotaWorkPlanPeriod(startMinuteOfDay: 11 * 60, endMinuteOfDay: 10 * 60)]
    )

    #expect(workPlan.availableMinutesPerDay == 60)
    #expect(
        abs(
            workPlan.expectedRemainingPercent(
                startDate: windowStart,
                resetDate: reset,
                now: afterFifthUsableHour,
                calendar: calendar
            ) - (2.0 / 7.0 * 100)
        ) < 0.001
    )
}

@Test
func quotaOverviewRowUsesWorkPlanForWeeklyTheoryText() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 6))!
        let reset = calendar.date(from: DateComponents(year: 2026, month: 1, day: 8, hour: 0))!
        let modes = Array(repeating: QuotaWorkPlanHourMode.paused, count: 12)
            + Array(repeating: QuotaWorkPlanHourMode.normal, count: 12)
        let workPlan = QuotaWorkPlanSettings(isEnabled: true, hourlyModes: modes)
        let profile = makeTestProviderProfile(
            id: "planned",
            displayName: "planned@example.com",
            authMode: .chatgpt,
            snapshot: CodexSnapshot(
                account: CodexAccount(type: "chatgpt", email: "planned@example.com", planType: "plus"),
                rateLimits: RateLimitSnapshot(
                    limitId: nil,
                    limitName: nil,
                    primary: nil,
                    secondary: RateLimitWindow(
                        usedPercent: 20,
                        windowDurationMins: 10_080,
                        resetsAt: Int(reset.timeIntervalSince1970)
                    ),
                    planType: "plus"
                ),
                fetchedAt: now
            )
        )

        let texts = quotaOverviewRowQuotaTexts(
            for: profile,
            quotaWorkPlan: workPlan,
            now: now
        )

        #expect(texts.secondaryRemainingText == "1w 80%/100%")
        #expect(texts.secondaryPaceState == .overGuard)
    }
}

@Test
func quotaOverviewRowColorsFiveHourQuotaByRemainingThreshold() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func texts(primaryRemaining: Double) -> QuotaOverviewRowQuotaTexts {
        quotaOverviewRowQuotaTexts(
            for: makeTestProviderProfile(
                id: "threshold-\(primaryRemaining)",
                displayName: "threshold@example.com",
                authMode: .chatgpt,
                snapshot: makeTestSnapshot(
                    email: "threshold@example.com",
                    primaryRemaining: primaryRemaining,
                    secondaryRemaining: 80,
                    fetchedAt: now
                )
            ),
            now: now
        )
    }

    let tenPercent = texts(primaryRemaining: 10)
    #expect(tenPercent.primaryRemainingText == "5h 10%")
    #expect(tenPercent.primaryPaceState == nil)

    let ninePercent = texts(primaryRemaining: 9)
    #expect(ninePercent.primaryRemainingText == "5h 9%")
    #expect(ninePercent.primaryPaceState == .withinGuard)

    let zeroPercent = texts(primaryRemaining: 0)
    #expect(zeroPercent.primaryRemainingText == "5h 0%")
    #expect(zeroPercent.primaryPaceState == .overGuard)
}

@Test
func quotaWorkPlanFallsBackToNormalWhenAllHoursArePaused() {
    let workPlan = QuotaWorkPlanSettings(
        isEnabled: true,
        hourlyModes: Array(repeating: .paused, count: 24)
    )

    #expect(workPlan.effectiveHourlyModes == Array(repeating: .normal, count: 24))
    #expect(workPlan.dailyRelativeWeight == 1_440)
}
