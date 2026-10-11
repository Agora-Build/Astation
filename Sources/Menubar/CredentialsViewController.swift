import AppKit

final class CredentialValueInput: NSStackView {
    let secureField = NSSecureTextField()
    let textView = NSTextView()
    let showButton = NSButton(checkboxWithTitle: "Show multiline value", target: nil, action: nil)
    private let scroll = NSScrollView()

    var value: String {
        get { showButton.state == .on ? textView.string : secureField.stringValue }
        set {
            if showButton.state == .on { textView.string = newValue; secureField.stringValue = "" }
            else { secureField.stringValue = newValue; textView.string = "" }
        }
    }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        secureField.placeholderString = "Paste the credential value"
        secureField.setAccessibilityLabel("Credential value, hidden")
        secureField.cell?.isScrollable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 460, height: 100)
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.setAccessibilityLabel("Credential value, visible")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        showButton.target = self
        showButton.action = #selector(toggleVisibility)
        addArrangedSubview(secureField)
        addArrangedSubview(scroll)
        addArrangedSubview(showButton)
        NSLayoutConstraint.activate([
            secureField.widthAnchor.constraint(equalTo: widthAnchor),
            scroll.widthAnchor.constraint(equalTo: widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 100)
        ])
        scroll.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func toggleVisibility() {
        if showButton.state == .on {
            textView.string = secureField.stringValue
            secureField.stringValue = ""
        } else {
            secureField.stringValue = textView.string
            textView.string = ""
        }
        secureField.isHidden = showButton.state == .on
        scroll.isHidden = showButton.state != .on
    }

    func clear() {
        secureField.stringValue = ""
        textView.string = ""
        showButton.state = .off
        secureField.isHidden = false
        scroll.isHidden = true
    }
}

final class CredentialEditor: NSObject {
    let panel: NSPanel
    let nameField = NSTextField()
    let projectField = NSComboBox()
    let projectButton = NSButton(checkboxWithTitle: "Use project scope", target: nil, action: nil)
    let input = CredentialValueInput()
    let status = NSTextField(wrappingLabelWithString: "")
    let saveButton = NSButton(title: "Save with Touch ID", target: nil, action: nil)
    let entry: LocalCredentialMetadata?
    let revision: UUID?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    init(entry: LocalCredentialMetadata?, snapshot: LocalCredentialSnapshot) {
        self.entry = entry
        revision = snapshot.revision
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 550),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = entry == nil ? "Add Credential" : "Update Credential"
        panel.isReleasedWhenClosed = false
        super.init()
        nameField.placeholderString = "OPENAI_API_KEY"
        nameField.setAccessibilityLabel("Credential name")
        projectField.placeholderString = "github.com/owner/repo or Git remote"
        projectField.setAccessibilityLabel("Credential project")
        projectField.addItems(withObjectValues: Array(Set(snapshot.entries.compactMap(\.project))).sorted())
        nameField.stringValue = entry?.name ?? ""
        projectField.stringValue = entry?.project ?? ""
        projectButton.state = entry?.project == nil ? .off : .on
        projectButton.target = self
        projectButton.action = #selector(scopeChanged)
        nameField.isEnabled = entry == nil
        projectButton.isEnabled = entry == nil
        projectField.isEnabled = entry == nil && projectButton.state == .on
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.stringValue = "Global credentials belong to this Mac. Values may contain up to 64 KiB; show multiline input for PEM or JSON."
        saveButton.target = self
        saveButton.action = #selector(save)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, saveButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [NSTextField(labelWithString: "Name"), nameField, projectButton, projectField,
            NSTextField(labelWithString: entry == nil ? "Value" : "Replacement Value"), input, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let content = panel.contentView!
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            projectField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func scopeChanged() { projectField.isEnabled = projectButton.state == .on }
    @objc private func save() { onSave?() }
    @objc private func cancel() { onCancel?() }

    func validatedInput() throws -> (name: String, project: String?, value: String) {
        let name = try LocalCredentialStore.name(nameField.stringValue)
        let project = try LocalCredentialStore.project(projectButton.state == .on ? projectField.stringValue : nil)
        if projectButton.state == .on && project == nil { throw LocalCredentialError.invalidProject }
        let value = input.value
        try LocalCredentialStore.validateValue(value)
        return (name, project, value)
    }

    func clear() { input.clear(); onSave = nil; onCancel = nil }
}

final class CredentialsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let currentAccount: () -> String
    private let makeStore: (String) -> LocalCredentialStore
    private let actions: LocalCredentialActions
    private let presentConfirmation: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private var store: LocalCredentialStore
    private var snapshot = LocalCredentialSnapshot(revision: nil, entries: [])
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton(title: "Add Credential", target: nil, action: nil)
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Value", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var editor: CredentialEditor?
    private var pendingDeleteAlert: NSAlert?
    private var storageAvailable = false

    init(account: @escaping () -> String = { AstationIdentity.shared.id },
         makeStore: @escaping (String) -> LocalCredentialStore = { LocalCredentialStore(account: $0) },
         authenticate: @escaping LocalCredentialActions.Authenticate = LocalCredentialActions.touchID,
         presentConfirmation: @escaping (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
             alert, window, completion in alert.beginSheetModal(for: window, completionHandler: completion)
         }) {
        currentAccount = account
        self.makeStore = makeStore
        store = makeStore(account())
        actions = LocalCredentialActions(account: account, authenticate: authenticate)
        self.presentConfirmation = presentConfirmation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Credentials")
        title.font = .boldSystemFont(ofSize: 22)
        let detail = NSTextField(wrappingLabelWithString: "API keys and passwords saved in this Mac's protected Keychain. Choose Global or a Git project. Changes and copies require Touch ID.")
        detail.textColor = .secondaryLabelColor
        let availability = NSTextField(wrappingLabelWithString: "Available on this Mac. Atem credential retrieval is not available in this version.")
        availability.font = .systemFont(ofSize: 11)
        availability.textColor = .secondaryLabelColor
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 30
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Saved credentials")
        for (id, label, width) in [("name", "Name", 170.0), ("scope", "Scope", 210.0), ("version", "Version", 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        addButton.target = self; addButton.action = #selector(addCredential)
        updateButton.target = self; updateButton.action = #selector(updateCredential)
        copyButton.target = self; copyButton.action = #selector(copyCredential)
        deleteButton.target = self; deleteButton.action = #selector(deleteCredential)
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshCredentials))
        let buttons = NSStackView(views: [updateButton, copyButton, deleteButton, refresh])
        buttons.orientation = .horizontal
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail, availability, addButton, scroll, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            availability.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshCredentials()
    }

    override func viewWillAppear() { super.viewWillAppear(); refreshCredentials() }
    override func viewDidDisappear() { super.viewDidDisappear(); cancelPending() }

    func refreshForDisplay() {
        if (editor == nil && pendingDeleteAlert == nil && !actions.isBusy) || store.account != currentAccount() { refreshCredentials() }
    }

    func cancelPending() {
        closeEditor()
        if let alert = pendingDeleteAlert {
            pendingDeleteAlert = nil
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
            alert.window.orderOut(nil)
        }
        actions.cancel()
        updateButtons()
    }

    @objc private func refreshCredentials() {
        if store.account != currentAccount() {
            cancelPending()
            store = makeStore(currentAccount())
        }
        do {
            snapshot = try store.snapshot()
            storageAvailable = true
            status.stringValue = snapshot.entries.isEmpty ? "No credentials yet. Add a name and value to get started." : "\(snapshot.entries.count) saved credential(s). Select one to update, copy or delete."
        } catch {
            snapshot = LocalCredentialSnapshot(revision: nil, entries: [])
            storageAvailable = false
            status.stringValue = error.localizedDescription
        }
        table.reloadData()
        updateButtons()
    }

    private var selected: LocalCredentialMetadata? {
        snapshot.entries.indices.contains(table.selectedRow) ? snapshot.entries[table.selectedRow] : nil
    }

    private func updateButtons() {
        addButton.isEnabled = storageAvailable && !actions.isBusy && editor == nil && pendingDeleteAlert == nil
        for button in [updateButton, copyButton, deleteButton] {
            button.isEnabled = addButton.isEnabled && selected != nil
        }
    }

    @objc private func addCredential() { openEditor(entry: nil) }
    @objc private func updateCredential() { if let selected { openEditor(entry: selected) } }

    private func openEditor(entry: LocalCredentialMetadata?) {
        guard editor == nil, pendingDeleteAlert == nil, !actions.isBusy, storageAvailable, let window = view.window else { return }
        let form = CredentialEditor(entry: entry, snapshot: snapshot)
        editor = form
        form.onCancel = { [weak self] in self?.cancelPending() }
        form.onSave = { [weak self, weak form] in
            guard let self, let form else { return }
            do {
                let input = try form.validatedInput(), store = self.store
                form.saveButton.isEnabled = false
                form.status.stringValue = "Approve with Touch ID to save."
                self.actions.perform(account: store.account, reason: "save this credential", operation: {
                    try store.save(name: input.name, project: input.project, value: input.value,
                        updating: form.entry?.id, expectedRevision: form.revision)
                }) { [weak self, weak form] result in
                    guard let self, let form, self.editor === form else { return }
                    switch result {
                    case .success: self.closeEditor(); self.refreshCredentials(); self.status.stringValue = "Credential saved on this Mac."
                    case .failure(let error): form.status.stringValue = error.localizedDescription; form.saveButton.isEnabled = true
                    }
                    self.updateButtons()
                }
                self.updateButtons()
            } catch { form.status.stringValue = error.localizedDescription }
        }
        window.beginSheet(form.panel)
        updateButtons()
    }

    private func closeEditor() {
        guard let form = editor else { return }
        editor = nil
        form.clear()
        form.panel.sheetParent?.endSheet(form.panel)
        form.panel.orderOut(nil)
    }

    @objc private func copyCredential() {
        guard let selected, editor == nil, pendingDeleteAlert == nil else { return }
        let store = store, revision = snapshot.revision
        actions.perform(account: store.account, reason: "copy this credential", operation: {
            try store.value(id: selected.id, expectedRevision: revision)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): CredentialClipboard.shared.copy(value); self.status.stringValue = "Copied. The clipboard clears after 30 seconds."
            case .failure(let error): self.status.stringValue = error.localizedDescription
            }
            self.updateButtons()
        }
        updateButtons()
    }

    @objc private func deleteCredential() {
        guard let selected, editor == nil, pendingDeleteAlert == nil, !actions.isBusy, let window = view.window else { return }
        let store = store, revision = snapshot.revision
        let alert = NSAlert()
        alert.messageText = "Delete this credential?"
        alert.informativeText = "This removes \(selected.name) from \(selected.scopeLabel) on this Mac."
        alert.addButton(withTitle: "Delete with Touch ID")
        alert.addButton(withTitle: "Cancel")
        pendingDeleteAlert = alert
        updateButtons()
        presentConfirmation(alert, window) { [weak self, weak alert] response in
            guard let self, let alert, self.pendingDeleteAlert === alert else { return }
            self.pendingDeleteAlert = nil
            guard response == .alertFirstButtonReturn else { self.updateButtons(); return }
            self.actions.perform(account: store.account, reason: "delete this credential", operation: {
                try store.delete(id: selected.id, expectedRevision: revision)
            }) { [weak self] result in
                guard let self else { return }
                self.refreshCredentials()
                switch result {
                case .success: self.status.stringValue = "Credential deleted."
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
                self.updateButtons()
            }
            self.updateButtons()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshot.entries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard snapshot.entries.indices.contains(row) else { return nil }
        let entry = snapshot.entries[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "scope": text = entry.scopeLabel
        case "version": text = String(entry.version)
        default: text = entry.name
        }
        return NSTextField(labelWithString: text)
    }
}
