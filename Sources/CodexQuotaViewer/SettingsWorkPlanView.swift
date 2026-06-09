import AppKit
import Foundation

@MainActor
final class SettingsWorkPlanView: NSView {
    let enabledSwitch = NSSwitch()
    let addPeriodButton = NSButton(title: "", target: nil, action: nil)
    let resetButton = NSButton(title: "", target: nil, action: nil)
    let summaryLabel = NSTextField(labelWithString: "")
    var onChange: (() -> Void)?

    private let sectionTitleLabel = NSTextField(labelWithString: "")
    private let switchLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(labelWithString: "")
    private let periodsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var periodRows: [WorkPlanPeriodRowView] = []
    private var isApplying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyLocalizedText() {
        sectionTitleLabel.stringValue = AppLocalization.localized(en: "Work Plan", zh: "工作计划")
        switchLabel.stringValue = AppLocalization.localized(en: "Work plan mode", zh: "工作计划模式")
        explanationLabel.stringValue = AppLocalization.localized(
            en: "Add off-periods. The daily quota share stays fixed and is distributed only across usable time.",
            zh: "添加停用时段。每日额度份额固定，只分配到可用时间。"
        )
        emptyLabel.stringValue = AppLocalization.localized(en: "No off-periods. All day is usable.", zh: "没有停用时段，全天可用。")
        addPeriodButton.title = AppLocalization.localized(en: "Add Off Period", zh: "添加停用时段")
        resetButton.title = AppLocalization.localized(en: "Clear Periods", zh: "清空时段")
        periodRows.forEach { $0.applyLocalizedText() }
    }

    func configure(with workPlan: QuotaWorkPlanSettings) {
        isApplying = true
        enabledSwitch.state = workPlan.isEnabled ? .on : .off
        rebuildRows(periods: workPlan.offPeriods)
        summaryLabel.stringValue = workPlan.dailyShareDescription
        isApplying = false
    }

    var selectedWorkPlan: QuotaWorkPlanSettings {
        QuotaWorkPlanSettings(
            isEnabled: enabledSwitch.state == .on,
            offPeriods: periodRows.map(\.period)
        )
    }

    private func setupUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        sectionTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        sectionTitleLabel.textColor = .labelColor
        sectionTitleLabel.identifier = NSUserInterfaceItemIdentifier("settings.work-plan.section")

        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.maximumNumberOfLines = 2
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.identifier = NSUserInterfaceItemIdentifier("settings.work-plan.constraint")
        explanationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.identifier = NSUserInterfaceItemIdentifier("settings.work-plan.summary")

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.identifier = NSUserInterfaceItemIdentifier("settings.work-plan.empty")

        periodsStack.orientation = .vertical
        periodsStack.alignment = .leading
        periodsStack.spacing = 8

        addPeriodButton.bezelStyle = .rounded
        addPeriodButton.target = self
        addPeriodButton.action = #selector(addPeriodClicked)
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetPeriodsClicked)
        enabledSwitch.target = self
        enabledSwitch.action = #selector(controlChanged)

        stack.addArrangedSubview(sectionTitleLabel)
        stack.addArrangedSubview(makeSwitchRow())
        stack.addArrangedSubview(explanationLabel)
        stack.addArrangedSubview(periodsStack)
        stack.addArrangedSubview(emptyLabel)
        stack.addArrangedSubview(makeActionRow())
        stack.addArrangedSubview(summaryLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
        ])
    }

    private func makeSwitchRow() -> NSView {
        switchLabel.font = .systemFont(ofSize: 13, weight: .medium)
        switchLabel.textColor = .labelColor
        let row = NSStackView(views: [enabledSwitch, switchLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func makeActionRow() -> NSView {
        let row = NSStackView(views: [addPeriodButton, resetButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func rebuildRows(periods: [QuotaWorkPlanPeriod]) {
        periodRows.forEach { row in
            periodsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        periodRows = []

        for period in periods.filter({ !$0.isEmpty }) {
            appendRow(period: period)
        }
        updateEmptyState()
    }

    private func appendRow(period: QuotaWorkPlanPeriod) {
        let row = WorkPlanPeriodRowView(period: period)
        row.onChange = { [weak self] in
            self?.controlChanged()
        }
        row.onDelete = { [weak self, weak row] in
            guard let self,
                  let row else { return }
            self.removeRow(row)
        }
        row.applyLocalizedText()
        periodRows.append(row)
        periodsStack.addArrangedSubview(row)
    }

    private func removeRow(_ row: WorkPlanPeriodRowView) {
        guard let index = periodRows.firstIndex(where: { $0 === row }) else {
            return
        }
        periodRows.remove(at: index)
        periodsStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        controlChanged()
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !periodRows.isEmpty
        resetButton.isEnabled = !periodRows.isEmpty
    }

    @objc
    private func addPeriodClicked() {
        appendRow(period: QuotaWorkPlanPeriod(startMinuteOfDay: 2 * 60, endMinuteOfDay: 10 * 60))
        controlChanged()
        updateEmptyState()
    }

    @objc
    private func resetPeriodsClicked() {
        rebuildRows(periods: [])
        controlChanged()
    }

    @objc
    private func controlChanged() {
        guard !isApplying else {
            return
        }
        summaryLabel.stringValue = selectedWorkPlan.dailyShareDescription
        onChange?()
    }
}

@MainActor
private final class WorkPlanPeriodRowView: NSView {
    var onChange: (() -> Void)?
    var onDelete: (() -> Void)?

    private let startLabel = NSTextField(labelWithString: "")
    private let endLabel = NSTextField(labelWithString: "")
    private let startHourPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startMinutePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let endHourPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let endMinutePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let separatorLabel = NSTextField(labelWithString: ":")
    private let endSeparatorLabel = NSTextField(labelWithString: ":")
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    init(period: QuotaWorkPlanPeriod) {
        super.init(frame: .zero)
        setupUI()
        configure(period)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var period: QuotaWorkPlanPeriod {
        QuotaWorkPlanPeriod(
            startMinuteOfDay: selectedMinute(hourPopup: startHourPopup, minutePopup: startMinutePopup),
            endMinuteOfDay: selectedMinute(hourPopup: endHourPopup, minutePopup: endMinutePopup)
        )
    }

    func applyLocalizedText() {
        startLabel.stringValue = AppLocalization.localized(en: "Off from", zh: "停用从")
        endLabel.stringValue = AppLocalization.localized(en: "to", zh: "到")
        deleteButton.title = AppLocalization.localized(en: "Remove", zh: "删除")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false

        [startHourPopup, startMinutePopup, endHourPopup, endMinutePopup].forEach(configureTimePopup)
        fill(popup: startHourPopup, range: 0..<24)
        fill(popup: endHourPopup, range: 0..<24)
        fill(popup: startMinutePopup, range: 0..<60)
        fill(popup: endMinutePopup, range: 0..<60)

        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)

        let row = NSStackView(views: [
            startLabel,
            startHourPopup,
            separatorLabel,
            startMinutePopup,
            endLabel,
            endHourPopup,
            endSeparatorLabel,
            endMinutePopup,
            deleteButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            startLabel.widthAnchor.constraint(equalToConstant: 54),
            endLabel.widthAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func configure(_ period: QuotaWorkPlanPeriod) {
        selectMinute(period.startMinuteOfDay, hourPopup: startHourPopup, minutePopup: startMinutePopup)
        selectMinute(period.endMinuteOfDay, hourPopup: endHourPopup, minutePopup: endMinutePopup)
    }

    private func configureTimePopup(_ popup: NSPopUpButton) {
        popup.bezelStyle = .rounded
        popup.controlSize = .small
        popup.target = self
        popup.action = #selector(timeChanged)
        popup.widthAnchor.constraint(equalToConstant: 52).isActive = true
    }

    private func fill(popup: NSPopUpButton, range: Range<Int>) {
        popup.removeAllItems()
        for value in range {
            popup.addItem(withTitle: String(format: "%02d", value))
            popup.lastItem?.representedObject = value
        }
    }

    private func selectedMinute(hourPopup: NSPopUpButton, minutePopup: NSPopUpButton) -> Int {
        let hour = hourPopup.selectedItem?.representedObject as? Int ?? 0
        let minute = minutePopup.selectedItem?.representedObject as? Int ?? 0
        return hour * 60 + minute
    }

    private func selectMinute(_ minuteOfDay: Int, hourPopup: NSPopUpButton, minutePopup: NSPopUpButton) {
        let normalized = QuotaWorkPlanPeriod.normalizedMinute(minuteOfDay)
        select(value: normalized / 60, in: hourPopup)
        select(value: normalized % 60, in: minutePopup)
    }

    private func select(value: Int, in popup: NSPopUpButton) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? Int) == value }) {
            popup.select(item)
        }
    }

    @objc
    private func timeChanged() {
        onChange?()
    }

    @objc
    private func deleteClicked() {
        onDelete?()
    }
}
