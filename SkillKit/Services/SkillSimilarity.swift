import Foundation

/// Finds items whose instructions are nearly the same text — the usual result
/// of copying a skill into a second agent's folder and letting the copies drift.
///
/// Each document becomes a set of hashed word 3-grams ("shingles"); two
/// documents' similarity is the Jaccard index of their sets. Pure and
/// `Sendable`, so the dashboard can run it off the main actor.
enum SkillSimilarity {
    struct Document: Sendable {
        let id: String
        let text: String
    }

    struct Match: Sendable, Equatable {
        let leftID: String
        let rightID: String
        /// 0...1, where 1 means the same words in the same order.
        let similarity: Double
    }

    static let defaultThreshold = 0.8
    static let shingleSize = 3
    /// Below this many shingles a document is too short for the score to mean much.
    static let minimumShingles = 12

    /// Pairs at or above `threshold`, most similar first.
    static func matches(in documents: [Document], threshold: Double = defaultThreshold) -> [Match] {
        let shingled: [(id: String, shingles: Set<Int>)] = documents.compactMap { document in
            let set = shingles(document.text)
            return set.count >= minimumShingles ? (document.id, set) : nil
        }
        .sorted { $0.shingles.count < $1.shingles.count }

        var matches: [Match] = []
        for i in shingled.indices {
            let left = shingled[i]
            for j in shingled.indices where j > i {
                let right = shingled[j]
                // Sorted by size, so Jaccard ≤ |left| / |right| only shrinks from here.
                if Double(left.shingles.count) / Double(right.shingles.count) < threshold { break }
                let score = jaccard(left.shingles, right.shingles)
                if score >= threshold {
                    matches.append(Match(leftID: left.id, rightID: right.id, similarity: score))
                }
            }
        }
        return matches.sorted {
            $0.similarity != $1.similarity ? $0.similarity > $1.similarity : ($0.leftID, $0.rightID) < ($1.leftID, $1.rightID)
        }
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        jaccard(shingles(a), shingles(b))
    }

    static func shingles(_ text: String) -> Set<Int> {
        let words = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard words.count >= shingleSize else {
            return words.isEmpty ? [] : [words.joined(separator: " ").hashValue]
        }
        var result = Set<Int>()
        result.reserveCapacity(words.count)
        for start in 0...(words.count - shingleSize) {
            result.insert(words[start..<(start + shingleSize)].joined(separator: " ").hashValue)
        }
        return result
    }

    private static func jaccard(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        let shared = small.reduce(0) { large.contains($1) ? $0 + 1 : $0 }
        return Double(shared) / Double(a.count + b.count - shared)
    }
}
