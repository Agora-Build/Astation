import Foundation

struct AtemApprovalActivity: Equatable {
    let target: AtemSessionTarget
    let messageID: String
    let createdAt: Date
    let part: AgentChatPart
}
