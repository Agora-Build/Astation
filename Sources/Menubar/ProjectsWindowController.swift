import Cocoa
import Foundation

class ProjectsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let hubManager: AstationHubManager
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var certificateVisibility: [String: Bool] = [:]

    private let nameColId = NSUserInterfaceItemIdentifier("name")
    private let appIdColId = NSUserInterfaceItemIdentifier("appId")
    private let certColId = NSUserInterfaceItemIdentifier("cert")
    private let statusColId = NSUserInterfaceItemIdentifier("status")

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
    }

    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshTable()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agora Projects"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 550, height: 300)

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Header
        let headerLabel = NSTextField(labelWithString: "Projects")
        headerLabel.font = NSFont.boldSystemFont(ofSize: 14)
        headerLabel.frame = NSRect(x: 16, y: 410, width: 200, height: 24)
        contentView.addSubview(headerLabel)

        // Refresh button
        let refreshButton = NSButton(
            title: "Refresh", target: self, action: #selector(refreshProjects))
        refreshButton.bezelStyle = .rounded
        refreshButton.frame = NSRect(x: 600, y: 410, width: 80, height: 24)
        refreshButton.autoresizingMask = [.minXMargin]
        contentView.addSubview(refreshButton)

        // Table in scroll view
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 40, width: 668, height: 360))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        let table = NSTableView()
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self

        let nameCol = NSTableColumn(identifier: nameColId)
        nameCol.title = "Name"
        nameCol.width = 140
        nameCol.minWidth = 80
        table.addTableColumn(nameCol)

        let appIdCol = NSTableColumn(identifier: appIdColId)
        appIdCol.title = "App ID"
        appIdCol.width = 220
        appIdCol.minWidth = 120
        table.addTableColumn(appIdCol)

        let certCol = NSTableColumn(identifier: certColId)
        certCol.title = "Certificate"
        certCol.width = 240
        certCol.minWidth = 140
        table.addTableColumn(certCol)

        let statusCol = NSTableColumn(identifier: statusColId)
        statusCol.title = "Status"
        statusCol.width = 70
        statusCol.minWidth = 50
        table.addTableColumn(statusCol)

        scrollView.documentView = table
        contentView.addSubview(scrollView)
        self.tableView = table

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.frame = NSRect(x: 16, y: 12, width: 668, height: 18)
        statusLabel.autoresizingMask = [.width]
        contentView.addSubview(statusLabel)
        updateStatusLabel()

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func updateStatusLabel() {
        if let error = hubManager.projectLoadError {
            statusLabel?.stringValue = "Error: \(error)"
            statusLabel?.textColor = .systemRed
        } else {
            let count = hubManager.getProjects().count
            statusLabel?.stringValue = "\(count) project\(count == 1 ? "" : "s") loaded"
            statusLabel?.textColor = .secondaryLabelColor
        }
    }

    @objc private func refreshProjects() {
        hubManager.refreshProjects()
        // Reload after a short delay for the async fetch
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshTable()
        }
    }

    private func refreshTable() {
        tableView?.reloadData()
        updateStatusLabel()
    }

    // MARK: - Button Actions

    @objc private func copyAppId(_ sender: NSButton) {
        guard let row = rowForButton(sender) else { return }
        let projects = hubManager.getProjects()
        guard row < projects.count else { return }
        copyToPasteboard(projects[row].vendorKey)
    }

    @objc private func toggleCertVisibility(_ sender: NSButton) {
        guard let row = rowForButton(sender) else { return }
        let projects = hubManager.getProjects()
        guard row < projects.count else { return }
        let key = projects[row].vendorKey
        certificateVisibility[key] = !(certificateVisibility[key] ?? false)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 2))
    }

    @objc private func copyCert(_ sender: NSButton) {
        guard let row = rowForButton(sender) else { return }
        let projects = hubManager.getProjects()
        guard row < projects.count else { return }
        copyToPasteboard(projects[row].signKey)
    }

    private func rowForButton(_ button: NSView) -> Int? {
        let row = tableView.row(for: button)
        return row >= 0 ? row : nil
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension ProjectsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return hubManager.getProjects().count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let projects = hubManager.getProjects()
        guard row < projects.count, let colId = tableColumn?.identifier else { return nil }
        let project = projects[row]

        switch colId {
        case nameColId:
            return makeLabelCell(tableView, id: "nameCell", text: project.name)

        case appIdColId:
            return makeTextWithCopyCell(
                tableView, id: "appIdCell", text: project.vendorKey, row: row,
                copyAction: #selector(copyAppId(_:)))

        case certColId:
            let isVisible = certificateVisibility[project.vendorKey] ?? false
            let displayText = isVisible ? project.signKey : String(repeating: "\u{2022}", count: 12)
            let toggleTitle = isVisible ? "Hide" : "Show"
            return makeCertCell(
                tableView, id: "certCell", text: displayText, toggleTitle: toggleTitle, row: row)

        case statusColId:
            let cell = makeLabelCell(tableView, id: "statusCell", text: project.status)
            if let textField = cell as? NSTextField {
                textField.textColor = project.status == "active" ? .systemGreen : .secondaryLabelColor
            }
            return cell

        default:
            return nil
        }
    }

    // MARK: - Cell Factories

    private func makeLabelCell(_ tableView: NSTableView, id: String, text: String) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier(id)
        if let existing = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField {
            existing.stringValue = text
            return existing
        }
        let label = NSTextField(labelWithString: text)
        label.identifier = cellId
        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeTextWithCopyCell(
        _ tableView: NSTableView, id: String, text: String, row: Int, copyAction: Selector
    ) -> NSView {
        let container = NSView()

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let copyBtn = NSButton(title: "Copy", target: self, action: copyAction)
        copyBtn.bezelStyle = .inline
        copyBtn.font = NSFont.systemFont(ofSize: 10)
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(copyBtn)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: copyBtn.leadingAnchor, constant: -4),

            copyBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            copyBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            copyBtn.widthAnchor.constraint(equalToConstant: 40),
        ])

        return container
    }

    private func makeCertCell(
        _ tableView: NSTableView, id: String, text: String, toggleTitle: String, row: Int
    ) -> NSView {
        let container = NSView()

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let toggleBtn = NSButton(
            title: toggleTitle, target: self, action: #selector(toggleCertVisibility(_:)))
        toggleBtn.bezelStyle = .inline
        toggleBtn.font = NSFont.systemFont(ofSize: 10)
        toggleBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggleBtn)

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyCert(_:)))
        copyBtn.bezelStyle = .inline
        copyBtn.font = NSFont.systemFont(ofSize: 10)
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(copyBtn)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: toggleBtn.leadingAnchor, constant: -4),

            toggleBtn.trailingAnchor.constraint(equalTo: copyBtn.leadingAnchor, constant: -4),
            toggleBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            toggleBtn.widthAnchor.constraint(equalToConstant: 40),

            copyBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            copyBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            copyBtn.widthAnchor.constraint(equalToConstant: 40),
        ])

        return container
    }
}
