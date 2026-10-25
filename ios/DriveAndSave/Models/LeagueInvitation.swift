import Foundation

/// Local sharing format only; the backend still receives its existing UUID and join_code.
struct LeagueInvitation {
    let id: UUID
    let code: String
    static func parse(_ text: String) -> LeagueInvitation? {
        guard let idRange = text.range(of: #"(?i)League ID:\s*([0-9a-f-]{36})"#, options: .regularExpression),
              let uuidRange = text[idRange].range(of: #"[0-9a-fA-F-]{36}"#, options: .regularExpression),
              let id = UUID(uuidString: String(text[uuidRange])),
              let codeRange = text.range(of: #"(?i)Invite code:\s*([^\s·]+)"#, options: .regularExpression) else { return nil }
        let code = text[codeRange].split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (4...12).contains(code.count) else { return nil }
        return LeagueInvitation(id: id, code: code.uppercased())
    }
}
