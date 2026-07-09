import Foundation

/// How the user scoped an approval from the transcript card.
enum ApprovalScope: Equatable {
    case once, session
}

/// Pure approval policy for gated agent tools. The bundled pi extension
/// only raises approval requests for `write`, `edit`, and `bash` (reads run
/// without asking — see Resources/pi/lokalbot-extension/index.ts). This type
/// decides whether a raised request can be answered automatically
/// (auto-approve toggle, session allowances) or must be shown to the user.
struct AgentApprovalPolicy: Equatable {
    var autoApproveAll = false
    private(set) var sessionAllowedTools: Set<String> = []

    enum Verdict: Equatable { case allow, ask }

    func verdict(tool: String) -> Verdict {
        if autoApproveAll || sessionAllowedTools.contains(tool) { return .allow }
        return .ask
    }

    mutating func allowForSession(tool: String) {
        sessionAllowedTools.insert(tool)
    }

    mutating func resetSession() {
        sessionAllowedTools.removeAll()
    }
}
