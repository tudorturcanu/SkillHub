import Foundation

/// Single source of truth for the rough token estimates shown across the app.
///
/// Real tokenizers differ per model and vocabulary; the ~4 characters/token
/// rule of thumb is close enough for a size hint and avoids pretending we know
/// the vendor's exact count.
enum TokenEstimator {
    static let charactersPerToken = 4.0

    static let helpText = "Rough estimate: about 4 characters per token. Real tokenizers vary."

    /// Characters / 4, rounded to the nearest whole token. Empty text is 0.
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charactersPerToken).rounded())
    }

    /// "~123 tokens (estimate)"
    static func label(for text: String) -> String {
        "~\(estimate(text)) tokens (estimate)"
    }
}
