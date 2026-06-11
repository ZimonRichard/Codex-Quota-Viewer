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
    switchItem.view = CPAPoolMenuActionRowView(
        model: CPAPoolMenuActionRowModel(
            title: switchItemTitle,
            detail: parentProfile.isCurrent
                ? parentProfile.displayName
                : AppLocalization.localized(en: "API account", zh: "API 账号"),
            titleColor: parentProfile.isCurrent ? cpaPoolCurrentTextColor : .systemBlue,
            isEnabled: switchItemIsEnabled,
            isPrimaryAction: !parentProfile.isCurrent && switchItemIsEnabled
        )
    )
    submenu.addItem(switchItem)
    submenu.addItem(.separator())

    let poolHeaderTitle = AppLocalization.localized(en: "CPA Pool Members", zh: "CPA 子号池")
    let poolHeader = NSMenuItem(title: poolHeaderTitle, action: nil, keyEquivalent: "")
    poolHeader.isEnabled = false
    poolHeader.view = CPAPoolMenuSectionHeaderView(title: poolHeaderTitle)
    submenu.addItem(poolHeader)

    for profile in cpaPoolMembers {
        submenu.addItem(
            makeAllAccountsProfileItem(
                profile,
                refreshIntervalPreset: refreshIntervalPreset,
                isPerformingSafeSwitchOperation: false,
                target: target,
                activateSavedAccountAction: activateSavedAccountAction,
                forceEnabledReadOnlyPoolMember: true
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
    activateSavedAccountAction: Selector,
    forceEnabledReadOnlyPoolMember: Bool = false
) -> NSMenuItem {
    let now = Date()
    let presentation = buildAllAccountsMenuItemPresentation(
        for: profile,
        refreshIntervalPreset: refreshIntervalPreset,
        now: now,
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
    item.isEnabled = presentation.isEnabled || (forceEnabledReadOnlyPoolMember && profile.isReadOnlyPoolMember)
    if profile.isReadOnlyPoolMember {
        item.attributedTitle = cpaPoolMemberAttributedTitle(
            for: profile,
            title: presentation.title,
            now: now
        )
        if forceEnabledReadOnlyPoolMember {
            item.view = CPAPoolMemberMenuRowView(
                model: cpaPoolMemberMenuRowModel(for: profile, now: now)
            )
        }
    }
    return item
}

private func cpaPoolMemberMenuRowModel(for profile: ProviderProfile, now: Date) -> CPAPoolMemberMenuRowModel {
    let windows = cpaPoolMenuQuotaWindows(for: profile, now: now)
    let primaryWindow = windows.first
    let secondaryWindow = windows.dropFirst().first
    let detailText = joinedNonEmptyParts([
        cpaPoolMenuVisibleText(profile.model, hiddenValue: "quota-probe"),
        cpaPoolMenuVisibleText(profile.cpaPoolReasoningEffort, hiddenValue: "read-only"),
        profile.cpaPoolStatusCode.map { "HTTP \($0)" },
    ], separator: " · ")

    return CPAPoolMemberMenuRowModel(
        name: profile.displayName,
        routeText: cpaPoolMenuRouteText(for: profile),
        detailText: detailText,
        primaryText: cpaPoolMenuWindowText(primaryWindow, placeholder: "5h -"),
        secondaryText: cpaPoolMenuWindowText(secondaryWindow, placeholder: "1w -"),
        primaryResetText: cpaPoolMenuWindowResetText(primaryWindow, placeholder: "5h -"),
        secondaryResetText: cpaPoolMenuWindowResetText(secondaryWindow, placeholder: "1w -"),
        updatedText: cpaPoolMenuFetchedAtText(for: profile) ?? "",
        routeColor: cpaPoolRouteTextColor(for: profile),
        primaryColor: primaryWindow.map { cpaPoolQuotaTextColor(for: $0.window) } ?? .secondaryLabelColor,
        secondaryColor: secondaryWindow.map { cpaPoolQuotaTextColor(for: $0.window) } ?? .secondaryLabelColor
    )
}

private func cpaPoolMemberAttributedTitle(
    for profile: ProviderProfile,
    title: String,
    now: Date
) -> NSAttributedString {
    let attributedTitle = NSMutableAttributedString(
        string: title,
        attributes: [.foregroundColor: NSColor.labelColor]
    )

    if profile.isCPAPoolCurrentRoute {
        applyForegroundColor(
            cpaPoolCurrentTextColor,
            to: cpaPoolMenuRouteText(for: profile),
            in: attributedTitle
        )
    }

    for quotaWindow in cpaPoolMenuQuotaWindows(for: profile, now: now) {
        let color = cpaPoolQuotaTextColor(for: quotaWindow.window)
        applyForegroundColor(
            color,
            to: "\(quotaWindow.label) \(quotaWindow.window.remainingPercentText)",
            in: attributedTitle
        )
    }

    return attributedTitle
}

private func cpaPoolMenuQuotaWindows(for profile: ProviderProfile, now: Date) -> [QuotaDisplayWindow] {
    guard profile.isReadOnlyPoolMember else {
        return quotaDisplayWindows(from: profile.snapshot, now: now)
    }
    if profile.healthStatus == .healthy && profile.quotaFailureDisposition == nil {
        return quotaDisplayWindows(from: profile.snapshot, now: now)
    }
    return quotaDisplayWindows(from: profile.snapshot)
}

private let cpaPoolCurrentTextColor = NSColor(calibratedRed: 0.10, green: 0.64, blue: 0.32, alpha: 1)
private let cpaPoolWarningTextColor = NSColor(calibratedRed: 0.88, green: 0.50, blue: 0.00, alpha: 1)
private let cpaPoolCriticalTextColor = NSColor(calibratedRed: 0.90, green: 0.16, blue: 0.12, alpha: 1)

private func cpaPoolQuotaTextColor(for window: RateLimitWindow) -> NSColor {
    let displayedRemainingPercent = Int(window.remainingPercent.rounded())
    if displayedRemainingPercent <= 0 {
        return cpaPoolCriticalTextColor
    }
    if displayedRemainingPercent < 10 {
        return cpaPoolWarningTextColor
    }
    return .labelColor
}

private func cpaPoolMenuRouteText(for profile: ProviderProfile) -> String {
    if profile.isCPAPoolCurrentRoute {
        if profile.isCPAPoolLatestRequestRoute {
            return AppLocalization.localized(en: "current · latest", zh: "当前 · 最近")
        }
        return AppLocalization.localized(en: "current", zh: "当前")
    }
    if profile.isCPAPoolLatestRequestRoute {
        return AppLocalization.localized(en: "latest hit", zh: "最近")
    }
    if profile.isCPAPoolRoutePreferred {
        return AppLocalization.localized(en: "scheduled route", zh: "调度选择")
    }
    return AppLocalization.localized(en: "standby", zh: "备用")
}

private func cpaPoolRouteTextColor(for profile: ProviderProfile) -> NSColor {
    if profile.isCPAPoolCurrentRoute {
        return cpaPoolCurrentTextColor
    }
    if profile.isCPAPoolLatestRequestRoute {
        return .systemBlue
    }
    return .secondaryLabelColor
}

private func cpaPoolMenuVisibleText(_ value: String?, hiddenValue: String) -> String? {
    let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let text, !text.isEmpty, text != hiddenValue else {
        return nil
    }
    return text
}

private func cpaPoolMenuFetchedAtText(for profile: ProviderProfile) -> String? {
    guard let date = profile.quotaFetchedAt ?? profile.snapshot?.fetchedAt else {
        return nil
    }

    let formatter = DateFormatter()
    formatter.locale = AppLocalization.locale
    formatter.dateFormat = "M/d HH:mm"
    let text = formatter.string(from: date)
    return AppLocalization.localized(en: "updated \(text)", zh: "更新 \(text)")
}

private func cpaPoolMenuWindowText(_ quotaWindow: QuotaDisplayWindow?, placeholder: String) -> String {
    guard let quotaWindow else {
        return placeholder
    }
    return "\(quotaWindow.label) \(quotaWindow.window.remainingPercentText)"
}

private enum CPAPoolQuotaResetDateStyle {
    case time
    case monthDay
}

private func cpaPoolMenuWindowResetText(_ quotaWindow: QuotaDisplayWindow?, placeholder: String) -> String {
    guard let quotaWindow,
          let resetDate = quotaWindow.window.resetDate else {
        return placeholder
    }

    let formatter = DateFormatter()
    formatter.locale = AppLocalization.locale
    switch cpaPoolQuotaResetDateStyle(for: quotaWindow.window) {
    case .time:
        formatter.dateFormat = "HH:mm"
    case .monthDay:
        formatter.dateFormat = "M/d HH:mm"
    }

    return "\(quotaWindow.label) \(formatter.string(from: resetDate))"
}

private func cpaPoolQuotaResetDateStyle(for window: RateLimitWindow) -> CPAPoolQuotaResetDateStyle {
    if let duration = window.windowDurationMins,
       duration >= 1_440 {
        return .monthDay
    }
    return .time
}

private func applyForegroundColor(
    _ color: NSColor,
    to text: String,
    in attributedString: NSMutableAttributedString
) {
    guard let range = attributedString.string.range(of: text) else {
        return
    }
    attributedString.addAttribute(
        .foregroundColor,
        value: color,
        range: NSRange(range, in: attributedString.string)
    )
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
