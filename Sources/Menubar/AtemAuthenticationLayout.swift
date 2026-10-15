import AppKit
import LocalAuthenticationEmbeddedUI

enum AtemAuthenticationLayout {
    static let width: CGFloat = 420

    static func content(_ sections: [NSView]) -> NSStackView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.setFrameSize(stack.fittingSize)
        return stack
    }

    static func details(_ rows: [(String, String)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for (name, value) in rows {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = name == "Device" ? .systemFont(ofSize: 13, weight: .semibold)
                : name == "Boot ID" ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 12)
            field.isSelectable = true
            field.preferredMaxLayoutWidth = width - 32 - 90 - 12
            field.widthAnchor.constraint(equalToConstant: field.preferredMaxLayoutWidth).isActive = true
            let row = NSStackView(views: [label, field])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 12
            stack.addArrangedSubview(row)
        }
        return card(stack)
    }

    static func code(_ field: NSTextField) -> NSView {
        let caption = NSTextField(labelWithString: "SAFETY CODE")
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [caption, field])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        field.widthAnchor.constraint(equalToConstant: width - 32).isActive = true
        return card(stack, accented: true)
    }

    static func touchID(_ authentication: LAAuthenticationView, status: NSTextField,
                        passwordButton: NSButton) -> NSView {
        let size = authentication.fittingSize
        authentication.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        authentication.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        let title = NSTextField(labelWithString: "Verify on This Mac")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = width - 32 - size.width - 16
        status.widthAnchor.constraint(equalToConstant: status.preferredMaxLayoutWidth).isActive = true
        // Reserve room for failure guidance so the window does not jump during authentication.
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        passwordButton.bezelStyle = .rounded
        passwordButton.controlSize = .small
        let text = NSStackView(views: [title, status, passwordButton])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        let row = NSStackView(views: [authentication, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        return card(row)
    }

    static func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.alignment = .center
        field.preferredMaxLayoutWidth = width
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private static func card(_ content: NSView, accented: Bool = false) -> NSView {
        let card = AtemAuthenticationCard(accented: accented)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }
}

private final class AtemAuthenticationCard: NSView {
    private let accented: Bool
    override var wantsUpdateLayer: Bool { true }

    init(accented: Bool) {
        self.accented = accented
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (accented ? NSColor.controlAccentColor.withAlphaComponent(0.07)
                : NSColor.controlBackgroundColor).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        }
    }
}
