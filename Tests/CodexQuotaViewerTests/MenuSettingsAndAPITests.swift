import AppKit
import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func menuTrackingGateDefersRebuildUntilMenuCloses() {
    var gate = MenuTrackingGate()

    gate.beginTracking()
    #expect(gate.requestRebuild() == false)
    #expect(gate.hasPendingRebuild == true)
    #expect(gate.finishTracking() == true)
    #expect(gate.hasPendingRebuild == false)
}

@Test
func deferredMenuPresentationQueueDrainsAfterMenuCloses() {
    var queue = DeferredMenuPresentationQueue()
    queue.enqueue(.settings)
    queue.enqueue(.settings)

    #expect(queue.actions == [.settings])
    #expect(queue.drain() == [.settings])
    #expect(queue.actions.isEmpty)
}

@MainActor
@Test
func quotaWorkPlanMenuToggleViewResizesWithMenuWidth() {
    let view = QuotaWorkPlanMenuToggleView()

    #expect(view.frame.width == QuotaWorkPlanMenuToggleView.minimumWidth)
    #expect(view.intrinsicContentSize.width == QuotaWorkPlanMenuToggleView.minimumWidth)

    view.resizeToMenuWidth(620.2)
    #expect(view.frame.width == 621)
    #expect(view.intrinsicContentSize.width == 621)

    view.resizeToMenuWidth(300)
    #expect(view.frame.width == QuotaWorkPlanMenuToggleView.minimumWidth)
    #expect(view.intrinsicContentSize.width == QuotaWorkPlanMenuToggleView.minimumWidth)
}

@Test
func settingsAccountSectionsGroupAndSortAccountsForHumanScanning() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sections = buildSettingsAccountSections([
            SettingsAccountPresentationInput(
                id: "current",
                title: "current@example.com",
                authMode: .chatgpt,
                state: .healthy,
                isCurrent: true,
                lastUsedAt: now,
                host: nil,
                model: nil
            ),
            SettingsAccountPresentationInput(
                id: "healthy",
                title: "healthy@example.com",
                authMode: .chatgpt,
                state: .healthy,
                isCurrent: false,
                lastUsedAt: now.addingTimeInterval(-10),
                host: nil,
                model: nil
            ),
            SettingsAccountPresentationInput(
                id: "limited",
                title: "limited@example.com",
                authMode: .chatgpt,
                state: .limited,
                isCurrent: false,
                lastUsedAt: now.addingTimeInterval(-5),
                host: nil,
                model: nil
            ),
            SettingsAccountPresentationInput(
                id: "api",
                title: "api.example.com",
                authMode: .apiKey,
                state: .healthy,
                isCurrent: false,
                lastUsedAt: now.addingTimeInterval(-20),
                host: "api.example.com",
                model: "gpt-5.4"
            ),
        ])

        #expect(sections.map(\.title) == ["Current Account (1)", "ChatGPT Accounts (2)", "API Accounts (1)"])
        #expect(sections[0].items.map(\.id) == ["current"])
        #expect(sections[1].items.map(\.id) == ["healthy", "limited"])
        #expect(sections[2].items.map(\.id) == ["api"])
    }
}

@Test
func profileLastUsedComparatorPrefersMostRecentUsageThenTitle() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(
        profileLastUsedComparator(
            lhsLastUsedAt: now,
            lhsDisplayName: "zeta@example.com",
            rhsLastUsedAt: now.addingTimeInterval(-10),
            rhsDisplayName: "alpha@example.com"
        )
    )
    #expect(
        profileLastUsedComparator(
            lhsLastUsedAt: now,
            lhsDisplayName: "alpha@example.com",
            rhsLastUsedAt: now,
            rhsDisplayName: "beta@example.com"
        )
    )
    #expect(
        profileLastUsedComparator(
            lhsLastUsedAt: nil,
            lhsDisplayName: "alpha@example.com",
            rhsLastUsedAt: nil,
            rhsDisplayName: "beta@example.com"
        )
    )
}

@Test
func settingsAccountSectionsIncludeLocalizedHealthHints() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let sections = buildSettingsAccountSections([
            SettingsAccountPresentationInput(
                id: "attention",
                title: "attention@example.com",
                authMode: .chatgpt,
                state: .attention,
                isCurrent: false,
                lastUsedAt: nil,
                host: nil,
                model: nil
            ),
            SettingsAccountPresentationInput(
                id: "api",
                title: "api.example.com",
                authMode: .apiKey,
                state: .healthy,
                isCurrent: false,
                lastUsedAt: nil,
                host: "api.example.com",
                model: "gpt-5.4"
            ),
        ])

        #expect(sections[0].items[0].subtitle.contains("Needs attention"))
        #expect(sections[1].items[0].subtitle.contains("Healthy"))
    }
}

@Test
func settingsAccountPanelBuilderMarksCurrentAndAttentionStatesConsistently() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let currentProfile = makeTestProviderProfile(
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
        let apiProfile = makeTestProviderProfile(
            id: "api",
            displayName: "api.example.com",
            authMode: .apiKey,
            snapshot: nil,
            isCurrent: false,
            lastUsedAt: now.addingTimeInterval(-20),
            healthStatus: .readFailure
        )

        let panelState = buildSettingsAccountPanelState(
            vaultSnapshot: AccountVaultSnapshot(
                accounts: [
                    makeTestVaultRecord(from: currentProfile),
                    makeTestVaultRecord(from: apiProfile),
                ]
            ),
            vaultProfiles: [apiProfile],
            currentProviderProfile: currentProfile,
            refreshIntervalPreset: RefreshIntervalPreset.fiveMinutes,
            actionsEnabled: false
        )

        #expect(panelState.importStatusText == "Local vault: 2 saved account(s)")
        #expect(panelState.actionsEnabled == false)
        #expect(panelState.sections.map(\.title) == ["Current Account (1)", "API Accounts (1)"])
        #expect(panelState.sections[0].items[0].isCurrent)
        #expect(panelState.sections[1].items[0].subtitle.contains("Needs attention"))
    }
}

@Test
func apiAutoConfigNormalizesURLAndChoosesGeneralPurposeModel() {
    let fallback = try! buildFallbackAPIAccountDraft(
        apiKey: "sk-test",
        rawBaseURL: "shell.wyzai.top"
    )

    #expect(fallback.displayName == "shell.wyzai.top")
    #expect(fallback.normalizedBaseURL == "https://shell.wyzai.top/v1")
    #expect(fallback.model == "gpt-5.4")

    let preferred = preferredModelID(
        from: [
            "text-embedding-3-large",
            "gpt-4o",
            "moderation-latest",
        ]
    )

    #expect(preferred == "gpt-4o")
}

@Test
func apiAutoConfigRejectsInvalidFallbackBaseURL() {
    #expect(throws: APIAccountAutoConfigurationError.invalidBaseURL) {
        try buildFallbackAPIAccountDraft(
            apiKey: "sk-test",
            rawBaseURL: "://bad-url"
        )
    }
}

@Test
func apiStatusTextUsesAPIAsPrimaryLabel() {
    let details = APIKeyProfileDetails(
        providerName: "openai",
        baseURL: "https://api.example.com/v1",
        model: "gpt-5.4",
        keyHint: "...1234"
    )

    let texts = apiKeyStatusTexts(details: details)

    #expect(texts.0 == "API")
    #expect(texts.1 == "gpt-5.4 · api.example.com · ...1234")
}

@Test
func chatGPTProviderModeMenuPresentationUsesAccountStateSpecificTitles() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])

        let inactive = buildChatGPTProviderModeMenuPresentation(
            modeState: nil,
            currentAuthMode: .chatgpt,
            savedAPIAccountCount: 1,
            isPerformingSafeSwitchOperation: false
        )
        let apiLoginInactive = buildChatGPTProviderModeMenuPresentation(
            modeState: nil,
            currentAuthMode: .apiKey,
            savedAPIAccountCount: 1,
            isPerformingSafeSwitchOperation: false
        )
        let active = buildChatGPTProviderModeMenuPresentation(
            modeState: ChatGPTProviderModeState(
                restorePointID: "restore-1",
                providerAccountID: "api-1",
                providerDisplayName: "api.example.com",
                activatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            currentAuthMode: .chatgpt,
            savedAPIAccountCount: 1,
            isPerformingSafeSwitchOperation: false
        )

        #expect(inactive.title == "切换为第三方 Provider…")
        #expect(inactive.isEnabled)
        #expect(apiLoginInactive.title == "切换为第三方 Provider…")
        #expect(apiLoginInactive.isEnabled == false)
        #expect(active.title == "切换回正常账号")
        #expect(active.isEnabled)
    }
}

@Test
func allAccountsMenuItemPresentationUsesCurrentCheckmarkAndDirectSwitchForOthers() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
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
        let other = makeTestProviderProfile(
            id: "other",
            displayName: "other@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(
                email: "other@example.com",
                primaryRemaining: 77,
                secondaryRemaining: 73,
                fetchedAt: now
            ),
            isCurrent: false,
            lastUsedAt: now.addingTimeInterval(-20)
        )

        let currentItem = buildAllAccountsMenuItemPresentation(
            for: current,
            refreshIntervalPreset: .fiveMinutes,
            now: now,
            isPerformingSafeSwitchOperation: false
        )
        let otherItem = buildAllAccountsMenuItemPresentation(
            for: other,
            refreshIntervalPreset: .fiveMinutes,
            now: now,
            isPerformingSafeSwitchOperation: false
        )

        #expect(currentItem.showsCheckmark == true)
        #expect(currentItem.isEnabled == true)
        #expect(currentItem.triggersDirectSwitch == false)
        #expect(currentItem.title.contains("Selected") == false)

        #expect(otherItem.showsCheckmark == false)
        #expect(otherItem.isEnabled == true)
        #expect(otherItem.triggersDirectSwitch == true)
    }
}

@MainActor
@Test
func quotaOverviewMenuShowsCPAPoolMembersOnAPIParentRow() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_180)
        let apiParent = makeTestProviderProfile(
            id: "api-parent",
            displayName: "svip",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 51,
                secondaryRemaining: 8,
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now
        )
        let routedMember = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-2",
            displayName: "codex_plus_2",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 51,
                secondaryRemaining: 8,
                fetchedAt: now
            ),
            source: .cpaPoolMember,
            lastUsedAt: now,
            cpaPoolParentID: apiParent.id,
            cpaPoolParentDisplayName: apiParent.displayName,
            isCPAPoolCurrentRoute: true,
            cpaPoolReasoningEffort: "xhigh",
            cpaPoolStatusCode: 200
        )
        let exhaustedMember = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-1",
            displayName: "codex_plus_1",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 0,
                secondaryRemaining: 37,
                fetchedAt: now.addingTimeInterval(-60)
            ),
            source: .cpaPoolMember,
            lastUsedAt: now.addingTimeInterval(-60),
            cpaPoolParentID: apiParent.id,
            cpaPoolParentDisplayName: apiParent.displayName,
            cpaPoolReasoningEffort: "xhigh",
            cpaPoolStatusCode: 429
        )
        let state = buildQuotaOverviewState(
            currentProfile: apiParent,
            vaultProfiles: [routedMember, exhaustedMember],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        let items = buildQuotaOverviewMenuItems(
            quotaOverviewState: state,
            refreshIntervalPreset: .fiveMinutes,
            isPerformingSafeSwitchOperation: false,
            target: nil,
            activateSavedAccountAction: #selector(NSResponder.cancelOperation(_:))
        )

        let apiParentItem = try #require(items.first { $0.title == "svip" })
        let detailsMenu = try #require(apiParentItem.submenu)
        let currentItem = try #require(detailsMenu.items.first)
        let poolHeader = try #require(detailsMenu.items.dropFirst(2).first)
        let exhaustedItem = try #require(detailsMenu.items.dropFirst(3).first)
        let routedItem = try #require(detailsMenu.items.dropFirst(4).first)

        #expect(apiParentItem.isEnabled == true)
        #expect(detailsMenu.items.count == 5)
        #expect(currentItem.title == "Current API Account")
        #expect(currentItem.isEnabled == false)
        #expect(currentItem.view is CPAPoolMenuActionRowView)
        let currentActionRow = try #require(currentItem.view as? CPAPoolMenuActionRowView)
        #expect(currentActionRow.model.isPrimaryAction == false)
        #expect(color(currentActionRow.model.titleColor, isCloseTo: testCPAPoolCurrentTextColor))
        #expect(detailsMenu.items[1].isSeparatorItem == true)
        #expect(poolHeader.title == "CPA Pool Members")
        #expect(poolHeader.isEnabled == false)
        #expect(poolHeader.view is CPAPoolMenuSectionHeaderView)
        assertTextFieldsStayInsideBounds(try #require(currentItem.view))
        assertTextFieldsStayInsideBounds(try #require(poolHeader.view))
        let primaryReset = makeTestTimeText(Date(timeIntervalSince1970: 1_800_000_360))
        let secondaryReset = makeTestMonthDayTimeText(Date(timeIntervalSince1970: 1_800_086_400))
        let routedUpdated = makeTestShortDateTimeText(now)
        let exhaustedUpdated = makeTestShortDateTimeText(now.addingTimeInterval(-60))
        #expect(exhaustedItem.title == "codex_plus_1 · standby · gpt-5.4 · xhigh · HTTP 429 · 5h 0% / \(primaryReset) · 1w 37% / \(secondaryReset) · updated \(exhaustedUpdated)")
        #expect(exhaustedItem.isEnabled == true)
        #expect(exhaustedItem.action == nil)
        let exhaustedRow = try #require(exhaustedItem.view as? CPAPoolMemberMenuRowView)
        let exhaustedPrimary = try #require(findLabel(in: exhaustedRow) { $0 == "5h 0%" })
        #expect(findLabel(in: exhaustedRow) { $0 == "5h \(primaryReset)" } != nil)
        #expect(findLabel(in: exhaustedRow) { $0 == "1w \(secondaryReset)" } != nil)
        let exhaustedUpdatedLabel = try #require(findLabel(in: exhaustedRow) { $0.contains("updated \(exhaustedUpdated)") })
        #expect(exhaustedUpdatedLabel.stringValue.hasPrefix("updated \(exhaustedUpdated)"))
        assertLabelIsLeftAligned(in: exhaustedRow, exhaustedUpdatedLabel)
        assertLabelsShareRow(in: exhaustedRow, exhaustedUpdatedLabel, "5h \(primaryReset)")
        assertLabelsShareRow(in: exhaustedRow, exhaustedUpdatedLabel, "1w \(secondaryReset)")
        assertTextFieldsStayInsideBounds(exhaustedRow)
        #expect(color(exhaustedPrimary.textColor, isCloseTo: testCPAPoolCriticalTextColor))
        #expect(routedItem.title == "codex_plus_2 · current · gpt-5.4 · xhigh · HTTP 200 · 5h 51% / \(primaryReset) · 1w 8% / \(secondaryReset) · updated \(routedUpdated)")
        #expect(routedItem.isEnabled == true)
        #expect(routedItem.action == nil)
        #expect(routedItem.state == .on)
        let routedRow = try #require(routedItem.view as? CPAPoolMemberMenuRowView)
        let routeLabel = try #require(findLabel(in: routedRow) { $0 == "current" })
        let routedSecondary = try #require(findLabel(in: routedRow) { $0 == "1w 8%" })
        #expect(findLabel(in: routedRow) { $0 == "5h \(primaryReset)" } != nil)
        #expect(findLabel(in: routedRow) { $0 == "1w \(secondaryReset)" } != nil)
        let routedUpdatedLabel = try #require(findLabel(in: routedRow) { $0.contains("updated \(routedUpdated)") })
        #expect(routedUpdatedLabel.stringValue.hasPrefix("updated \(routedUpdated)"))
        assertLabelIsLeftAligned(in: routedRow, routedUpdatedLabel)
        assertLabelsShareRow(in: routedRow, routedUpdatedLabel, "5h \(primaryReset)")
        assertLabelsShareRow(in: routedRow, routedUpdatedLabel, "1w \(secondaryReset)")
        assertTextFieldsStayInsideBounds(routedRow)
        #expect(color(routeLabel.textColor, isCloseTo: testCPAPoolCurrentTextColor))
        #expect(color(routedSecondary.textColor, isCloseTo: testCPAPoolWarningTextColor))

        let allAccountsItem = try #require(items.last)
        let allAccountsMenu = try #require(allAccountsItem.submenu)
        let allAccountsAPIParentItem = try #require(allAccountsMenu.items.first { $0.title.hasPrefix("svip") })
        #expect(allAccountsAPIParentItem.submenu == nil)
    }
}

@MainActor
@Test
func quotaOverviewAPIPoolHoverMenuOffersSwitchActionForNonCurrentParent() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_190)
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
        let routedMember = makeTestProviderProfile(
            id: "api-parent::cpa::codex-plus-2",
            displayName: "codex_plus_2",
            authMode: .apiKey,
            snapshot: makeTestAPISnapshot(
                primaryRemaining: 51,
                secondaryRemaining: 8,
                fetchedAt: now
            ),
            source: .cpaPoolMember,
            cpaPoolParentID: apiParent.id,
            cpaPoolParentDisplayName: apiParent.displayName,
            isCPAPoolCurrentRoute: true
        )
        let state = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [apiParent, routedMember],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        let items = buildQuotaOverviewMenuItems(
            quotaOverviewState: state,
            refreshIntervalPreset: .fiveMinutes,
            isPerformingSafeSwitchOperation: false,
            target: nil,
            activateSavedAccountAction: #selector(NSResponder.cancelOperation(_:))
        )

        let apiParentItem = try #require(items.first { $0.title == "svip" })
        let switchItem = try #require(apiParentItem.submenu?.items.first)

        #expect(apiParentItem.action != #selector(NSResponder.cancelOperation(_:)))
        #expect(switchItem.title == "Switch to svip")
        #expect(switchItem.isEnabled == true)
        #expect(switchItem.action == #selector(NSResponder.cancelOperation(_:)))
        #expect(switchItem.representedObject as? String == "api-parent")
        let switchActionRow = try #require(switchItem.view as? CPAPoolMenuActionRowView)
        #expect(switchActionRow.model.detail == "API account")
        #expect(switchActionRow.model.isPrimaryAction == true)
        #expect(color(switchActionRow.model.titleColor, isCloseTo: .systemBlue))
    }
}

@MainActor
@Test
func quotaOverviewMenuRowsUseCustomViewAndShowDualQuotaColumns() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_120)
        let api = makeTestProviderProfile(
            id: "api",
            displayName: "api.example.com",
            authMode: .apiKey,
            snapshot: nil,
            isCurrent: false,
            lastUsedAt: now
        )
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
        let tile = QuotaTileViewModel(
            profile: current,
            primaryText: "5h 81%",
            secondaryText: "1w 79%",
            state: .healthy
        )
        let items = buildQuotaOverviewMenuItems(
            quotaOverviewState: QuotaOverviewState(
                chatGPTCount: 1,
                apiCount: 1,
                boardTiles: [tile],
                sections: []
            ),
            refreshIntervalPreset: .fiveMinutes,
            isPerformingSafeSwitchOperation: false,
            target: nil,
            activateSavedAccountAction: #selector(NSResponder.cancelOperation(_:))
        )
        let state = buildQuotaOverviewState(
            currentProfile: nil,
            vaultProfiles: [api],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )
        let rowView = try #require(items.first?.view as? AccountMenuRowView)

        let timeFormatter = DateFormatter()
        timeFormatter.locale = AppLocalization.locale
        timeFormatter.dateFormat = "HH:mm"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = AppLocalization.locale
        dateFormatter.setLocalizedDateFormatFromTemplate("MMM d")

        #expect(findLabel(in: rowView) { $0 == "current@example.com" } != nil)
        #expect(findLabel(in: rowView) { $0 == "5h 81%" } != nil)
        #expect(findLabel(in: rowView) { $0.hasPrefix("1w 79%/") } != nil)
        #expect(findLabel(in: rowView) { $0 == "5h \(timeFormatter.string(from: Date(timeIntervalSince1970: 1_800_000_360)))" } != nil)
        #expect(findLabel(in: rowView) { $0 == "1w \(dateFormatter.string(from: Date(timeIntervalSince1970: 1_800_086_400)))" } != nil)
        #expect((rowView.accessibilityLabel() ?? "").contains("Current account"))
        #expect(quotaOverviewEmptyStateMessage(for: state).contains("API accounts"))
    }
}

@MainActor
@Test
func maintenanceMenuRefreshItemShowsProgressCountsWhenAvailable() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let maintenance = buildMaintenanceMenu(
            isRefreshing: true,
            refreshProgress: RefreshProgress(completedCount: 3, totalCount: 8),
            isLaunchingSessionManager: false,
            isPerformingSafeSwitchOperation: false,
            hasRollbackRestorePoint: true,
            target: nil,
            refreshAction: #selector(NSResponder.cancelOperation(_:)),
            manageSessionsAction: #selector(NSResponder.cancelOperation(_:)),
            repairAction: #selector(NSResponder.cancelOperation(_:)),
            rollbackAction: #selector(NSResponder.cancelOperation(_:))
        )

        #expect(maintenance.items.first?.title == "Refreshing 3/8…")
        #expect(maintenance.items.first?.isEnabled == false)
    }
}

@MainActor
@Test
func quotaOverviewMenuRowsPadWeeklyOnlyAccountsWithFiveHourPlaceholder() throws {
    try withExclusiveAppLocalization {
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
        let items = buildQuotaOverviewMenuItems(
            quotaOverviewState: state,
            refreshIntervalPreset: .fiveMinutes,
            isPerformingSafeSwitchOperation: false,
            target: nil,
            activateSavedAccountAction: #selector(NSResponder.cancelOperation(_:))
        )
        let rowView = try #require(items.first?.view as? AccountMenuRowView)

        let dateFormatter = DateFormatter()
        dateFormatter.locale = AppLocalization.locale
        dateFormatter.setLocalizedDateFormatFromTemplate("MMM d")

        #expect(findLabel(in: rowView) { $0 == "5h -" } != nil)
        #expect(findLabel(in: rowView) { $0.hasPrefix("1w 63%/") } != nil)
        #expect(findLabel(in: rowView) { $0 == "1w \(dateFormatter.string(from: Date(timeIntervalSince1970: 1_800_086_400)))" } != nil)
    }
}

@Test
func statusItemAccessibilityDescriptionExplainsMeterStateAndStaleness() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])

        let description = statusItemAccessibilityDescription(
            summary: "5h 81% 1w 79%",
            style: .meter,
            isStale: true
        )

        #expect(description.contains("Quota meter"))
        #expect(description.contains("Data may be stale"))
    }
}

@Test
func statusItemPresentationBuildsMeterAndTextModesOutsideAppController() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_220)
        let snapshot = makeTestSnapshot(
            email: "current@example.com",
            primaryRemaining: 81,
            secondaryRemaining: 79,
            fetchedAt: now
        )

        let meter = buildStatusItemPresentation(
            snapshot: snapshot,
            apiKeyDetails: nil,
            statusItemStyle: .meter,
            refreshIntervalPreset: .fiveMinutes,
            isRefreshing: false,
            currentError: nil,
            lastRefreshAt: now.addingTimeInterval(-600),
            now: now
        )
        let text = buildStatusItemPresentation(
            snapshot: snapshot,
            apiKeyDetails: nil,
            statusItemStyle: .text,
            refreshIntervalPreset: .fiveMinutes,
            isRefreshing: false,
            currentError: nil,
            lastRefreshAt: now,
            now: now
        )

        #expect(meter.title.isEmpty)
        #expect(meter.accessibilityDescription.contains("Quota meter"))
        #expect(text.title.contains("5h"))

        switch meter.visualContent {
        case .brand:
            Issue.record("Expected a meter visual for the ChatGPT quota snapshot.")
        case .meter(_, _, let state):
            #expect(state == .stale)
        }

        #expect(text.visualContent == .brand)
    }
}

@Test
func statusItemPresentationBuildsMeterForAPIQuotaSnapshot() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_230)
        let snapshot = makeTestAPISnapshot(
            primaryRemaining: 23,
            secondaryRemaining: 85,
            fetchedAt: now
        )

        let meter = buildStatusItemPresentation(
            snapshot: snapshot,
            apiKeyDetails: nil,
            statusItemStyle: .meter,
            refreshIntervalPreset: .fiveMinutes,
            isRefreshing: false,
            currentError: nil,
            lastRefreshAt: now,
            now: now
        )
        let text = buildStatusItemPresentation(
            snapshot: snapshot,
            apiKeyDetails: nil,
            statusItemStyle: .text,
            refreshIntervalPreset: .fiveMinutes,
            isRefreshing: false,
            currentError: nil,
            lastRefreshAt: now,
            now: now
        )

        switch meter.visualContent {
        case .brand:
            Issue.record("Expected a meter visual for an API quota snapshot with rate-limit windows.")
        case .meter(let primaryRemaining, let secondaryRemaining, let state):
            #expect(abs(primaryRemaining - 0.23) < 0.0001)
            #expect(abs(secondaryRemaining - 0.85) < 0.0001)
            #expect(state == .normal)
        }

        #expect(text.title == "5h23% 1w85%")
    }
}

@MainActor
@Test
func menuItemBuilderProducesStandardQuotaAndMaintenanceMenuItems() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_240)
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
        let other = makeTestProviderProfile(
            id: "other",
            displayName: "other@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(
                email: "other@example.com",
                primaryRemaining: 77,
                secondaryRemaining: 73,
                fetchedAt: now
            ),
            isCurrent: false,
            lastUsedAt: now.addingTimeInterval(-20)
        )
        let state = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [other],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )

        let items = buildQuotaOverviewMenuItems(
            quotaOverviewState: state,
            refreshIntervalPreset: .fiveMinutes,
            isPerformingSafeSwitchOperation: false,
            target: nil,
            activateSavedAccountAction: #selector(NSResponder.cancelOperation(_:))
        )
        let maintenance = buildMaintenanceMenu(
            isRefreshing: false,
            isLaunchingSessionManager: false,
            isPerformingSafeSwitchOperation: false,
            hasRollbackRestorePoint: true,
            target: nil,
            refreshAction: #selector(NSResponder.cancelOperation(_:)),
            manageSessionsAction: #selector(NSResponder.cancelOperation(_:)),
            repairAction: #selector(NSResponder.cancelOperation(_:)),
            rollbackAction: #selector(NSResponder.cancelOperation(_:))
        )

        #expect(items.count == state.boardTiles.count + 1)
        #expect(items.first?.view is AccountMenuRowView)
        #expect(items.first?.action == nil)
        #expect(items[1].action == #selector(NSResponder.cancelOperation(_:)))
        #expect(items.last?.submenu?.items.isEmpty == false)
        #expect(maintenance.items.count == 5)
        #expect(maintenance.items[2].isSeparatorItem == true)
        #expect(maintenance.items.last?.isEnabled == true)
    }
}

@MainActor
@Test
func quotaOverviewMenuItemsReuseExistingRowViewsWhenShapeMatches() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date(timeIntervalSince1970: 1_800_000_240)
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
        let other = makeTestProviderProfile(
            id: "other",
            displayName: "other@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(
                email: "other@example.com",
                primaryRemaining: 77,
                secondaryRemaining: 73,
                fetchedAt: now
            ),
            isCurrent: false,
            lastUsedAt: now.addingTimeInterval(-20)
        )
        let initialState = buildQuotaOverviewState(
            currentProfile: current,
            vaultProfiles: [other],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )
        let updatedCurrent = makeTestProviderProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(
                email: "current@example.com",
                primaryRemaining: 64,
                secondaryRemaining: 52,
                fetchedAt: now.addingTimeInterval(60)
            ),
            isCurrent: true,
            lastUsedAt: now.addingTimeInterval(60)
        )
        let updatedOther = makeTestProviderProfile(
            id: "other",
            displayName: "other@example.com",
            authMode: .chatgpt,
            snapshot: makeTestSnapshot(
                email: "other@example.com",
                primaryRemaining: 71,
                secondaryRemaining: 69,
                fetchedAt: now.addingTimeInterval(60)
            ),
            isCurrent: false,
            lastUsedAt: now.addingTimeInterval(40)
        )
        let updatedState = buildQuotaOverviewState(
            currentProfile: updatedCurrent,
            vaultProfiles: [updatedOther],
            refreshIntervalPreset: .fiveMinutes,
            now: now.addingTimeInterval(60)
        )

        let items = buildQuotaOverviewMenuItems(
            quotaOverviewState: initialState,
            refreshIntervalPreset: .fiveMinutes,
            isPerformingSafeSwitchOperation: false,
            target: nil,
            activateSavedAccountAction: #selector(NSResponder.cancelOperation(_:))
        )
        let firstRowView = try #require(items.first?.view as? AccountMenuRowView)

        let didReuse = reconcileQuotaOverviewMenuItemsInPlace(
            items,
            quotaOverviewState: updatedState,
            refreshIntervalPreset: .fiveMinutes,
            isPerformingSafeSwitchOperation: false,
            target: nil,
            activateSavedAccountAction: #selector(NSResponder.cancelOperation(_:))
        )

        let updatedRowView = try #require(items.first?.view as? AccountMenuRowView)
        #expect(didReuse)
        #expect(updatedRowView === firstRowView)
        #expect(findLabel(in: updatedRowView) { $0 == "5h 64%" } != nil)
        #expect(findLabel(in: updatedRowView) { $0.hasPrefix("1w 52%/") } != nil)
    }
}

@MainActor
@Test
func quotaOverviewMenuRowsColorWeeklyPaceOverspend() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let now = Date()
        let weeklyReset = now.addingTimeInterval(10_080 * 60 * 0.84)
        let profile = makeTestProviderProfile(
            id: "current",
            displayName: "current@example.com",
            authMode: .chatgpt,
            snapshot: CodexSnapshot(
                account: CodexAccount(type: "chatgpt", email: "current@example.com", planType: "plus"),
                rateLimits: RateLimitSnapshot(
                    limitId: nil,
                    limitName: nil,
                    primary: RateLimitWindow(
                        usedPercent: 19,
                        windowDurationMins: 300,
                        resetsAt: 1_800_000_360
                    ),
                    secondary: RateLimitWindow(
                        usedPercent: 24,
                        windowDurationMins: 10_080,
                        resetsAt: Int(weeklyReset.timeIntervalSince1970)
                    ),
                    planType: "plus"
                ),
                fetchedAt: now
            ),
            isCurrent: true,
            lastUsedAt: now
        )
        let state = buildQuotaOverviewState(
            currentProfile: profile,
            vaultProfiles: [],
            refreshIntervalPreset: .fiveMinutes,
            now: now
        )
        let items = buildQuotaOverviewMenuItems(
            quotaOverviewState: state,
            refreshIntervalPreset: .fiveMinutes,
            isPerformingSafeSwitchOperation: false,
            target: nil,
            activateSavedAccountAction: #selector(NSResponder.cancelOperation(_:))
        )
        let rowView = try #require(items.first?.view as? AccountMenuRowView)
        let weeklyLabel = try #require(findLabel(in: rowView) { $0 == "1w 76%/84%" })
        #expect(weeklyLabel.textColor == .systemRed)
    }
}

@MainActor
@Test
func settingsWindowCoordinatorBuildsPanelStateBeforeForwardingToPresenter() {
    let controller = SettingsWindowControllerSpy()
    var createdSettings: AppSettings?
    var createdPanelState: SettingsAccountPanelState?
    let coordinator = SettingsWindowCoordinator(
        controllerFactory: { settings, accountPanelState in
            createdSettings = settings
            createdPanelState = accountPanelState
            return controller
        }
    )
    let now = Date(timeIntervalSince1970: 1_800_000_260)
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
    let accountPanelState = buildSettingsAccountPanelState(
        vaultSnapshot: AccountVaultSnapshot(accounts: [makeTestVaultRecord(from: current)]),
        vaultProfiles: [],
        currentProviderProfile: current,
        refreshIntervalPreset: .fiveMinutes,
        actionsEnabled: false
    )
    let presentationState = SettingsWindowPresentationState(
        settings: AppSettings(),
        accountPanelState: accountPanelState
    )

    coordinator.update(state: presentationState)
    #expect(controller.lastUpdatedSettings == nil)
    #expect(controller.lastUpdatedPanelState == nil)

    let becameVisible = coordinator.show(
        state: presentationState,
        callbacks: SettingsPresenterCallbacks(
            onSettingsChanged: { _ in },
            onAddChatGPTAccount: {},
            onAddAPIAccount: {},
            onActivateAccount: { _ in },
            onRenameAccount: { _ in },
            onForgetAccount: { _ in },
            onOpenVaultFolder: {},
            onWindowClosed: {}
        )
    )

    #expect(becameVisible == true)
    #expect(controller.showCallCount == 1)
    #expect(createdSettings != nil)
    #expect(createdPanelState?.actionsEnabled == false)
    #expect(createdPanelState?.sections.first?.items.first?.isCurrent == true)
    #expect(coordinator.isVisible == true)
}

@MainActor
@Test
func settingsWindowCoordinatorRefreshesCallbacksOnRepeatedPresentation() {
    let controller = SettingsWindowControllerSpy()
    let coordinator = SettingsWindowCoordinator(
        controllerFactory: { _, _ in controller }
    )
    let panelState = SettingsAccountPanelState(
        importStatusText: "",
        sections: [],
        actionsEnabled: true
    )

    var called: [String] = []

    _ = coordinator.show(
        settings: AppSettings(),
        accountPanelState: panelState,
        callbacks: SettingsPresenterCallbacks(
            onSettingsChanged: { _ in },
            onAddChatGPTAccount: {},
            onAddAPIAccount: { called.append("old") },
            onActivateAccount: { _ in },
            onRenameAccount: { _ in },
            onForgetAccount: { _ in },
            onOpenVaultFolder: {},
            onWindowClosed: {}
        )
    )

    _ = coordinator.show(
        settings: AppSettings(),
        accountPanelState: panelState,
        callbacks: SettingsPresenterCallbacks(
            onSettingsChanged: { _ in },
            onAddChatGPTAccount: {},
            onAddAPIAccount: { called.append("new") },
            onActivateAccount: { _ in },
            onRenameAccount: { _ in },
            onForgetAccount: { _ in },
            onOpenVaultFolder: {},
            onWindowClosed: {}
        )
    )

    controller.onAddAPIAccount?()

    #expect(controller.showCallCount == 2)
    #expect(controller.updateCallCount == 1)
    #expect(called == ["new"])
    #expect(coordinator.isVisible == true)
}

@MainActor
@Test
func foregroundPresentationControllerBalancesActivationPolicyAndVisibility() {
    var appliedPolicies: [NSApplication.ActivationPolicy] = []
    var activationCount = 0
    var isPrimaryWindowVisible = false
    let controller = ForegroundPresentationController(
        setActivationPolicy: { appliedPolicies.append($0) },
        activateApp: { activationCount += 1 },
        isPrimaryWindowVisible: { isPrimaryWindowVisible }
    )

    controller.begin()
    controller.begin()
    controller.endIfPossible()

    #expect(appliedPolicies == [.regular])
    #expect(activationCount == 2)

    isPrimaryWindowVisible = true
    controller.endIfPossible()
    #expect(appliedPolicies == [.regular])

    controller.begin()
    isPrimaryWindowVisible = false
    controller.endIfPossible()
    #expect(appliedPolicies == [.regular, .regular, .accessory])
}

@MainActor
@Test
func settingsPresenterShowRefreshesCallbacksOnRepeatedPresentation() throws {
    let presenter = SettingsPresenter()
    let panelState = SettingsAccountPanelState(
        importStatusText: "",
        sections: [],
        actionsEnabled: true
    )

    var called: [String] = []

    presenter.show(
        settings: AppSettings(),
        accountPanelState: panelState,
        callbacks: SettingsPresenterCallbacks(
            onSettingsChanged: { _ in },
            onAddChatGPTAccount: {},
            onAddAPIAccount: { called.append("old") },
            onActivateAccount: { _ in },
            onRenameAccount: { _ in },
            onForgetAccount: { _ in },
            onOpenVaultFolder: {},
            onWindowClosed: {}
        )
    )

    presenter.show(
        settings: AppSettings(),
        accountPanelState: panelState,
        callbacks: SettingsPresenterCallbacks(
            onSettingsChanged: { _ in },
            onAddChatGPTAccount: {},
            onAddAPIAccount: { called.append("new") },
            onActivateAccount: { _ in },
            onRenameAccount: { _ in },
            onForgetAccount: { _ in },
            onOpenVaultFolder: {},
            onWindowClosed: {}
        )
    )

    let controller = try #require(extractSettingsPresenterController(presenter))
    controller.onAddAPIAccount?()

    #expect(called == ["new"])
}

@MainActor
@Test
func settingsWindowControllerUsesDedicatedTabViews() throws {
    let controller = SettingsWindowController(
        settings: AppSettings(),
        accountPanelState: SettingsAccountPanelState(importStatusText: "", sections: [], actionsEnabled: true)
    )

    let contentView = try #require(controller.window?.contentView)
    let tabView = try #require(findView(ofType: NSTabView.self, in: contentView))

    #expect(tabView.tabViewItems.count == 3)
    #expect(tabView.tabViewItems[0].view is SettingsGeneralView)
    #expect(tabView.tabViewItems[1].view is SettingsWorkPlanView)
    #expect(tabView.tabViewItems[2].view is SettingsAccountsView)
}

@MainActor
@Test
func settingsWindowControllerInitializesForAccountsPanelState() {
    withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let state = SettingsAccountPanelState(
            importStatusText: "Local vault: 2 saved accounts",
            sections: [
                SettingsAccountSection(
                    title: "Current Account",
                    items: [
                        SettingsAccountItem(
                            id: "current",
                            title: "current@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: true,
                            canActivate: false,
                            canRename: true,
                            canForget: false
                        )
                    ]
                ),
                SettingsAccountSection(
                    title: "API Accounts",
                    items: [
                        SettingsAccountItem(
                            id: "api",
                            title: "api.example.com",
                            subtitle: "API Key · Stored in local vault · api.example.com · gpt-5.4",
                            isCurrent: false,
                            canActivate: true,
                            canRename: true,
                            canForget: true
                        )
                    ]
                ),
            ],
            actionsEnabled: true
        )

        let controller = SettingsWindowController(
            settings: AppSettings(),
            accountPanelState: state
        )

        #expect(controller.window != nil)
        #expect(controller.window?.title == "Settings")
    }
}

@MainActor
@Test
func settingsWindowControllerExplainsWhyAccountActionsAreDisabled() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let controller = SettingsWindowController(
            settings: AppSettings(),
            accountPanelState: SettingsAccountPanelState(
                importStatusText: "Local vault: 3 saved accounts",
                sections: [],
                actionsEnabled: false
            )
        )

        let contentView = try #require(controller.window?.contentView)
        let tabView = try #require(findView(ofType: NSTabView.self, in: contentView))
        let accountsView = try #require(tabView.tabViewItems.last?.view)
        let addChatGPTButton = try #require(findButton(in: accountsView, title: "Sign in with ChatGPT"))
        let addAPIButton = try #require(findButton(in: accountsView, title: "Add API Account"))
        let statusLabel = try #require(
            findLabel(in: accountsView) { $0.contains("Local vault: 3 saved accounts") }
        )

        #expect(addChatGPTButton.isEnabled == false)
        #expect(addAPIButton.isEnabled == false)
        #expect(statusLabel.stringValue.contains("Finish the current account operation before changing saved accounts."))
        #expect(addChatGPTButton.toolTip == "Finish the current account operation before changing saved accounts.")
        #expect(addAPIButton.toolTip == "Finish the current account operation before changing saved accounts.")
    }
}

@MainActor
@Test
func settingsWindowControllerSeparatesAccountsHeaderFromScrollableList() throws {
    let controller = SettingsWindowController(
        settings: AppSettings(),
        accountPanelState: SettingsAccountPanelState(
            importStatusText: "Local vault: 3 saved accounts",
            sections: [
                SettingsAccountSection(
                    title: "Current Account (1)",
                    items: [
                        SettingsAccountItem(
                            id: "current",
                            title: "current@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: true,
                            canActivate: false,
                            canRename: true,
                            canForget: false
                        )
                    ]
                ),
                SettingsAccountSection(
                    title: "ChatGPT Accounts (2)",
                    items: [
                        SettingsAccountItem(
                            id: "a",
                            title: "a@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: false,
                            canActivate: true,
                            canRename: true,
                            canForget: true
                        ),
                        SettingsAccountItem(
                            id: "b",
                            title: "b@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: false,
                            canActivate: true,
                            canRename: true,
                            canForget: true
                        )
                    ]
                ),
            ],
            actionsEnabled: true
        )
    )

    let contentView = try #require(controller.window?.contentView)
    let tabView = try #require(findView(ofType: NSTabView.self, in: contentView))
    let accountsView = try #require(tabView.tabViewItems.last?.view)
    let header = try #require(findView(in: accountsView, identifier: "settings.accounts.header"))
    let scrollView = try #require(findView(in: accountsView, identifier: "settings.accounts.scroll") as? NSScrollView)

    #expect(scrollView.hasVerticalScroller)
    #expect(header !== scrollView)
    #expect(isDescendant(header, of: scrollView) == false)
    let tableView = try #require(findView(in: scrollView, identifier: "settings.accounts.table") as? NSTableView)
    controller.window?.layoutIfNeeded()
    accountsView.layoutSubtreeIfNeeded()
    #expect(tableView.numberOfRows == 5)
    #expect(scrollView.documentView === tableView)
    #expect(tableView.frame.height > 0)
}

@MainActor
@Test
func settingsWindowControllerRendersAccountsAfterLateUpdate() throws {
    let controller = SettingsWindowController(
        settings: AppSettings(),
        accountPanelState: SettingsAccountPanelState(
            importStatusText: "",
            sections: [],
            actionsEnabled: true
        )
    )

    let contentView = try #require(controller.window?.contentView)
    let tabView = try #require(findView(ofType: NSTabView.self, in: contentView))
    let accountsView = try #require(tabView.tabViewItems.last?.view)
    let scrollView = try #require(findView(in: accountsView, identifier: "settings.accounts.scroll") as? NSScrollView)
    let tableView = try #require(findView(in: scrollView, identifier: "settings.accounts.table") as? NSTableView)

    controller.update(
        settings: AppSettings(),
        accountPanelState: SettingsAccountPanelState(
            importStatusText: "Local vault: 2 saved accounts",
            sections: [
                SettingsAccountSection(
                    title: "Current Account (1)",
                    items: [
                        SettingsAccountItem(
                            id: "current",
                            title: "current@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: true,
                            canActivate: false,
                            canRename: true,
                            canForget: false
                        )
                    ]
                ),
                SettingsAccountSection(
                    title: "ChatGPT Accounts (1)",
                    items: [
                        SettingsAccountItem(
                            id: "other",
                            title: "other@example.com",
                            subtitle: "ChatGPT · Stored in local vault",
                            isCurrent: false,
                            canActivate: true,
                            canRename: true,
                            canForget: true
                        )
                    ]
                ),
            ],
            actionsEnabled: true
        )
    )

    controller.window?.layoutIfNeeded()
    accountsView.layoutSubtreeIfNeeded()

    #expect(tableView.numberOfRows == 4)
    #expect(tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) != nil)
    #expect(tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) != nil)
}

@MainActor
@Test
func settingsWindowControllerRelocalizesGeneralControlsAfterLanguageChange() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        var settings = AppSettings()
        settings.appLanguage = .en

        let controller = SettingsWindowController(
            settings: settings,
            accountPanelState: SettingsAccountPanelState(importStatusText: "", sections: [], actionsEnabled: true)
        )

        let contentView = try #require(controller.window?.contentView)
        let refreshLabel = try #require(
            findView(in: contentView, identifier: "settings.general.refresh") as? NSTextField
        )
        let languageLabel = try #require(
            findView(in: contentView, identifier: "settings.general.language") as? NSTextField
        )
        let iconStyleLabel = try #require(
            findView(in: contentView, identifier: "settings.general.icon-style") as? NSTextField
        )

        #expect(refreshLabel.stringValue == "Refresh interval")
        #expect(languageLabel.stringValue == "Language")
        #expect(iconStyleLabel.stringValue == "Menu bar style")

        settings.appLanguage = .zh
        AppLocalization.setPreferredLanguage(.zh, preferredLanguages: ["zh-Hans-CN"])
        controller.update(
            settings: settings,
            accountPanelState: SettingsAccountPanelState(importStatusText: "", sections: [], actionsEnabled: true)
        )

        #expect(refreshLabel.stringValue == "刷新频率")
        #expect(languageLabel.stringValue == "语言")
        #expect(iconStyleLabel.stringValue == "状态栏样式")
    }
}

@MainActor
@Test
func applicationMainMenuIncludesStandardEditCommands() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])
        let mainMenu = makeApplicationMainMenu(appName: "Codex Quota Viewer")

        #expect(mainMenu.items.count >= 2)

        let appMenu = try #require(mainMenu.item(at: 0)?.submenu)
        let editMenu = try #require(mainMenu.item(at: 1)?.submenu)

        #expect(appMenu.items.contains(where: { $0.action == #selector(NSApplication.terminate(_:)) }))
        #expect(editMenu.items.contains(where: { $0.action == #selector(NSText.cut(_:)) }))
        #expect(editMenu.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }))
        #expect(editMenu.items.contains(where: { $0.action == #selector(NSText.paste(_:)) }))
        #expect(editMenu.items.contains(where: { $0.action == #selector(NSText.selectAll(_:)) }))
    }
}

@MainActor
private func findView(in root: NSView, identifier: String) -> NSView? {
    if root.identifier?.rawValue == identifier {
        return root
    }

    for subview in root.subviews {
        if let match = findView(in: subview, identifier: identifier) {
            return match
        }
    }

    return nil
}

@MainActor
private func findView<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
    if let root = root as? T {
        return root
    }

    for subview in root.subviews {
        if let match: T = findView(ofType: type, in: subview) {
            return match
        }
    }

    return nil
}

@MainActor
private func extractSettingsPresenterController(_ presenter: SettingsPresenter) -> SettingsWindowController? {
    // `SettingsPresenter.controller` is `private`, so use reflection for this narrow behavior test.
    let presenterMirror = Mirror(reflecting: presenter)
    for child in presenterMirror.children {
        guard child.label == "controller" else { continue }
        let optionalMirror = Mirror(reflecting: child.value)
        guard optionalMirror.displayStyle == .optional else { return nil }
        guard let some = optionalMirror.children.first else { return nil }
        return some.value as? SettingsWindowController
    }
    return nil
}

@MainActor
private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
    var currentView = view.superview
    while currentView != nil {
        if currentView === ancestor {
            return true
        }
        currentView = currentView?.superview
    }
    return false
}

@MainActor
private func findButton(in root: NSView, title: String) -> NSButton? {
    if let button = root as? NSButton, button.title == title {
        return button
    }

    for subview in root.subviews {
        if let match = findButton(in: subview, title: title) {
            return match
        }
    }

    return nil
}

@MainActor
private func findLabel(in root: NSView, where predicate: (String) -> Bool) -> NSTextField? {
    if let label = root as? NSTextField,
       predicate(label.stringValue) {
        return label
    }

    for subview in root.subviews {
        if let match = findLabel(in: subview, where: predicate) {
            return match
        }
    }

    return nil
}

private let testCPAPoolCurrentTextColor = NSColor(calibratedRed: 0.10, green: 0.64, blue: 0.32, alpha: 1)
private let testCPAPoolWarningTextColor = NSColor(calibratedRed: 0.88, green: 0.50, blue: 0.00, alpha: 1)
private let testCPAPoolCriticalTextColor = NSColor(calibratedRed: 0.90, green: 0.16, blue: 0.12, alpha: 1)

private func color(_ actual: NSColor?, isCloseTo expected: NSColor) -> Bool {
    guard let actual = actual?.usingColorSpace(.sRGB),
          let expected = expected.usingColorSpace(.sRGB) else {
        return false
    }
    return abs(actual.redComponent - expected.redComponent) < 0.01
        && abs(actual.greenComponent - expected.greenComponent) < 0.01
        && abs(actual.blueComponent - expected.blueComponent) < 0.01
}

@MainActor
private func assertTextFieldsStayInsideBounds(_ root: NSView) {
    let size = root.intrinsicContentSize
    if size.width > 0 && size.height > 0 {
        root.frame = NSRect(origin: .zero, size: size)
    }
    root.layoutSubtreeIfNeeded()

    for field in textFields(in: root) {
        let frame = root.convert(field.bounds, from: field)
        #expect(frame.minX >= -0.5)
        #expect(frame.minY >= -0.5)
        #expect(frame.maxX <= root.bounds.maxX + 0.5)
        #expect(frame.maxY <= root.bounds.maxY + 0.5)
    }
}

@MainActor
private func assertLabelsShareRow(in root: NSView, _ lhs: NSTextField, _ rhsText: String) {
    let rhs = findLabel(in: root) { $0 == rhsText }
    #expect(rhs != nil)
    guard let rhs else {
        return
    }

    root.layoutSubtreeIfNeeded()
    let lhsFrame = root.convert(lhs.bounds, from: lhs)
    let rhsFrame = root.convert(rhs.bounds, from: rhs)
    #expect(abs(lhsFrame.midY - rhsFrame.midY) < 1)
}

@MainActor
private func assertLabelIsLeftAligned(in root: NSView, _ label: NSTextField) {
    root.layoutSubtreeIfNeeded()
    let frame = root.convert(label.bounds, from: label)
    #expect(frame.minX < 24)
}

@MainActor
private func textFields(in root: NSView) -> [NSTextField] {
    var fields: [NSTextField] = []
    if let field = root as? NSTextField {
        fields.append(field)
    }
    for subview in root.subviews {
        fields.append(contentsOf: textFields(in: subview))
    }
    return fields
}

@MainActor
private final class SettingsPresenterSpy: SettingsWindowPresenting {
    var isVisible = false
    var showCallCount = 0
    var lastUpdatedSettings: AppSettings?
    var lastUpdatedPanelState: SettingsAccountPanelState?

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    ) {
        lastUpdatedSettings = settings
        lastUpdatedPanelState = accountPanelState
    }

    func show(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState,
        callbacks: SettingsPresenterCallbacks
    ) {
        showCallCount += 1
        isVisible = true
        lastUpdatedSettings = settings
        lastUpdatedPanelState = accountPanelState
    }
}

@MainActor
private final class SettingsWindowControllerSpy: SettingsWindowControlling {
    var onSettingsChanged: ((AppSettings) -> Void)?
    var onAddChatGPTAccount: (() -> Void)?
    var onAddAPIAccount: (() -> Void)?
    var onActivateAccount: ((String) -> Void)?
    var onRenameAccount: ((String) -> Void)?
    var onForgetAccount: ((String) -> Void)?
    var onOpenVaultFolder: (() -> Void)?
    var onWindowClosed: (() -> Void)?

    let window: NSWindow? = NSWindow()
    var showCallCount = 0
    var updateCallCount = 0
    var lastUpdatedSettings: AppSettings?
    var lastUpdatedPanelState: SettingsAccountPanelState?
    private var visible = false

    var isVisible: Bool {
        visible
    }

    func update(
        settings: AppSettings,
        accountPanelState: SettingsAccountPanelState
    ) {
        updateCallCount += 1
        lastUpdatedSettings = settings
        lastUpdatedPanelState = accountPanelState
    }

    func showWindow(_ sender: Any?) {
        showCallCount += 1
        visible = true
    }
}
