import AppKit

@MainActor
final class QuotaWorkPlanMenuToggleView: NSView {
    static let height: CGFloat = 46
    static let minimumWidth: CGFloat = 408

    var onToggle: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let modeSwitch = WorkPlanSwitchControl()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.height))
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.minimumWidth, height: Self.height)
    }

    func apply(workPlan: QuotaWorkPlanSettings) {
        titleLabel.stringValue = AppLocalization.localized(en: "Work Plan", zh: "工作计划")
        detailLabel.stringValue = workPlan.isEnabled
            ? AppLocalization.localized(en: "Color by next off-time target", zh: "按停用前目标着色")
            : AppLocalization.localized(en: "Color by live pace", zh: "按实时进度着色")
        modeSwitch.isOn = workPlan.isEnabled
        setAccessibilityLabel("\(titleLabel.stringValue), \(detailLabel.stringValue)")
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            return
        }
        guard !modeSwitch.frame.contains(point) else {
            return
        }
        onToggle?()
    }

    private func setupUI() {
        wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        modeSwitch.target = self
        modeSwitch.action = #selector(switchChanged)

        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(modeSwitch)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            heightAnchor.constraint(equalToConstant: Self.height),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeSwitch.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeSwitch.leadingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            modeSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            modeSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc
    private func switchChanged() {
        onToggle?()
    }
}

@MainActor
private final class WorkPlanSwitchControl: NSControl {
    var isOn: Bool = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isOn ? "on" : "off")
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 42, height: 24)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityValue("off")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackRect = bounds.insetBy(dx: 1, dy: 2)
        let trackPath = NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackRect.height / 2,
            yRadius: trackRect.height / 2
        )
        (isOn ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor.withAlphaComponent(0.45)).setFill()
        trackPath.fill()

        let knobSize = trackRect.height - 4
        let knobX = isOn
            ? trackRect.maxX - knobSize - 2
            : trackRect.minX + 2
        let knobRect = NSRect(
            x: knobX,
            y: trackRect.minY + 2,
            width: knobSize,
            height: knobSize
        )
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: knobRect,
            xRadius: knobSize / 2,
            yRadius: knobSize / 2
        ).fill()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
