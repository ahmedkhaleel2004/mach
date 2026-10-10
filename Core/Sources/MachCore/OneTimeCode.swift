import Foundation

/// Finds the sign-in code in a "here is your code" email, so it can be copied with one tap instead of read and typed.
///
/// It would rather miss a code than call an order number one: a message has to talk about a code, and the digits
/// have to sit where a code sits (right after the word, or alone on their own line).
public enum OneTimeCode {
    /// Words that say a message is about a code. Lowercase; matched anywhere in the subject or the opening text.
    private static let hints = [
        "verification code", "security code", "login code", "log-in code", "sign-in code", "sign in code", "signin code",
        "one-time", "one time", "single-use", "single use", "otp", "passcode", "pass code", "access code", "auth code",
        "authentication code", "authorization code", "confirmation code", "2fa", "two-factor", "two factor", "two-step", "2-step",
        "verify your", "your code", "code is", "code:", "enter this code", "enter the code", "following code", "use this code",
        "temporary code", "magic code", "identity code", "pin code", "code below", "entering the code", "enter code",
        "código", "codigo", "code de", "bestätigungscode", "sicherheitscode", "codice",
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// The shapes a code takes: 4 to 8 digits, 3+3 or 4+4 digits with a space or dash, or a short mix of capitals and digits.
    private static let digits = "(\\d{3}[ -]\\d{3}|\\d{4}[ -]\\d{4}|\\d{4,8})"
    /// "code is 123456", "code: 123 456", "passcode - G-123456", "OTP 1234".
    private static let afterWord = regex("(?<!promo |coupon |discount |voucher |zip |postal |area |country |referral |invite |gift |tracking |booking )\\b(?:code|otp|passcode|pin|código|codigo|codice)\\b(?:\\s+(?:is|est|es|lautet|ist))?\\s*[:=\\-–—]?\\s*(?:[A-Z]{1,3}-)?\(digits)(?![\\d.,/:-]*\\d)")
    /// "123456 is your verification code".
    private static let beforeWord = regex("(?<![\\d.,/:$#€£-])(?:[A-Z]{1,3}-)?\(digits)(?![\\d.,/:-]*\\d)\\s+(?:is|as)\\s+(?:your|the)\\b[^.\\n]{0,40}\\b(?:code|otp|passcode|pin)\\b")
    /// Digits alone on a line, the way most of these emails set the code apart.
    private static let alone = regex("(?m)^[ \\t]*\(digits)[ \\t]*$")
    /// A mixed code alone on a line: capitals and digits, at least one of each, such as "X7K2-9QPM" or "A1B2C3".
    private static let mixedAlone = try! NSRegularExpression(pattern: "(?m)^[ \\t]*((?=[A-Z0-9-]*\\d)(?=[A-Z0-9-]*[A-Z])[A-Z0-9]{3,5}-[A-Z0-9]{3,5}|(?=[A-Z0-9]*\\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{6,8})[ \\t]*$")

    public static func find(subject: String, text: String) -> String? {
        // Codes are in the subject or near the top. Reading no further keeps this cheap on long newsletters.
        let opening = String(text.prefix(1500))
        let lowered = (subject + "\n" + opening).lowercased()
        guard lowered.unicodeScalars.contains(where: { $0.value >= 48 && $0.value <= 57 }), hints.contains(where: { lowered.contains($0) }) else { return nil }
        for source in [subject, opening] {
            if let found = first(afterWord, in: source) ?? first(beforeWord, in: source) { return found }
        }
        if let found = first(alone, in: opening) ?? first(mixedAlone, in: opening, tidy: false) { return found }
        return nil
    }

    private static func first(_ pattern: NSRegularExpression, in text: String, tidy: Bool = true) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let found = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[found])
            let code = tidy ? raw.filter(\.isNumber) : raw
            // A lone four digits that reads as a year is a year.
            if tidy, code.count == 4, let year = Int(code), (1990...2100).contains(year) { continue }
            return code
        }
        return nil
    }
}
