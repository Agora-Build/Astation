import Cocoa

private final class TokenToolsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

struct TokenToolsForm {
    var isRTM = false
    var usesAccount = false
    var channel = ""
    var identity = "1234"
    var role: AgoraTokenRole = .publisher
    var tokenExpiry = "3600"
    var privilegeExpiry = "3600"
    var customExpiries = ["3600", "3600", "3600", "3600"]
    var includeRTM = false
    var rtmUser = ""
    var rtmExpiry = "3600"

    func seconds(_ text: String) throws -> UInt32 {
        guard let value = UInt32(text), value > 0 else {
            throw AgoraTokenError.invalid("Enter an expiry from 1 to 4,294,967,295 seconds.")
        }
        return value
    }

    func generate(appID: String, certificate: String) throws -> String {
        if isRTM {
            return try AgoraTokenService.rtm(appID: appID, certificate: certificate, user: identity, expiry: seconds(tokenExpiry))
        }
        let user: AgoraTokenIdentity
        if usesAccount {
            guard identity.unicodeScalars.allSatisfy({ $0.isASCII }) else {
                throw AgoraTokenError.invalid("RTC user accounts must use ASCII characters and match the account used to join.")
            }
            user = .account(identity)
        }
        else {
            guard let uid = UInt32(identity) else {
                throw AgoraTokenError.invalid("Enter a numeric UID from 0 to 4,294,967,295, or choose User account.")
            }
            user = .uid(uid)
        }
        var request = AgoraRTCRequest(channel: channel, identity: user, role: role, tokenExpiry: try seconds(tokenExpiry))
        if role == .custom {
            guard customExpiries.count == 4 else { throw AgoraTokenError.invalid("Provide all four privilege expiries.") }
            request.joinExpiry = try seconds(customExpiries[0]); request.audioExpiry = try seconds(customExpiries[1])
            request.videoExpiry = try seconds(customExpiries[2]); request.dataExpiry = try seconds(customExpiries[3])
        } else { request.privilegeExpiry = try seconds(privilegeExpiry) }
        request.includeRTM = includeRTM
        if includeRTM {
            request.rtmUser = rtmUser.isEmpty ? nil : rtmUser
            request.rtmExpiry = try seconds(rtmExpiry)
        }
        return try AgoraTokenService.rtc(appID: appID, certificate: certificate, request: request)
    }
}

final class TokenToolsViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private let projects: () -> [AgoraProject]
    private let initialProjectID: String?
    var onClose: (() -> Void)?
    private var projectIDs: [String] = []
    private let projectPicker = NSPopUpButton()
    private let mode = NSSegmentedControl(labels: ["Generate", "Inspect"], trackingMode: .selectOne, target: nil, action: nil)
    private let kind = NSSegmentedControl(labels: ["RTC", "RTM"], trackingMode: .selectOne, target: nil, action: nil)
    private let identityType = NSPopUpButton()
    private let role = NSPopUpButton()
    private let appID = NSTextField()
    private let certificate = NSSecureTextField()
    private let channel = NSTextField()
    private let identity = NSTextField(string: "1234")
    private let tokenExpiry = NSTextField(string: "3600")
    private let privilegeExpiry = NSTextField(string: "3600")
    private let customExpiries = (0..<4).map { _ in NSTextField(string: "3600") }
    private let includeRTM = NSButton(checkboxWithTitle: "Also grant RTM login", target: nil, action: nil)
    private let rtmUser = NSTextField()
    private let rtmExpiry = NSTextField(string: "3600")
    private let result = NSTextView()
    private let tokenInput = NSTextView()
    private let inspection = NSTextView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let verification = NSTextField(wrappingLabelWithString: "Fields only. Decode a token to inspect its contents.")
    private let copy = NSButton(title: "Copy Token", target: nil, action: nil)
    private let inspectGenerated = NSButton(title: "Inspect", target: nil, action: nil)
    private let verify = NSButton(title: "Verify with Project", target: nil, action: nil)
    private var generation = NSStackView()
    private var inspector = NSStackView()
    private var customCredentials: NSStackView!
    private var channelRow: NSView!
    private var identityTypeRow: NSView!
    private var roleRow: NSView!
    private var privilegeRow: NSView!
    private var customRow: NSView!
    private var rtmRow: NSView!
    private var generatedToken: String?
    private var decoded: AgoraDecodedToken?

    init(projects: @escaping () -> [AgoraProject], initialProjectID: String?) {
        self.projects = projects
        self.initialProjectID = initialProjectID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 740))
        let heading = NSTextField(labelWithString: "Token Tools")
        heading.font = .boldSystemFont(ofSize: 22)
        let detail = NSTextField(wrappingLabelWithString: "Generate access for a channel and user, or inspect an existing token.")
        detail.textColor = .secondaryLabelColor
        projectIDs = projects().map(\.id)
        projectPicker.addItems(withTitles: projects().map { "\($0.name) (\($0.vendorKey.prefix(6))...)" } + ["Custom App ID..."])
        if let id = initialProjectID, let index = projectIDs.firstIndex(of: id) { projectPicker.selectItem(at: index) }
        else if projectIDs.isEmpty { projectPicker.selectItem(at: 0) }
        projectPicker.target = self; projectPicker.action = #selector(configurationChanged)
        projectPicker.setAccessibilityLabel("Token project")
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Token operation")
        kind.selectedSegment = 0; kind.target = self; kind.action = #selector(configurationChanged)
        kind.setAccessibilityLabel("Token service")
        identityType.addItems(withTitles: ["Numeric UID", "User account"])
        identityType.setAccessibilityLabel("RTC identity type")
        role.addItems(withTitles: ["Publisher", "Subscriber", "Custom expiries"])
        role.setAccessibilityLabel("RTC permissions")
        for popup in [identityType, role] { popup.target = self; popup.action = #selector(configurationChanged) }
        appID.placeholderString = "32-character App ID"
        certificate.placeholderString = "App Certificate (not saved)"
        channel.placeholderString = "Channel name"
        identity.toolTip = "Numeric UID 0 allows any user. User accounts must match the identity used to join."
        identity.setAccessibilityLabel("Token user identity")
        certificate.setAccessibilityLabel("Custom App Certificate")
        verification.setAccessibilityLabel("Token verification status")
        rtmUser.placeholderString = "Blank uses the RTC identity"
        includeRTM.target = self; includeRTM.action = #selector(configurationChanged)
        for field in [appID, certificate, channel, identity, tokenExpiry, privilegeExpiry, rtmUser, rtmExpiry] + customExpiries {
            field.delegate = self
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        customCredentials = stack([row("App ID", appID), row("Certificate", certificate)])
        let projectRow = row("Project", projectPicker)
        channelRow = row("Channel", channel)
        identityTypeRow = row("Identity type", identityType)
        roleRow = row("Permissions", role)
        privilegeRow = row("Privileges (s)", privilegeExpiry)
        let privilegeFields = zip(["Join", "Audio", "Video", "Data"], customExpiries).map { title, field -> NSView in
            stack([smallLabel(title), field])
        }
        let privileges = NSStackView(views: privilegeFields)
        privileges.orientation = .horizontal; privileges.distribution = .fillEqually; privileges.spacing = 8
        customRow = row("Expiries (s)", privileges)
        rtmRow = stack([row("RTM user ID", rtmUser), row("RTM expiry (s)", rtmExpiry)])
        let generate = NSButton(title: "Generate Token", target: self, action: #selector(generateToken))
        generate.bezelStyle = .rounded
        generate.keyEquivalent = "\r"
        generate.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
        generate.imagePosition = .imageLeading
        copy.target = self; copy.action = #selector(copyToken); copy.isEnabled = false
        inspectGenerated.target = self; inspectGenerated.action = #selector(inspectResult); inspectGenerated.isEnabled = false
        let buttons = NSStackView(views: [generate, copy, inspectGenerated])
        buttons.orientation = .horizontal; buttons.spacing = 8
        result.isEditable = false
        result.setAccessibilityLabel("Generated token")
        generation = stack([row("Service", kind), channelRow, identityTypeRow, row("User ID", identity), roleRow,
                            row("Token expiry (s)", tokenExpiry), privilegeRow, customRow, includeRTM, rtmRow,
                            buttons, message, textBox(result, height: 95)])
        tokenInput.delegate = self
        tokenInput.setAccessibilityLabel("Token to inspect")
        let decode = NSButton(title: "Decode Token", target: self, action: #selector(decodeToken))
        decode.bezelStyle = .rounded
        decode.keyEquivalent = "\r"
        verify.target = self; verify.action = #selector(verifyToken); verify.isEnabled = false
        let inspectionButtons = NSStackView(views: [decode, verify])
        inspectionButtons.orientation = .horizontal; inspectionButtons.spacing = 8
        inspection.isEditable = false
        inspection.setAccessibilityLabel("Decoded token fields")
        inspector = stack([smallLabel("Paste a token"), textBox(tokenInput, height: 100), inspectionButtons,
                           verification, textBox(inspection, height: 240)])
        inspector.isHidden = true
        let body = stack([projectRow, customCredentials, mode, generation, inspector])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = TokenToolsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
        let close = NSButton(title: "Close", target: self, action: #selector(closeTools))
        close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        let privacy = smallLabel("Generated on this Mac. App Certificates stay local.")
        for child in [heading, detail, scroll, privacy, close] {
            child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -16),
            close.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            close.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            privacy.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            privacy.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            privacy.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -12)
        ])
        updateVisibility()
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        return label
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for child in views {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 108).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        return row
    }

    private func textBox(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.documentView = text
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func credentials() throws -> (app: String, certificate: String) {
        if projectPicker.indexOfSelectedItem == projectIDs.count {
            return (appID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    certificate.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard projectIDs.indices.contains(projectPicker.indexOfSelectedItem),
              let project = projects().first(where: { $0.id == projectIDs[projectPicker.indexOfSelectedItem] }) else {
            throw AgoraTokenError.invalid("This project is no longer available. Refresh Projects and reopen Token Tools.")
        }
        return (project.vendorKey, project.signKey)
    }

    private func updateVisibility() {
        let rtc = kind.selectedSegment == 0
        customCredentials.isHidden = projectPicker.indexOfSelectedItem != projectIDs.count
        channelRow.isHidden = !rtc; identityTypeRow.isHidden = !rtc; roleRow.isHidden = !rtc
        privilegeRow.isHidden = !rtc || role.indexOfSelectedItem == 2
        customRow.isHidden = !rtc || role.indexOfSelectedItem != 2
        includeRTM.isHidden = !rtc; rtmRow.isHidden = !rtc || includeRTM.state != .on
        generation.isHidden = mode.selectedSegment != 0; inspector.isHidden = mode.selectedSegment == 0
    }

    private func invalidate() {
        generatedToken = nil; decoded = nil
        result.string = ""; inspection.string = ""; message.stringValue = ""
        copy.isEnabled = false; inspectGenerated.isEnabled = false; verify.isEnabled = false
        verification.stringValue = "Decoded fields do not establish authenticity. Verify with a project's certificate."
        verification.textColor = .secondaryLabelColor
    }

    @objc private func configurationChanged() { invalidate(); updateVisibility() }
    @objc private func modeChanged() { updateVisibility() }
    func controlTextDidChange(_ notification: Notification) { invalidate() }
    func textDidChange(_ notification: Notification) { invalidate() }
    @objc private func closeTools() { clearSensitiveContent(); onClose?() }

    func clearSensitiveContent() {
        certificate.stringValue = ""; tokenInput.string = ""; invalidate()
    }

    @objc private func generateToken() {
        invalidate()
        do {
            let credential = try credentials()
            let form = TokenToolsForm(isRTM: kind.selectedSegment == 1, usesAccount: identityType.indexOfSelectedItem == 1,
                                      channel: channel.stringValue, identity: identity.stringValue,
                                      role: [.publisher, .subscriber, .custom][role.indexOfSelectedItem],
                                      tokenExpiry: tokenExpiry.stringValue, privilegeExpiry: privilegeExpiry.stringValue,
                                      customExpiries: customExpiries.map(\.stringValue), includeRTM: includeRTM.state == .on,
                                      rtmUser: rtmUser.stringValue, rtmExpiry: rtmExpiry.stringValue)
            let token = try form.generate(appID: credential.app, certificate: credential.certificate)
            let fields = try AgoraTokenService.decode(token)
            generatedToken = token; result.string = token
            copy.isEnabled = true; inspectGenerated.isEnabled = true
            message.textColor = .systemGreen
            message.stringValue = "Generated. Expires \(fields.expiryDate.formatted(date: .abbreviated, time: .standard))."
        } catch { message.textColor = .systemRed; message.stringValue = error.localizedDescription }
    }

    @objc private func copyToken() {
        guard let generatedToken else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(generatedToken, forType: .string)
    }

    @objc private func inspectResult() {
        guard let generatedToken else { return }
        tokenInput.string = generatedToken
        mode.selectedSegment = 1; updateVisibility(); decodeToken()
    }

    @objc private func decodeToken() {
        decoded = nil; verify.isEnabled = false; inspection.string = ""
        verification.textColor = .secondaryLabelColor
        do {
            let fields = try AgoraTokenService.decode(tokenInput.string.trimmingCharacters(in: .whitespacesAndNewlines))
            decoded = fields; verify.isEnabled = true
            inspection.string = Self.describe(fields)
            verification.stringValue = "Decoded fields only. Signature not verified."
        } catch { verification.textColor = .systemRed; verification.stringValue = error.localizedDescription }
    }

    @objc private func verifyToken() {
        do {
            let credential = try credentials()
            let token = tokenInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = try AgoraTokenService.decode(token)
            let valid = try AgoraTokenService.verify(token, certificate: credential.certificate)
                && fields.app_id.caseInsensitiveCompare(credential.app) == .orderedSame
            if valid {
                let expired = fields.expiryDate <= Date()
                verification.textColor = expired ? .systemOrange : .systemGreen
                verification.stringValue = expired ? "Signature verified for this project. This token has expired."
                    : "Signature verified for this project. Check the service privileges and their expiry below."
            } else {
                verification.textColor = .systemRed
                verification.stringValue = "The token does not match this project's App ID and certificate."
            }
        } catch { verification.textColor = .systemRed; verification.stringValue = error.localizedDescription }
    }

    static func describe(_ token: AgoraDecodedToken) -> String {
        func date(_ value: Date) -> String { value.formatted(date: .abbreviated, time: .standard) }
        var lines = ["App ID: \(token.app_id)", "Format: \(token.version)", "Issued: \(date(token.issuedDate))",
                     "Token expires: \(date(token.expiryDate))", ""]
        for service in token.services {
            lines.append(service.details.kind.uppercased())
            if let channel = service.details.channel { lines.append("Channel: \(channel)") }
            if let account = service.details.account { lines.append("Account: \(account.isEmpty ? "Any UID (0)" : account)") }
            if let user = service.details.user_id { lines.append("User ID: \(user)") }
            let names: [String: String]
            switch service.service_type {
            case 1: names = ["1": "Join channel", "2": "Publish audio", "3": "Publish video", "4": "Publish data"]
            case 2: names = ["1": "Login"]
            default: names = [:]
            }
            for key in service.privileges.keys.sorted() {
                if let expiry = service.privileges[key] { lines.append("\(names[key] ?? "Privilege " + key): \(date(token.date(after: expiry)))") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
