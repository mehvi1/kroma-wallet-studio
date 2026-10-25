import Foundation

/// Extracts card references only from Wallet-specific log structures.
/// It intentionally does not treat arbitrary private-looking tokens as cards.
enum KromaCardScanner {
    private static let pathPatterns = [
        #"/(?:Passes/)?Cards/([-A-Za-z0-9_+=]{20,64})(?:\.pkpass|\.cache|\.pkcache|/|\s|\"|'|\)|,|$)"#,
        #"PDCardFileManager:\s*writing card\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#,
        #"PDPassLibrary:\s*wrote pass\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#,
        #"selected pass uniqueID\s*:\s*\"?([-A-Za-z0-9_+=]{20,64})\"?"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let inSessionList = try! NSRegularExpression(
        pattern: #"passIDs\[InSession\]\s*:\s*\{\s*\(([^)]*)\)"#,
        options: [.caseInsensitive]
    )
    private static let listToken = try! NSRegularExpression(pattern: #"[-A-Za-z0-9_+=]{20,64}"#)
    private static let reserved: Set<String> = ["<private>", "<redacted>"]

    static func cardIDs(in line: String) -> [String] {
        let fullRange = NSRange(line.startIndex..., in: line)
        var matches: [(Int, String)] = []
        for regex in pathPatterns {
            for match in regex.matches(in: line, range: fullRange) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                matches.append((match.range.location, String(line[range])))
            }
        }
        for match in inSessionList.matches(in: line, range: fullRange) {
            for token in listToken.matches(in: line, range: match.range(at: 1)) {
                guard let range = Range(token.range, in: line) else { continue }
                matches.append((token.range.location, String(line[range])))
            }
        }
        matches.sort { $0.0 < $1.0 }
        var seen = Set<String>()
        return matches.compactMap { _, id in
            guard !reserved.contains(id.lowercased()), seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
