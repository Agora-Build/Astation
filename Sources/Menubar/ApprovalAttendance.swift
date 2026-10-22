import AppKit
import CoreGraphics
import SwiftUI

enum ApprovalAttendance {
    static func eligible(appActive: Bool, keyWindow: Bool, visible: Bool, idleSeconds: TimeInterval) -> Bool {
        appActive && keyWindow && visible && idleSeconds.isFinite && idleSeconds >= 0 && idleSeconds <= 60
    }
}

/// A mounted SwiftUI row alone is insufficient: scroll clipping, window focus
/// and recent physical input determine whether the card was actively seen.
struct ApprovalAttendanceView: NSViewRepresentable {
    let entry: ApprovalInboxEntry

    func makeNSView(context: Context) -> ApprovalAttendanceProbe { ApprovalAttendanceProbe() }
    func updateNSView(_ view: ApprovalAttendanceProbe, context: Context) {
        view.report = { [entry] in
            guard entry.available, entry.resolution == nil else { return }
            entry.client.markApprovalSeen(entry.request)
        }
    }
}

final class ApprovalAttendanceProbe: NSView {
    var report: (() -> Void)?
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func check() {
        let events: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let idle = events.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        guard ApprovalAttendance.eligible(appActive: NSApp.isActive && !NSApp.isHidden,
            keyWindow: window?.isKeyWindow == true,
            visible: window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty,
            idleSeconds: idle) else { return }
        report?()
    }

    deinit { timer?.invalidate() }
}
