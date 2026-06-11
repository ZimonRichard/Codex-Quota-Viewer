import AppKit

private enum CPAPoolMenuMetrics {
    static let width: CGFloat = 452
    static let cardInset: CGFloat = 3
    static let horizontalPadding: CGFloat = 12
    static let quotaColumnWidth: CGFloat = 92
    static let quotaColumnSpacing: CGFloat = 8
}

struct CPAPoolMenuActionRowModel {
    let title: String
    let detail: String
    let titleColor: NSColor
    let isEnabled: Bool
    let isPrimaryAction: Bool
}

@MainActor
final class CPAPoolMenuActionRowView: NSView {
    static let minimumWidth: CGFloat = CPAPoolMenuMetrics.width
    static let height: CGFloat = 44

    private let cardView = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let actionImageView = NSImageView()
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false {
        didSet { updateAppearance() }
    }
    private(set) var model: CPAPoolMenuActionRowModel

    init(model: CPAPoolMenuActionRowModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.height))
        setupView()
        apply(model: model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.minimumWidth, height: Self.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if model.isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard model.isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        guard model.isEnabled else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              let menuItem = enclosingMenuItem,
              let action = menuItem.action else {
            return
        }
        menuItem.menu?.cancelTracking()
        NSApp.sendAction(action, to: menuItem.target, from: menuItem)
    }

    func apply(model: CPAPoolMenuActionRowModel) {
        self.model = model
        titleField.stringValue = model.title
        detailField.stringValue = model.detail
        titleField.textColor = model.titleColor
        actionImageView.isHidden = !model.isPrimaryAction
        alphaValue = model.isEnabled ? 1 : 0.95
        updateAppearance()
        setAccessibilityLabel([model.title, model.detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 6
        addSubview(cardView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        addSubview(titleField)

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 10, weight: .regular)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1
        addSubview(detailField)

        actionImageView.translatesAutoresizingMaskIntoConstraints = false
        actionImageView.image = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: nil)
        actionImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        actionImageView.contentTintColor = .systemBlue
        actionImageView.imageScaling = .scaleProportionallyDown
        addSubview(actionImageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.minimumWidth),
            heightAnchor.constraint(equalToConstant: Self.height),

            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            actionImageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            actionImageView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            actionImageView.widthAnchor.constraint(equalToConstant: 16),
            actionImageView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: actionImageView.leadingAnchor, constant: -8),
            titleField.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 5),

            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            detailField.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -5),
        ])
        updateAppearance()
    }

    private func updateAppearance() {
        if model.isPrimaryAction {
            let backgroundAlpha: CGFloat = isHovered && model.isEnabled ? 0.18 : 0.11
            let borderAlpha: CGFloat = isHovered && model.isEnabled ? 0.55 : 0.34
            cardView.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(backgroundAlpha).cgColor
            cardView.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(borderAlpha).cgColor
            cardView.layer?.borderWidth = 1
            return
        }

        let alpha: CGFloat = isHovered && model.isEnabled ? 0.14 : 0.08
        cardView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(alpha).cgColor
        cardView.layer?.borderColor = nil
        cardView.layer?.borderWidth = 0
    }
}

@MainActor
final class CPAPoolMenuSectionHeaderView: NSView {
    static let minimumWidth: CGFloat = CPAPoolMenuMetrics.width
    static let height: CGFloat = 26

    private let titleField = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.height))
        setupView()
        titleField.stringValue = title
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.minimumWidth, height: Self.height)
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.maximumNumberOfLines = 1
        addSubview(titleField)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.minimumWidth),
            heightAnchor.constraint(equalToConstant: Self.height),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

struct CPAPoolMemberMenuRowModel {
    let name: String
    let routeText: String
    let detailText: String
    let primaryText: String
    let secondaryText: String
    let primaryResetText: String
    let secondaryResetText: String
    let updatedText: String
    let routeColor: NSColor
    let primaryColor: NSColor
    let secondaryColor: NSColor
}

@MainActor
final class CPAPoolMemberMenuRowView: NSView {
    static let minimumWidth: CGFloat = CPAPoolMenuMetrics.width
    static let height: CGFloat = 52

    private let cardView = NSView()
    private let nameField = NSTextField(labelWithString: "")
    private let routeField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let primaryField = NSTextField(labelWithString: "")
    private let secondaryField = NSTextField(labelWithString: "")
    private let primaryResetField = NSTextField(labelWithString: "")
    private let secondaryResetField = NSTextField(labelWithString: "")

    private(set) var model: CPAPoolMemberMenuRowModel

    init(model: CPAPoolMemberMenuRowModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.height))
        setupView()
        apply(model: model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.minimumWidth, height: Self.height)
    }

    func apply(model: CPAPoolMemberMenuRowModel) {
        self.model = model
        nameField.stringValue = model.name
        routeField.stringValue = model.routeText
        detailField.stringValue = [model.updatedText, model.detailText]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        primaryField.stringValue = model.primaryText
        secondaryField.stringValue = model.secondaryText
        primaryResetField.stringValue = model.primaryResetText
        secondaryResetField.stringValue = model.secondaryResetText
        routeField.textColor = model.routeColor
        primaryField.textColor = model.primaryColor
        secondaryField.textColor = model.secondaryColor
        setAccessibilityLabel([
            model.name,
            model.routeText,
            model.primaryText,
            model.primaryResetText,
            model.secondaryText,
            model.secondaryResetText,
            model.detailText,
            model.updatedText,
        ].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 6
        cardView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.08).cgColor
        addSubview(cardView)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 12, weight: .regular)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        addSubview(nameField)

        routeField.translatesAutoresizingMaskIntoConstraints = false
        routeField.font = .systemFont(ofSize: 11, weight: .semibold)
        routeField.maximumNumberOfLines = 1
        addSubview(routeField)

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 10, weight: .regular)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1
        addSubview(detailField)

        for field in [primaryField, secondaryField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            field.alignment = .right
            field.maximumNumberOfLines = 1
            addSubview(field)
        }

        for field in [primaryResetField, secondaryResetField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.alignment = .right
            field.maximumNumberOfLines = 1
            addSubview(field)
        }

        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        routeField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for field in [primaryField, secondaryField, primaryResetField, secondaryResetField] {
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.minimumWidth),
            heightAnchor.constraint(equalToConstant: Self.height),

            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CPAPoolMenuMetrics.cardInset),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CPAPoolMenuMetrics.cardInset),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: CPAPoolMenuMetrics.cardInset),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CPAPoolMenuMetrics.cardInset),

            secondaryField.trailingAnchor.constraint(
                equalTo: cardView.trailingAnchor,
                constant: -CPAPoolMenuMetrics.horizontalPadding
            ),
            secondaryField.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            secondaryField.widthAnchor.constraint(equalToConstant: CPAPoolMenuMetrics.quotaColumnWidth),

            primaryField.trailingAnchor.constraint(
                equalTo: secondaryField.leadingAnchor,
                constant: -CPAPoolMenuMetrics.quotaColumnSpacing
            ),
            primaryField.topAnchor.constraint(equalTo: secondaryField.topAnchor),
            primaryField.widthAnchor.constraint(equalToConstant: CPAPoolMenuMetrics.quotaColumnWidth),

            secondaryResetField.trailingAnchor.constraint(equalTo: secondaryField.trailingAnchor),
            secondaryResetField.topAnchor.constraint(equalTo: secondaryField.bottomAnchor, constant: 4),
            secondaryResetField.widthAnchor.constraint(equalTo: secondaryField.widthAnchor),

            primaryResetField.trailingAnchor.constraint(equalTo: primaryField.trailingAnchor),
            primaryResetField.topAnchor.constraint(equalTo: secondaryResetField.topAnchor),
            primaryResetField.widthAnchor.constraint(equalTo: primaryField.widthAnchor),

            nameField.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: CPAPoolMenuMetrics.horizontalPadding),
            nameField.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 6),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: routeField.leadingAnchor, constant: -8),

            routeField.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            routeField.trailingAnchor.constraint(lessThanOrEqualTo: primaryField.leadingAnchor, constant: -12),

            detailField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: primaryResetField.leadingAnchor, constant: -12),
            detailField.centerYAnchor.constraint(equalTo: primaryResetField.centerYAnchor),
        ])
    }
}
