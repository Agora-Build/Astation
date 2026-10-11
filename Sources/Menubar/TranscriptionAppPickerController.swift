import AppKit

private final class AppPickerDocumentView: NSView { override var isFlipped: Bool { true } }
private final class AppPickerCheckbox: NSButton { var bundleID = "" }

final class TranscriptionAppPickerController: NSViewController {
    private var applications: [RecordingApplication]
    private(set) var selectedIDs: Set<String>
    private(set) var appButtons: [String: NSButton] = [:]
    let applyButton = NSButton(title: "Use Apps", target: nil, action: nil)
    private let rows = NSStackView()
    var onApply: (([String]) -> Void)?
    var onCancel: (() -> Void)?
    var onRefresh: (() -> [RecordingApplication])?

    init(applications: [RecordingApplication], selectedIDs: [String]) {
        self.applications = applications
        self.selectedIDs = Set(selectedIDs)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        view = background
        preferredContentSize = NSSize(width: 304, height: 320)
        let icon = NSImageView(image: NSImage(systemSymbolName: "app.badge.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemTeal
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let title = NSTextField(labelWithString: "Choose app audio")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let header = NSStackView(views: [icon, title, NSView()])
        header.spacing = 10
        let note = NSTextField(wrappingLabelWithString: "Transcribe selected apps. Your microphone stays off.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = AppPickerDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshApps))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        applyButton.target = self
        applyButton.action = #selector(applySelection)
        applyButton.contentTintColor = .systemTeal
        for button in [refresh, cancel, applyButton] { button.bezelStyle = .rounded }
        let footer = NSStackView(views: [refresh, NSView(), cancel, applyButton])
        footer.spacing = 6
        let stack = NSStackView(views: [header, note, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        rebuildRows()
    }

    private func rebuildRows() {
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        appButtons = [:]
        if applications.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Open an app, then refresh to choose it.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            rows.addArrangedSubview(empty)
        }
        for app in applications {
            let checkbox = AppPickerCheckbox(checkboxWithTitle: app.name, target: self, action: #selector(toggleApp(_:)))
            checkbox.bundleID = app.bundleID
            checkbox.state = selectedIDs.contains(app.bundleID) ? .on : .off
            checkbox.font = .systemFont(ofSize: 12, weight: .medium)
            checkbox.lineBreakMode = .byTruncatingTail
            checkbox.setAccessibilityLabel("Transcribe \(app.name) audio")
            let icon = NSImageView(image: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
            icon.contentTintColor = .systemTeal
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
            let row = NSStackView(views: [icon, checkbox, NSView()])
            row.spacing = 8
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            appButtons[app.bundleID] = checkbox
        }
        applyButton.isEnabled = !selectedIDs.isEmpty
    }
    @objc private func toggleApp(_ sender: AppPickerCheckbox) {
        if sender.state == .on { selectedIDs.insert(sender.bundleID) }
        else { selectedIDs.remove(sender.bundleID) }
        applyButton.isEnabled = !selectedIDs.isEmpty
    }
    @objc private func refreshApps() {
        if let onRefresh { applications = onRefresh() }
        selectedIDs.formIntersection(applications.map(\.bundleID))
        rebuildRows()
    }
    @objc private func cancelSelection() { onCancel?() }
    @objc private func applySelection() {
        let ids = applications.map(\.bundleID).filter { selectedIDs.contains($0) }
        guard !ids.isEmpty else { return }
        onApply?(ids)
    }
}
