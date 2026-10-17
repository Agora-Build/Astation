import AppKit
import WebKit

enum RemoteTerminalAssets {
    static var pageURL: URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "RemoteTerminal")
    }

    static func validate() throws {
        let files = ["index.html", "terminal.js", "terminal.css", "xterm.js", "xterm.css", "addon-fit.js",
                     "atem-unicode.js", "atem-unicode.cjs", "unicode-width-0.1.14.json", "xterm-LICENSE", "addon-fit-LICENSE"]
        guard let directory = pageURL?.deletingLastPathComponent() else { throw CocoaError(.fileReadNoSuchFile) }
        for file in files {
            if try Data(contentsOf: directory.appendingPathComponent(file)).isEmpty { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}

enum RemoteTerminalRendererAction {
    case ready
    case input(Data, epoch: String)
    case consumed(String)
    case size(rows: Int, cols: Int)
    case copy(String)
    case paste(epoch: String)
    case oversizedPaste
}

private final class WeakTerminalScriptHandler: NSObject, WKScriptMessageHandler {
    weak var renderer: RemoteTerminalRenderer?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        renderer?.receive(message)
    }
}

private final class TerminalWebView: WKWebView {
    var configureContextMenu: ((NSMenu) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        configureContextMenu?(menu)
    }
}

final class RemoteTerminalRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var isReady = false
    var onAction: ((RemoteTerminalRendererAction) -> Void)?
    var onFailure: (() -> Void)?
    private let handler: WeakTerminalScriptHandler
    private let pageURL: URL?
    private var inputEnabled = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        handler = WeakTerminalScriptHandler()
        configuration.userContentController.add(handler, name: "terminal")
        let terminalView = TerminalWebView(frame: .zero, configuration: configuration)
        webView = terminalView
        pageURL = RemoteTerminalAssets.pageURL
        super.init()
        handler.renderer = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        terminalView.configureContextMenu = { [weak self] menu in self?.configureContextMenu(menu) }
    }

    func load() {
        isReady = false
        inputEnabled = false
        guard let pageURL else { onFailure?(); return }
        do { try RemoteTerminalAssets.validate() } catch { onFailure?(); return }
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    func render(_ frame: RemoteTerminalFrame, token: String) {
        call("applyFrame", arguments: [["bytes": frame.bytes, "reset": frame.reset,
             "rows": frame.rows, "cols": frame.cols, "streamId": frame.stream.streamId], token])
    }

    func setControl(_ enabled: Bool, epoch: String) {
        inputEnabled = enabled
        guard isReady else { return }
        call("setControl", arguments: [enabled, epoch])
    }

    func paste(_ text: String, epoch: String, submit: Bool = false) { call("paste", arguments: [text, epoch, submit]) }
    func copySelection() { call("copySelection", arguments: []) }

    private func configureContextMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for (title, action, enabled) in [
            ("Copy", #selector(copyFromMenu(_:)), isReady),
            ("Paste", #selector(pasteFromMenu(_:)), isReady && inputEnabled),
            ("Select All", #selector(selectAllFromMenu(_:)), isReady)
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
        }
    }

    @objc private func copyFromMenu(_ sender: Any?) { copySelection() }
    @objc private func pasteFromMenu(_ sender: Any?) { call("requestPaste", arguments: []) }
    @objc private func selectAllFromMenu(_ sender: Any?) { call("selectAll", arguments: []) }

    private func call(_ method: String, arguments: [Any]) {
        guard isReady, let data = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.astationTerminal.\(method)(...\(json))") { [weak self] _, error in
            if error != nil { self?.onFailure?() }
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == pageURL?.standardizedFileURL,
              let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        switch op {
        case "ready": isReady = true; onAction?(.ready)
        case "input":
            guard let encoded = body["bytes"] as? String, encoded.utf8.count <= 21_848,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 16 * 1024,
                  let epoch = body["epoch"] as? String else { return }
            onAction?(.input(bytes, epoch: epoch))
        case "consumed":
            if let token = body["token"] as? String { onAction?(.consumed(token)) }
        case "size":
            if let rows = body["rows"] as? Int, let cols = body["cols"] as? Int,
               rows > 0, cols > 0, rows <= 100_000, cols <= 100_000 { onAction?(.size(rows: rows, cols: cols)) }
        case "copy":
            if let text = body["text"] as? String, text.utf8.count <= 1024 * 1024 { onAction?(.copy(text)) }
        case "paste":
            if let epoch = body["epoch"] as? String { onAction?(.paste(epoch: epoch)) }
        case "oversizedPaste": onAction?(.oversizedPaste)
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true
                        && navigationAction.request.url?.standardizedFileURL == pageURL?.standardizedFileURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed() }

    private func failed() { isReady = false; onFailure?() }
}
