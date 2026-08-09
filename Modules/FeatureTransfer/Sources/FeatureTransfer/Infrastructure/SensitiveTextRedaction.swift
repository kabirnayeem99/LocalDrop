import Foundation

/// Strips PIN values out of free-form text before it reaches a log sink or the UI.
///
/// The sender transmits the PIN as a `?pin=` query parameter (protocol section 4.1). Nothing in
/// LocalDrop logs a query string today — the server logs `url.path` only — but
/// `error.localizedDescription` on a transport error can carry the failing URL, and that string
/// reaches both `AppLogger` *and* `ActiveTransferProgress.files[].errorSummary`, which is rendered
/// on screen. Redacting at those two boundaries keeps a future transport change from silently
/// leaking the user's PIN into logs or into the transfer card.
enum SensitiveTextRedaction {
    static let placeholder = "<redacted>"

    private static let pinQueryExpression = try? NSRegularExpression(
        pattern: #"(?i)\bpin=[^&\s"'<>\\)\]}]*"#
    )

    /// Replaces every `pin=<value>` occurrence with `pin=<redacted>`.
    static func redactingPINs(in text: String) -> String {
        guard let pinQueryExpression else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard pinQueryExpression.firstMatch(in: text, options: [], range: range) != nil else {
            return text
        }
        return pinQueryExpression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "pin=\(placeholder)"
        )
    }

    /// The single entry point every `error.localizedDescription` in the send path goes through.
    static func redactedDescription(of error: any Error) -> String {
        redactingPINs(in: error.localizedDescription)
    }
}
