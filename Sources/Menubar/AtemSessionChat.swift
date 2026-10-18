import Foundation

/// One ordered read subscription per target/attachment, shared by native
/// approval activity and the local API. Reading never acquires control.
final class AtemSessionChat {
    struct Snapshot: Encodable {
        let binding: AtemSessionBinding
        let chat_id: String
        var sequence: UInt64?
        var loaded = false
        var truncated = false
        var locally_truncated = false
        var oldest_retained: String?
        var holes: [AtemChatHole] = []
        var holes_more = false
        var page: AtemChatPage?
        var status: AgentChatStatus?
        var unavailable: [String] = []
        var error: String?
        var closed = false
        var reopens = 0
        var messages: [AgentChatWire] = []
    }
    struct HistoryReply: Encodable {
        let page_id: String
        var pending = true
        var error: String?
        var page: AtemChatPage?
        var sequence: UInt64?
        var messages: [AgentChatWire] = []
    }
    private struct View {
        var snapshot: Snapshot
        var order: [String] = []
        var messages: [String: AgentChatWire] = [:]
        var sizes: [String: Int] = [:]
        var versions: [String: UInt64] = [:]
        var replies: [String: HistoryReply] = [:]
        var pageIDs: [String] = []
        var pageTimes: [String: TimeInterval] = [:]
        var pageBytes: [String: Int] = [:]
        var pageContent: [String: Int] = [:]
        var initial: [String] = []
        var initialBytes = 0
        var initialContent = 0
        var historyTimes: [TimeInterval] = []
        var openedAt: TimeInterval = 0
    }
    private var views: [String: View] = [:]
    private var requested: [String: TimeInterval] = [:]
    private let send: (AgentChatWire) -> Bool
    private let now: () -> TimeInterval
    private let makeID: () -> String
    private let features: () -> Set<String>

    init(now: @escaping () -> TimeInterval, makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
         features: @escaping () -> Set<String> = { AtemSessionWire.features },
         send: @escaping (AgentChatWire) -> Bool) {
        self.now = now; self.makeID = makeID; self.send = send; self.features = features
    }

    var activities: [AtemApprovalActivity] {
        views.values.flatMap { view in
            view.messages.values.compactMap { event -> AtemApprovalActivity? in
                guard event.role == "assistant", let id = event.messageId, let date = event.createdAt?.date,
                      let part = event.parts?.first(where: { $0.kind == "approval" && $0.state == "auto_allowed" }) else { return nil }
                return AtemApprovalActivity(target: view.snapshot.binding.target, messageID: id, createdAt: date, part: part)
            }
        }.sorted { $0.createdAt > $1.createdAt }.prefix(64).map { $0 }
    }

    func reset(sendClose: Bool = true) {
        if sendClose { for view in views.values { close(view.snapshot) } }
        views = [:]
        requested = [:]
    }

    func sync(_ bindings: [AtemSessionBinding]) {
        let ids = Set(bindings.map { $0.target.session_id })
        requested = requested.filter { ids.contains($0.key) }
        let bindings = Array(bindings.sorted {
            let lhs = requested[$0.target.session_id] ?? -1, rhs = requested[$1.target.session_id] ?? -1
            return lhs == rhs ? $0.target.session_id < $1.target.session_id : lhs > rhs
        }.prefix(8))
        for (id, view) in views where !bindings.contains(view.snapshot.binding) {
            close(view.snapshot); views.removeValue(forKey: id)
        }
        for binding in bindings where views[binding.target.session_id] == nil { open(binding) }
    }

    func requestView(_ binding: AtemSessionBinding) {
        requested[binding.target.session_id] = now()
        if views[binding.target.session_id]?.snapshot.binding == binding { return }
        if views[binding.target.session_id] == nil, views.count >= 8,
           let oldest = views.keys.min(by: { (requested[$0] ?? -1) < (requested[$1] ?? -1) }),
           let old = views.removeValue(forKey: oldest) { close(old.snapshot) }
        open(binding)
    }

    @discardableResult
    func open(_ binding: AtemSessionBinding, conversationID: String? = nil) -> String {
        let id = binding.target.session_id
        if let view = views[id], view.snapshot.binding == binding, !view.snapshot.closed { return view.snapshot.chat_id }
        let snapshot = Snapshot(binding: binding, chat_id: conversationID ?? makeID())
        views[id] = View(snapshot: snapshot, openedAt: now())
        if !send(AgentChatWire(op: "open", conversationId: snapshot.chat_id, agentId: id, binding: binding)) {
            views[id]?.snapshot.closed = true
            views[id]?.snapshot.error = "delivery_uncertain"
        }
        return snapshot.chat_id
    }

    func snapshot(_ target: AtemSessionTarget) -> Snapshot? {
        guard let view = views[target.session_id], view.snapshot.binding.target == target else { return nil }
        var snapshot = view.snapshot
        // The API snapshot is bounded separately from the retained timeline.
        var bytes = 0
        for id in view.order.reversed().prefix(50) {
            guard let message = view.messages[id] else { continue }
            let size = view.sizes[id] ?? 0
            if bytes + size > 900_000 { snapshot.locally_truncated = true; break }
            bytes += size; snapshot.messages.insert(message, at: 0)
        }
        if snapshot.messages.count < view.order.count { snapshot.locally_truncated = true }
        return snapshot
    }

    func history(_ target: AtemSessionTarget, before: String? = nil, next: String? = nil,
                 turn: String? = nil, request: String? = nil, features: Set<String>) -> String? {
        guard features.contains("chat.history"), [before, next, turn, request].compactMap({ $0 }).count == 1,
              (turn == nil && request == nil) || features.contains("chat.lookup"),
              before.map(AtemSessionWire.opaque) != false, turn.map(AtemSessionWire.opaque) != false,
              request.map(AtemSessionWire.uuid) != false, next.map(AtemChatPage.validToken) != false,
              var view = views[target.session_id], view.snapshot.binding.target == target,
              view.snapshot.loaded, !view.snapshot.closed else { return nil }
        view.historyTimes.removeAll { now() - $0 >= 1 }
        guard view.historyTimes.count < 8, view.replies.values.filter(\.pending).count < 4 else { return nil }
        let pageID = makeID()
        view.historyTimes.append(now())
        view.replies[pageID] = HistoryReply(page_id: pageID)
        view.pageTimes[pageID] = now()
        view.pageIDs.append(pageID)
        while view.pageIDs.count > 4 {
            guard let index = view.pageIDs.firstIndex(where: { view.replies[$0]?.pending != true }) else { break }
            let oldest = view.pageIDs.remove(at: index)
            view.replies.removeValue(forKey: oldest); view.pageTimes.removeValue(forKey: oldest)
            view.pageBytes.removeValue(forKey: oldest)
            view.pageContent.removeValue(forKey: oldest)
        }
        views[target.session_id] = view
        var event = AgentChatWire(op: "history", conversationId: view.snapshot.chat_id, agentId: target.session_id,
            generation: target.process_gen, before: before, binding: view.snapshot.binding)
        event.page_id = pageID; event.next = next; event.turn_id = turn; event.request_id = request
        if !send(event) {
            views[target.session_id]?.replies[pageID]?.pending = false
            views[target.session_id]?.replies[pageID]?.error = "delivery_uncertain"
        }
        return pageID
    }

    func reply(_ target: AtemSessionTarget, pageID: String) -> HistoryReply? {
        guard views[target.session_id]?.snapshot.binding.target == target else { return nil }
        return views[target.session_id]?.replies[pageID]
    }

    func tick() {
        for (id, var view) in views {
            if !view.snapshot.loaded, !view.snapshot.closed, now() - view.openedAt >= 10 {
                view.snapshot.closed = true; view.snapshot.error = "history_unconfirmed"
            }
            for (pageID, time) in view.pageTimes where now() - time >= 10 && view.replies[pageID]?.pending == true {
                view.replies[pageID]?.pending = false; view.replies[pageID]?.error = "history_unconfirmed"
            }
            views[id] = view
        }
    }

    @discardableResult
    func receive(_ input: AgentChatWire) -> Bool {
        var event = input
        if !features().contains("approval.card_reason") {
            event.parts = event.parts?.map { part in var part = part; part.reason = nil; return part }
        }
        guard event.v == 1, var view = views[event.agentId], !view.snapshot.closed,
              event.conversationId == view.snapshot.chat_id,
              let encoded = try? JSONEncoder().encode(AstationMessage.agentChat(event)),
              max(encoded.count, event.wireBytes) <= 1_048_576 else { return false }
        let wireBytes = max(encoded.count, event.wireBytes)
        if event.op == "close" {
            if ["switched", "withdrawn", "restarted", "evicted", "fenced", "reset"].contains(event.reason ?? "") {
                resync(view)
            } else { view.snapshot.closed = true; view.snapshot.error = "chat_closed"; views[event.agentId] = view }
            return true
        }
        guard event.generation == view.snapshot.binding.target.process_gen,
              let sequence = event.sequence, sequence <= AtemSessionWire.maximumCounter else {
            if event.op == "error" { view.snapshot.closed = true; view.snapshot.error = event.code ?? "chat_unavailable"; views[event.agentId] = view }
            return false
        }
        if event.op == "opened" {
            guard view.snapshot.sequence == nil, sequence == 0, event.status?.isValid == true,
                  (event.unavailable?.count ?? 0) <= 32,
                  event.unavailable?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) != false else { return false }
            view.snapshot.status = event.status
            view.snapshot.unavailable = event.unavailable ?? []
        } else {
            guard let previous = view.snapshot.sequence, sequence > previous else { return false }
            guard sequence == previous + 1 else { resync(view); return true }
        }
        var valid = true
        switch event.op {
        case "opened": break
        case "message":
            guard let id = event.messageId, AtemSessionWire.opaque(id),
                  ["user", "assistant"].contains(event.role ?? ""), event.createdAt?.date != nil,
                  event.turnId.map(AtemSessionWire.opaque) == true, let parts = event.parts, parts.count <= 2048,
                  parts.allSatisfy(\.isValid), Set(parts.map(\.id)).count == parts.count,
                  parts.reduce(0, { $0 + $1.contentBytes }) <= 131_072 else { valid = false; break }
            let contentBytes = id.utf8.count + (event.turnId?.utf8.count ?? 0) + (event.requestId?.utf8.count ?? 0)
                + parts.reduce(0) { $0 + $1.historyBytes }
            if let pageID = event.page_id {
                guard view.replies[pageID] != nil else { break }
                guard view.replies[pageID]?.pending == true || view.replies[pageID]?.error == "history_unconfirmed" else { valid = false; break }
                view.replies[pageID]?.messages.append(event)
                view.pageBytes[pageID, default: 0] += wireBytes
                view.pageContent[pageID, default: 0] += contentBytes
                if let reply = view.replies[pageID], reply.messages.count > 50
                    || view.pageBytes[pageID, default: 0] > 1_048_576
                    || view.pageContent[pageID, default: 0] > 262_144 { valid = false; break }
            } else if event.history == true, !event.recovered, !view.snapshot.loaded {
                view.initial.append(id); view.initialBytes += wireBytes
                view.initialContent += contentBytes
                if view.initial.count > 50 || view.initialBytes > 1_048_576 || view.initialContent > 262_144 { valid = false; break }
            }
            // Stream positions order versions; a page can never regress a
            // newer whole message already applied by a native/API consumer.
            if sequence > (view.versions[id] ?? 0) {
                if view.messages[id] == nil {
                    if event.recovered {
                        if let after = event.after_message_id, let i = view.order.firstIndex(of: after) { view.order.insert(id, at: i + 1) }
                        else { view.order.insert(id, at: 0) }
                    } else if let pageID = event.page_id, view.replies[pageID]?.messages.count == 1 {
                        // Older pages are prepended at their explicit boundary.
                        view.order.append(id)
                    } else { view.order.append(id) }
                }
                view.messages[id] = event; view.sizes[id] = wireBytes; view.versions[id] = sequence
            }
        case "history_end":
            guard let page = event.page, page.valid else { valid = false; break }
            if let pageID = event.page_id {
                guard var reply = view.replies[pageID] else { break }
                guard (reply.pending || reply.error == "history_unconfirmed"), reply.messages.count == page.count,
                      view.pageBytes[pageID, default: 0] + wireBytes <= 1_048_576 else { valid = false; break }
                reply.pending = false; reply.error = nil; reply.page = page; reply.sequence = sequence; view.replies[pageID] = reply
                if ["newest", "before"].contains(page.selector) {
                    let ids = reply.messages.compactMap(\.messageId)
                    let known = Set(ids)
                    view.order = ids + view.order.filter { !known.contains($0) }
                }
            } else {
                guard !view.snapshot.loaded, page.selector == "newest", page.count == view.initial.count,
                      view.initialBytes + wireBytes <= 1_048_576 else { valid = false; break }
                view.snapshot.loaded = true; view.initial = []; view.initialBytes = 0; view.initialContent = 0
            }
            view.snapshot.page = page
            view.snapshot.truncated = view.snapshot.truncated || page.truncated
            view.snapshot.oldest_retained = page.oldest_retained
            for hole in page.holes where !view.snapshot.holes.contains(hole) { view.snapshot.holes.append(hole) }
            view.snapshot.holes_more = view.snapshot.holes_more || page.holes_more == true
        case "coverage":
            guard features().contains("chat.coverage") else { break }
            guard let holes = event.holes, holes.count <= 16, holes.allSatisfy(\.valid), event.truncated != nil,
                  event.oldest_retained.map(AtemSessionWire.opaque) != false else { valid = false; break }
            view.snapshot.truncated = view.snapshot.truncated || event.truncated == true
            view.snapshot.oldest_retained = event.oldest_retained
            view.snapshot.holes = holes; view.snapshot.holes_more = event.holes_more == true
        case "status":
            if let state = event.state, let since = event.since {
                let status = AgentChatStatus(state: state, since: since, detail: event.detail)
                if status.isValid { view.snapshot.status = status } else { valid = false }
            } else { valid = false }
        case "error":
            if let pageID = event.page_id, view.replies[pageID] != nil {
                view.replies[pageID]?.pending = false; view.replies[pageID]?.error = event.code ?? "history_unavailable"
            } else { view.snapshot.error = event.code ?? "chat_unavailable" }
        case "rules": break
        case "complete": valid = ["done", "interrupted"].contains(event.outcome ?? "")
        case "heartbeat": break
        default: valid = false
        }
        view.snapshot.sequence = sequence
        if !valid { close(view.snapshot); view.snapshot.closed = true; view.snapshot.error = "invalid_chat_message" }
        while view.order.count > 500 || view.sizes.values.reduce(0, +) > 8_388_608 {
            let id = view.order.removeFirst()
            view.messages.removeValue(forKey: id); view.sizes.removeValue(forKey: id); view.versions.removeValue(forKey: id)
            view.snapshot.locally_truncated = true
        }
        if view.snapshot.holes.count > 16 { view.snapshot.holes = Array(view.snapshot.holes.suffix(16)); view.snapshot.holes_more = true }
        views[event.agentId] = view
        return true
    }

    private func close(_ snapshot: Snapshot) {
        _ = send(AgentChatWire(op: "close", conversationId: snapshot.chat_id,
            agentId: snapshot.binding.target.session_id, binding: snapshot.binding))
    }

    private func resync(_ old: View) {
        close(old.snapshot)
        views.removeValue(forKey: old.snapshot.binding.target.session_id)
        if old.snapshot.reopens >= 2 {
            var failed = old
            failed.snapshot.closed = true; failed.snapshot.error = "refresh_required"
            views[old.snapshot.binding.target.session_id] = failed
            return
        }
        open(old.snapshot.binding)
        views[old.snapshot.binding.target.session_id]?.snapshot.reopens = old.snapshot.reopens + 1
    }
}
