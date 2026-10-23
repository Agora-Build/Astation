import Cocoa
import Foundation

class ProjectsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var tokenWindow: NSWindow?
    private let hubManager: AstationHubManager
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var selectionToast: NSTextField!
    private lazy var manageConnectionButton = NSButton(title: "Connect Agora Account...", target: self, action: #selector(openConnections))
    private lazy var refreshButton = NSButton(title: "Refresh Projects", target: self, action: #selector(refreshProjects))
    private var certificateVisibility: [String: Bool] = [:]

    private let nameColId = NSUserInterfaceItemIdentifier("name")
    private let appIdColId = NSUserInterfaceItemIdentifier("appId")
    private let certColId = NSUserInterfaceItemIdentifier("cert")
    private let statusColId = NSUserInterfaceItemIdentifier("status")
    private let createdColId = NSUserInterfaceItemIdentifier("created")

    init(hubManager: AstationHubManager) {
        self.hubManager = hubManager
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged), name: .accountLoginChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshTable()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agora Projects"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 380)

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Header + selection toast
        let headerLabel = NSTextField(labelWithString: "Projects")
        headerLabel.font = NSFont.boldSystemFont(ofSize: 18)

        selectionToast = NSTextField(labelWithString: "")
        selectionToast.font = NSFont.boldSystemFont(ofSize: 14)
        selectionToast.textColor = .systemBlue
        selectionToast.alphaValue = 0
        selectionToast.lineBreakMode = .byTruncatingTail
        selectionToast.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectionToast.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let tokenButton = NSButton(title: "Generate Token...", target: self, action: #selector(generateToken(_:)))
        tokenButton.bezelStyle = .rounded
        tokenButton.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
        tokenButton.imagePosition = .imageLeading
        tokenButton.toolTip = "Generate a token for the selected project, or inspect an existing token."

        refreshButton.bezelStyle = .rounded
        let header = NSStackView(views: [headerLabel, selectionToast, tokenButton, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        // Table in scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        let table = NSTableView()
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.doubleAction = #selector(tableDoubleClicked)
        table.target = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        let contextMenu = NSMenu()
        let contextToken = NSMenuItem(title: "Generate Token...", action: #selector(generateToken(_:)), keyEquivalent: "")
        contextToken.target = self
        contextMenu.addItem(contextToken)
        table.menu = contextMenu

        let nameCol = NSTableColumn(identifier: nameColId)
        nameCol.title = "Name"
        nameCol.width = 140
        nameCol.minWidth = 80
        table.addTableColumn(nameCol)

        let appIdCol = NSTableColumn(identifier: appIdColId)
        appIdCol.title = "App ID"
        appIdCol.width = 160
        appIdCol.minWidth = 100
        table.addTableColumn(appIdCol)

        let certCol = NSTableColumn(identifier: certColId)
        certCol.title = "Certificate"
        certCol.width = 180
        certCol.minWidth = 140
        table.addTableColumn(certCol)

        let statusCol = NSTableColumn(identifier: statusColId)
        statusCol.title = "Status"
        statusCol.width = 60
        statusCol.minWidth = 50
        table.addTableColumn(statusCol)

        let createdCol = NSTableColumn(identifier: createdColId)
        createdCol.title = "Created"
        createdCol.width = 160
        createdCol.minWidth = 150
        table.addTableColumn(createdCol)

        scrollView.documentView = table
        self.tableView = table

        // Keep connection controls and status together below the project list.
        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        manageConnectionButton.bezelStyle = .rounded
        let footer = NSStackView(views: [statusLabel, manageConnectionButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        for child in [header, scrollView, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        refreshTable()

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func updateStatusLabel() {
        if hubManager.usingSavedProjects {
            let date = hubManager.projectCacheUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "an earlier session"
            statusLabel?.stringValue = "Using saved projects from \(date). Token generation works offline."
            statusLabel?.textColor = .secondaryLabelColor
        } else if let error = hubManager.projectLoadError {
            statusLabel?.stringValue = "Error: \(error)"
            statusLabel?.textColor = .systemRed
        } else {
            let count = hubManager.getProjects().count
            let loaded = "\(count) project\(count == 1 ? "" : "s") loaded"
            statusLabel?.stringValue = hubManager.agoraConnection?.connected == true
                ? "Agora connected. \(loaded)"
                : "\(loaded). Connect an Agora account in the portal."
            statusLabel?.textColor = .secondaryLabelColor
        }
    }

    @objc private func refreshProjects() {
        hubManager.refreshProjects()
    }

    @objc private func accountChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshTable() }
    }

    @objc private func openConnections() {
        guard let url = hubManager.portalSettings?.accountURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshTable() {
        tableView?.reloadData()
        let agora = hubManager.agoraConnection
        manageConnectionButton.title = agora?.connected == true ? "Manage Agora Connection..." : "Connect Agora Account..."
        manageConnectionButton.isEnabled = hubManager.portalSettings != nil
        refreshButton.isEnabled = hubManager.signedInAccount != nil
        updateStatusLabel()
    }

    // MARK: - Button Actions

    @objc private func generateToken(_ sender: Any?) {
        let row = sender is NSMenuItem ? tableView.clickedRow : tableView.selectedRow
        let projects = hubManager.getProjects()
        showTokenTools(projectID: projects.indices.contains(row) ? projects[row].id : nil)
    }

    func showTokenTools(projectID: String? = nil) {
        showWindow()
        guard let window else { return }
        if let tokenWindow { tokenWindow.makeKeyAndOrderFront(nil); return }
        let controller = TokenToolsViewController(projects: { [weak hubManager] in hubManager?.getProjects() ?? [] },
                                                  initialProjectID: projectID ?? hubManager.effectiveProject?.id,
                                                  resolveProject: { [weak hubManager] id in
            guard let hubManager else { throw PortalAPIError.signInRequired }
            return try await hubManager.projectWithCertificate(id: id)
        })
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 740),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sheet.title = "Token Tools"
        sheet.minSize = NSSize(width: 560, height: 440)
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = controller
        sheet.setContentSize(NSSize(width: 680, height: 740))
        sheet.delegate = self
        controller.onClose = { [weak self] in self?.closeTokenTools() }
        tokenWindow = sheet
        window.beginSheet(sheet)
    }

    private func closeTokenTools() {
        guard let sheet = tokenWindow else { return }
        (sheet.contentViewController as? TokenToolsViewController)?.clearSensitiveContent()
        window?.endSheet(sheet)
        sheet.orderOut(nil)
        tokenWindow = nil
    }

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
        let id = projects[row].id
        Task { @MainActor in
            do {
                let project = try await hubManager.projectWithCertificate(id: id)
                certificateVisibility[project.vendorKey] = !(certificateVisibility[project.vendorKey] ?? false)
                tableView.reloadData()
            } catch { hubManager.projectLoadError = error.localizedDescription }
        }
    }

    @objc private func copyCert(_ sender: NSButton) {
        guard let row = rowForButton(sender), row < hubManager.projects.count else { return }
        let id = hubManager.projects[row].id
        Task { @MainActor in
            do { copyToPasteboard(try await hubManager.projectWithCertificate(id: id).signKey) }
            catch { hubManager.projectLoadError = error.localizedDescription }
        }
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
        guard notification.object as? NSWindow === window else { return }
        closeTokenTools()
        window = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === tokenWindow { closeTokenTools(); return false }
        return true
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension ProjectsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return hubManager.getProjects().count
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        let projects = hubManager.getProjects()
        guard row < projects.count else { return }
        hubManager.selectProject(id: projects[row].id)
        tableView.reloadData()
        showSelectionToast("Selected: \(projects[row].name)")
    }

    private func showSelectionToast(_ text: String) {
        // Cancel any in-flight animation so the new toast appears immediately.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            selectionToast.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.selectionToast.stringValue = text
            self.selectionToast.alphaValue = 1
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 4.0
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.selectionToast.animator().alphaValue = 0
            }
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let projects = hubManager.getProjects()
        guard row < projects.count, let colId = tableColumn?.identifier else { return nil }
        let project = projects[row]

        switch colId {
        case nameColId:
            let isSelected = hubManager.selectedProject?.id == project.id
            let displayName = isSelected ? "\u{2713} \(project.name)" : "  \(project.name)"
            return makeLabelCell(tableView, id: "nameCell", text: displayName)

        case appIdColId:
            return makeTextWithCopyCell(
                tableView, id: "appIdCell", text: Self.masked(project.vendorKey), row: row,
                copyAction: #selector(copyAppId(_:)))

        case certColId:
            let isVisible = certificateVisibility[project.vendorKey] ?? false
            let displayText = isVisible ? Self.masked(project.signKey) : String(repeating: "\u{2022}", count: 12)
            let toggleTitle = isVisible ? "Hide" : "Show"
            return makeCertCell(
                tableView, id: "certCell", text: displayText, toggleTitle: toggleTitle, row: row)

        case statusColId:
            let cell = makeLabelCell(tableView, id: "statusCell", text: project.status)
            if let cellView = cell as? NSTableCellView {
                cellView.textField?.textColor = project.status == "active" ? .systemGreen : .secondaryLabelColor
            }
            return cell

        case createdColId:
            let dateStr = Self.formatDate(project.created)
            let cell = makeLabelCell(tableView, id: "createdCell", text: dateStr)
            if let cellView = cell as? NSTableCellView {
                cellView.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            }
            return cell

        default:
            return nil
        }
    }

    /// Show first 6 + "..." + last 6 chars. Short strings pass through unchanged.
    private static func masked(_ s: String) -> String {
        guard s.count > 16 else { return s }
        return "\(s.prefix(6))...\(s.suffix(6))"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func formatDate(_ unix: UInt64) -> String {
        guard unix > 0 else { return "—" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    // MARK: - Cell Factories

    private func makeLabelCell(_ tableView: NSTableView, id: String, text: String) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier(id)
        if let existing = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            existing.textField?.stringValue = text
            return existing
        }
        let cell = NSTableCellView()
        cell.identifier = cellId
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeTextWithCopyCell(
        _ tableView: NSTableView, id: String, text: String, row: Int, copyAction: Selector
    ) -> NSView {
        let container = NSView()

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byClipping
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
        label.lineBreakMode = .byClipping
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
