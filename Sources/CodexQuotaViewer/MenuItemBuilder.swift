import AppKit
import Foundation

@MainActor
func buildQuotaOverviewMenuItems(
    quotaOverviewState: QuotaOverviewState?,
    refreshIntervalPreset: RefreshIntervalPreset,
    quotaWorkPlan: QuotaWorkPlanSettings = QuotaWorkPlanSettings(),
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> [NSMenuItem] {
    var items: [NSMenuItem] = []

    if let quotaOverviewState,
       !quotaOverviewState.boardTiles.isEmpty {
        items.append(
            contentsOf: quotaOverviewState.boardTiles.map { tile in
                let presentation = buildQuotaOverviewRowPresentation(
                    for: tile,
                    quotaWorkPlan: quotaWorkPlan,
                    isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation
                )
                let cpaPoolMembers = quotaOverviewState.cpaPoolMembersByParentID[tile.profile.id] ?? []
                return makeQuotaOverviewRowItem(
                    tileID: tile.profile.id,
                    profile: tile.profile,
                    presentation: presentation,
                    cpaPoolMembers: cpaPoolMembers,
                    refreshIntervalPreset: refreshIntervalPreset,
                    isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
                    target: target,
                    activateSavedAccountAction: activateSavedAccountAction
                )
            }
        )
    } else {
        let item = NSMenuItem(
            title: quotaOverviewEmptyStateMessage(for: quotaOverviewState),
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        items.append(item)
    }

    let allAccountsItem = NSMenuItem(
        title: AppLocalization.localized(en: "All Accounts", zh: "全部账号"),
        action: nil,
        keyEquivalent: ""
    )
    allAccountsItem.submenu = buildAllAccountsMenu(
        quotaOverviewState: quotaOverviewState,
        refreshIntervalPreset: refreshIntervalPreset,
        isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
        target: target,
        activateSavedAccountAction: activateSavedAccountAction
    )
    items.append(allAccountsItem)

    return items
}

@MainActor
func reconcileQuotaOverviewMenuItemsInPlace(
    _ existingItems: [NSMenuItem],
    quotaOverviewState: QuotaOverviewState?,
    refreshIntervalPreset: RefreshIntervalPreset,
    quotaWorkPlan: QuotaWorkPlanSettings = QuotaWorkPlanSettings(),
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> Bool {
    if let quotaOverviewState,
       !quotaOverviewState.boardTiles.isEmpty {
        guard existingItems.count == quotaOverviewState.boardTiles.count + 1 else {
            return false
        }

        for (index, tile) in quotaOverviewState.boardTiles.enumerated() {
            let presentation = buildQuotaOverviewRowPresentation(
                for: tile,
                quotaWorkPlan: quotaWorkPlan,
                isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation
            )
            let cpaPoolMembers = quotaOverviewState.cpaPoolMembersByParentID[tile.profile.id] ?? []
            let item = existingItems[index]
            guard let rowView = item.view as? AccountMenuRowView else {
                return false
            }

            item.title = presentation.name
            item.action = cpaPoolMembers.isEmpty && presentation.triggersDirectSwitch
                ? activateSavedAccountAction
                : nil
            item.target = target
            item.representedObject = tile.profile.id
            item.isEnabled = presentation.isEnabled || !cpaPoolMembers.isEmpty
            item.toolTip = presentation.accessibilityLabel
            item.submenu = cpaPoolMembers.isEmpty
                ? nil
                : makeCPAPoolDetailsMenu(
                    parentProfile: tile.profile,
                    canSwitchParent: presentation.triggersDirectSwitch,
                    cpaPoolMembers: cpaPoolMembers,
                    refreshIntervalPreset: refreshIntervalPreset,
                    target: target,
                    activateSavedAccountAction: activateSavedAccountAction
                )
            rowView.apply(
                model: quotaOverviewRowModel(
                    from: presentation,
                    forceEnabled: !cpaPoolMembers.isEmpty
                )
            )
        }

        let allAccountsItem = existingItems[quotaOverviewState.boardTiles.count]
        configureAllAccountsItem(
            allAccountsItem,
            quotaOverviewState: quotaOverviewState,
            refreshIntervalPreset: refreshIntervalPreset,
            isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
            target: target,
            activateSavedAccountAction: activateSavedAccountAction
        )
        return true
    }

    guard existingItems.count == 2 else {
        return false
    }

    let emptyStateItem = existingItems[0]
    guard emptyStateItem.view == nil else {
        return false
    }
    emptyStateItem.title = quotaOverviewEmptyStateMessage(for: quotaOverviewState)
    emptyStateItem.action = nil
    emptyStateItem.target = nil
    emptyStateItem.representedObject = nil
    emptyStateItem.isEnabled = false
    emptyStateItem.toolTip = nil

    configureAllAccountsItem(
        existingItems[1],
        quotaOverviewState: quotaOverviewState,
        refreshIntervalPreset: refreshIntervalPreset,
        isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
        target: target,
        activateSavedAccountAction: activateSavedAccountAction
    )
    return true
}

@MainActor
private func makeQuotaOverviewRowItem(
    tileID: String,
    profile: ProviderProfile,
    presentation: QuotaOverviewRowPresentation,
    cpaPoolMembers: [ProviderProfile],
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> NSMenuItem {
    let item = NSMenuItem(
        title: presentation.name,
        action: cpaPoolMembers.isEmpty && presentation.triggersDirectSwitch
            ? activateSavedAccountAction
            : nil,
        keyEquivalent: ""
    )
    item.target = target
    item.representedObject = tileID
    item.isEnabled = presentation.isEnabled || !cpaPoolMembers.isEmpty
    item.toolTip = presentation.accessibilityLabel
    if !cpaPoolMembers.isEmpty {
        item.submenu = makeCPAPoolDetailsMenu(
            parentProfile: profile,
            canSwitchParent: presentation.triggersDirectSwitch && !isPerformingSafeSwitchOperation,
            cpaPoolMembers: cpaPoolMembers,
            refreshIntervalPreset: refreshIntervalPreset,
            target: target,
            activateSavedAccountAction: activateSavedAccountAction
        )
    }
    item.view = AccountMenuRowView(
        model: quotaOverviewRowModel(
            from: presentation,
            forceEnabled: !cpaPoolMembers.isEmpty
        )
    )
    return item
}

private func quotaOverviewRowModel(
    from presentation: QuotaOverviewRowPresentation,
    forceEnabled: Bool = false
) -> AccountMenuRowModel {
    AccountMenuRowModel(
        name: presentation.name,
        primaryRemainingText: presentation.primaryRemainingText,
        secondaryRemainingText: presentation.secondaryRemainingText,
        primaryResetText: presentation.primaryResetText,
        secondaryResetText: presentation.secondaryResetText,
        primaryRemainingColor: quotaPaceColor(for: presentation.primaryPaceState),
        secondaryRemainingColor: quotaPaceColor(for: presentation.secondaryPaceState),
        indicatorColor: quotaOverviewIndicatorColor(for: presentation.state),
        isCurrent: presentation.isCurrent,
        isEnabled: presentation.isEnabled || forceEnabled,
        accessibilityLabel: presentation.accessibilityLabel
    )
}

private func quotaPaceColor(for state: QuotaPaceState?) -> NSColor {
    switch state {
    case .onPace:
        return .systemGreen
    case .withinGuard:
        return .systemYellow
    case .overGuard:
        return .systemRed
    case nil:
        return .secondaryLabelColor
    }
}

@MainActor
private func configureAllAccountsItem(
    _ item: NSMenuItem,
    quotaOverviewState: QuotaOverviewState?,
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) {
    item.title = AppLocalization.localized(en: "All Accounts", zh: "全部账号")
    item.action = nil
    item.target = nil
    item.representedObject = nil
    item.isEnabled = true
    item.toolTip = nil
    item.view = nil
    item.submenu = buildAllAccountsMenu(
        quotaOverviewState: quotaOverviewState,
        refreshIntervalPreset: refreshIntervalPreset,
        isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
        target: target,
        activateSavedAccountAction: activateSavedAccountAction
    )
}

private func quotaOverviewIndicatorColor(for state: QuotaTileState) -> NSColor {
    switch state {
    case .healthy:
        return .systemGreen
    case .lowQuota:
        return .systemYellow
    case .stale:
        return .systemOrange
    case .signInRequired, .expired, .readFailure:
        return .systemRed
    }
}

@MainActor
func buildAllAccountsMenu(
    quotaOverviewState: QuotaOverviewState?,
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> NSMenu {
    let submenu = NSMenu()

    guard let quotaOverviewState,
          !quotaOverviewState.sections.isEmpty else {
        let emptyItem = NSMenuItem(
            title: AppLocalization.localized(en: "No saved accounts", zh: "暂无已保存账号"),
            action: nil,
            keyEquivalent: ""
        )
        emptyItem.isEnabled = false
        submenu.addItem(emptyItem)
        return submenu
    }

    for (sectionIndex, section) in quotaOverviewState.sections.enumerated() {
        addRegularAllAccountsSection(
            section,
            to: submenu,
            refreshIntervalPreset: refreshIntervalPreset,
            isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
            target: target,
            activateSavedAccountAction: activateSavedAccountAction
        )

        if sectionIndex < quotaOverviewState.sections.count - 1 {
            submenu.addItem(.separator())
        }
    }

    return submenu
}

@MainActor
private func addRegularAllAccountsSection(
    _ section: AllAccountsSectionModel,
    to submenu: NSMenu,
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) {
    let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
    header.isEnabled = false
    submenu.addItem(header)

    for profile in section.profiles {
        submenu.addItem(
            makeAllAccountsProfileItem(
                profile,
                refreshIntervalPreset: refreshIntervalPreset,
                isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation,
                target: target,
                activateSavedAccountAction: activateSavedAccountAction
            )
        )
    }
}

@MainActor
private func makeCPAPoolDetailsMenu(
    parentProfile: ProviderProfile,
    canSwitchParent: Bool,
    cpaPoolMembers: [ProviderProfile],
    refreshIntervalPreset: RefreshIntervalPreset,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> NSMenu {
    let submenu = NSMenu()
    let switchItemTitle: String
    let switchItemIsEnabled: Bool
    let switchItemAction: Selector?

    if parentProfile.isCurrent {
        switchItemTitle = AppLocalization.localized(en: "Current API Account", zh: "当前 API 账号")
        switchItemIsEnabled = false
        switchItemAction = nil
    } else {
        switchItemTitle = AppLocalization.localized(
            en: "Switch to \(parentProfile.displayName)",
            zh: "切换到 \(parentProfile.displayName)"
        )
        switchItemIsEnabled = canSwitchParent
        switchItemAction = canSwitchParent ? activateSavedAccountAction : nil
    }

    let switchItem = NSMenuItem(title: switchItemTitle, action: switchItemAction, keyEquivalent: "")
    switchItem.target = target
    switchItem.representedObject = parentProfile.id
    switchItem.isEnabled = switchItemIsEnabled
    submenu.addItem(switchItem)
    submenu.addItem(.separator())

    let poolHeader = NSMenuItem(
        title: AppLocalization.localized(en: "CPA Pool Members", zh: "CPA 子号池"),
        action: nil,
        keyEquivalent: ""
    )
    poolHeader.isEnabled = false
    submenu.addItem(poolHeader)

    for profile in cpaPoolMembers {
        submenu.addItem(
            makeAllAccountsProfileItem(
                profile,
                refreshIntervalPreset: refreshIntervalPreset,
                isPerformingSafeSwitchOperation: false,
                target: target,
                activateSavedAccountAction: activateSavedAccountAction
            )
        )
    }
    return submenu
}

@MainActor
private func makeAllAccountsProfileItem(
    _ profile: ProviderProfile,
    refreshIntervalPreset: RefreshIntervalPreset,
    isPerformingSafeSwitchOperation: Bool,
    target: AnyObject?,
    activateSavedAccountAction: Selector
) -> NSMenuItem {
    let presentation = buildAllAccountsMenuItemPresentation(
        for: profile,
        refreshIntervalPreset: refreshIntervalPreset,
        isPerformingSafeSwitchOperation: isPerformingSafeSwitchOperation
    )
    let item = NSMenuItem(
        title: presentation.title,
        action: presentation.triggersDirectSwitch ? activateSavedAccountAction : nil,
        keyEquivalent: ""
    )
    item.target = target
    item.representedObject = profile.id
    item.state = presentation.showsCheckmark ? .on : .off
    item.isEnabled = presentation.isEnabled
    return item
}

@MainActor
func buildMaintenanceMenu(
    isRefreshing: Bool,
    refreshProgress: RefreshProgress? = nil,
    isLaunchingSessionManager: Bool,
    isPerformingSafeSwitchOperation: Bool,
    hasRollbackRestorePoint: Bool,
    target: AnyObject?,
    refreshAction: Selector,
    manageSessionsAction: Selector,
    repairAction: Selector,
    rollbackAction: Selector
) -> NSMenu {
    let submenu = NSMenu()

    let refreshItem = NSMenuItem(
        title: isRefreshing
            ? refreshItemTitle(refreshProgress: refreshProgress)
            : AppLocalization.localized(en: "Refresh All", zh: "全部刷新"),
        action: refreshAction,
        keyEquivalent: ""
    )
    refreshItem.target = target
    refreshItem.isEnabled = !isRefreshing && !isPerformingSafeSwitchOperation
    submenu.addItem(refreshItem)

    let sessionManagerItem = NSMenuItem(
        title: isLaunchingSessionManager
            ? AppLocalization.localized(en: "Opening Session Manager…", zh: "正在打开 Session Manager…")
            : AppLocalization.localized(en: "Open Session Manager", zh: "打开 Session Manager"),
        action: manageSessionsAction,
        keyEquivalent: ""
    )
    sessionManagerItem.target = target
    sessionManagerItem.isEnabled = !isLaunchingSessionManager && !isPerformingSafeSwitchOperation
    submenu.addItem(sessionManagerItem)

    submenu.addItem(.separator())

    let repairItem = NSMenuItem(
        title: AppLocalization.localized(en: "Repair Now", zh: "立即修复"),
        action: repairAction,
        keyEquivalent: ""
    )
    repairItem.target = target
    repairItem.isEnabled = !isPerformingSafeSwitchOperation
    submenu.addItem(repairItem)

    let rollbackItem = NSMenuItem(
        title: AppLocalization.localized(en: "Rollback Last Change", zh: "回滚上次变更"),
        action: rollbackAction,
        keyEquivalent: ""
    )
    rollbackItem.target = target
    rollbackItem.isEnabled = !isPerformingSafeSwitchOperation && hasRollbackRestorePoint
    submenu.addItem(rollbackItem)

    return submenu
}

@MainActor
func makeChatGPTProviderModeMenuItem(
    presentation: ChatGPTProviderModeMenuPresentation,
    target: AnyObject?,
    action: Selector
) -> NSMenuItem {
    let item = NSMenuItem(
        title: presentation.title,
        action: presentation.isEnabled ? action : nil,
        keyEquivalent: ""
    )
    item.target = target
    item.isEnabled = presentation.isEnabled
    item.state = presentation.isActive ? .on : .off
    item.toolTip = presentation.tooltip
    return item
}

private func refreshItemTitle(refreshProgress: RefreshProgress?) -> String {
    guard let refreshProgress else {
        return AppLocalization.localized(en: "Refreshing…", zh: "刷新中…")
    }

    return AppLocalization.localized(
        en: "Refreshing \(refreshProgress.fractionText)…",
        zh: "刷新中 \(refreshProgress.fractionText)…"
    )
}
