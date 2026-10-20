import Foundation

/// Matches on-screen text to species. The battle screen shows only the base name
/// ("Ninetales" for Alolan or Shadow Ninetales), so a match returns every form
/// sharing that name, best ranked first.
public struct NameMatcher: Sendable {
    public struct Match: Sendable, Equatable {
        /// Normalized base name, e.g. "ninetales".
        public let key: String
        public let candidates: [Species]
        /// Edit distance between the text and the name; 0 is exact.
        public let distance: Int
    }

    private let byKey: [String: [Species]]

    public init(data: GameData) {
        var byKey: [String: [Species]] = [:]
        for s in data.species.values {
            byKey[Self.baseKey(s.speciesName), default: []].append(s)
        }
        self.byKey = byKey.mapValues { $0.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) } }
    }

    public func match(_ text: String) -> Match? {
        let key = Self.normalize(text)
        guard key.count >= 3 else { return nil }
        if let exact = byKey[key] {
            return Match(key: key, candidates: exact, distance: 0)
        }
        // Allow small OCR errors; longer names tolerate more.
        let allowed = key.count >= 9 ? 2 : key.count >= 5 ? 1 : 0
        guard allowed > 0 else { return nil }
        var best: Match?
        for (k, candidates) in byKey where abs(k.count - key.count) <= allowed {
            let d = Self.editDistance(key, k, limit: allowed)
            if d <= allowed, d < (best?.distance ?? .max) {
                best = Match(key: k, candidates: candidates, distance: d)
            }
        }
        return best
    }

    /// "Ninetales (Shadow)" -> "ninetales", "Mr. Mime" -> "mrmime".
    static func baseKey(_ speciesName: String) -> String {
        let base = speciesName.split(separator: "(").first.map(String.init) ?? speciesName
        return normalize(base)
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) && $0.isASCII })
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if cur.min()! > limit { return limit + 1 }  // can only grow from here
            prev = cur
        }
        return prev[b.count]
    }
}
