import Foundation

// MARK: - Base64url

extension Data {
    init?(base64URL string: String) {
        // Message bodies arrive this way, hundreds of kilobytes at a time, so the usual case (plain ASCII) is done
        // on the bytes in one pass. Anything else takes the slower route below and gets the same answer.
        var bytes = Data(string.utf8)
        let plain = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            for index in 0..<buffer.count {
                let byte = buffer[index]
                if byte == UInt8(ascii: "-") {
                    buffer[index] = UInt8(ascii: "+")
                } else if byte == UInt8(ascii: "_") {
                    buffer[index] = UInt8(ascii: "/")
                } else if byte >= 0x80 || byte == 13 {
                    // Not ASCII, or a carriage return (which can pair up with a line feed and change the count below).
                    return false
                }
            }
            return true
        }
        if plain {
            let remainder = bytes.count % 4
            if remainder > 0 { bytes.append(contentsOf: [UInt8](repeating: UInt8(ascii: "="), count: 4 - remainder)) }
            self.init(base64Encoded: bytes, options: .ignoreUnknownCharacters)
            return
        }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

    func base64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Charsets

enum Charset {
    static func decode(_ data: Data, charset: String?) -> String {
        if let charset, !charset.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: encoding) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pulls a parameter such as `charset` or `name` out of a Content-Type style header.
    static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { String($0).trimmed }
            guard pair.count == 2, pair[0].lowercased() == name else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return nil
    }
}

// MARK: - RFC 2047 encoded words

public enum MIMEWords {
    private static let pattern = try! NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=")
    private static let gap = try! NSRegularExpression(pattern: "(\\?=)\\s+(=\\?)")

    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        // Whitespace between two encoded words is not part of the text.
        let joined = gap.stringByReplacingMatches(in: input, range: NSRange(input.startIndex..., in: input), withTemplate: "$1$2")
        let ns = joined as NSString
        var out = ""
        var cursor = 0
        // Older mailers cut a multi-byte character across two encoded words, so words that touch and share a
        // charset are joined as bytes first and decoded once.
        var pending = Data()
        var pendingCharset = ""
        func flush() {
            guard !pending.isEmpty else { return }
            out += Charset.decode(pending, charset: pendingCharset)
            pending = Data()
        }
        for match in pattern.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
            let charset = ns.substring(with: match.range(at: 1))
            if match.range.location != cursor || charset.lowercased() != pendingCharset.lowercased() {
                flush()
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let kind = ns.substring(with: match.range(at: 2)).lowercased()
            let payload = ns.substring(with: match.range(at: 3))
            let data = kind == "b" ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) : decodeQ(payload)
            if let data {
                pending.append(data)
                pendingCharset = charset
            } else {
                flush()
                out += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        flush()
        out += ns.substring(from: cursor)
        return out
    }

    private static func decodeQ(_ text: String) -> Data {
        var bytes: [UInt8] = []
        let chars = Array(text.utf8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "_") {
                bytes.append(0x20)
            } else if c == UInt8(ascii: "="), i + 2 < chars.count,
                      let v = UInt8(String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(v)
                i += 2
            } else {
                bytes.append(c)
            }
            i += 1
        }
        return Data(bytes)
    }

    /// Encodes a header value when it has characters outside ASCII.
    public static func encode(_ text: String) -> String {
        if text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) { return text }
        // Each encoded word may be at most 75 characters, so split on character boundaries.
        var words: [String] = []
        var chunk = ""
        for ch in text {
            if (chunk + String(ch)).utf8.count > 39 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
}

// MARK: - HTML helpers

public enum HTMLText {
    private static let blocks = try! NSRegularExpression(pattern: "<(style|script|head|title)\\b[^>]*>.*?</\\1>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let breaks = try! NSRegularExpression(pattern: "<(br|/p|/div|/tr|/li|/h[1-6])\\b[^>]*>", options: [.caseInsensitive])
    private static let tags = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let spaces = try! NSRegularExpression(pattern: "[ \\t\\u00a0\\u200b\\u200c\\ufeff]+")
    private static let lines = try! NSRegularExpression(pattern: "\\s*\\n\\s*")
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "zwnj": "", "zwj": "",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}", "mdash": "\u{2014}",
        "ndash": "\u{2013}", "hellip": "\u{2026}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "bull": "\u{2022}",
    ]

    /// Reduces HTML to readable plain text. Used for search and snippets, not for display.
    public static func strip(_ html: String, limit: Int = 40_000) -> String {
        var s = html
        func replace(_ re: NSRegularExpression, _ with: String) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
        }
        if let text = withoutTags(html, limit: limit * 6) {
            s = text
        } else {
            if html.count > limit * 6 { s = String(html.prefix(limit * 6)) }
            replace(blocks, " ")
            replace(breaks, "\n")
            replace(tags, " ")
        }
        s = squeezed(decodeEntities(s)).trimmed
        // A string can only be longer than `limit` characters if it is longer than `limit` bytes.
        return s.utf8.count > limit && s.count > limit ? String(s.prefix(limit)) : s
    }

    /// What the pattern `\s` matches (a test checks this list against the pattern for every character).
    static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// `strip` as it was first written, one pattern per step. Kept as the yardstick the faster one is tested against.
    @_spi(Bench) public static func stripReference(_ html: String, limit: Int = 40_000) -> String {
        var s = html.count > limit * 6 ? String(html.prefix(limit * 6)) : html
        func replace(_ re: NSRegularExpression, _ with: String) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
        }
        replace(blocks, " ")
        replace(breaks, "\n")
        replace(tags, " ")
        s = decodeEntities(s)
        replace(spaces, " ")
        replace(lines, "\n")
        s = s.trimmed
        return s.count > limit ? String(s.prefix(limit)) : s
    }


    /// The length in bytes of the white space character at `index`, or 0 if there is none. White space here is
    /// what `\\s` means in a pattern, checked against the pattern engine itself: U+0009 to U+000D, space, U+0085 and every Unicode separator.
    private static func whiteSpace(_ input: UnsafeBufferPointer<UInt8>, _ index: Int) -> Int {
        let byte = input[index]
        if byte < 0x80 { return byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) ? 1 : 0 }
        if byte == 0xC2 { return index + 1 < input.count && (input[index + 1] == 0xA0 || input[index + 1] == 0x85) ? 2 : 0 }
        guard index + 2 < input.count else { return 0 }
        let second = input[index + 1], third = input[index + 2]
        switch (byte, second) {
        case (0xE1, 0x9A): return third == 0x80 ? 3 : 0
        case (0xE2, 0x80): return (third >= 0x80 && third <= 0x8A) || third == 0xA8 || third == 0xA9 || third == 0xAF ? 3 : 0
        case (0xE2, 0x81): return third == 0x9F ? 3 : 0
        case (0xE3, 0x80): return third == 0x80 ? 3 : 0
        default: return 0
        }
    }

    /// Turns every run of spaces, tabs, no-break spaces and zero-width padding into one space, and then every run
    /// of white space with a line break in it into one line break. (This used to be the patterns
    /// `[ \\t\\u00a0\\u200b\\u200c\\ufeff]+` and `\\s*\\n\\s*`; done on the bytes it is several times faster.)
    static func squeezed(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var spaced: [UInt8] = []
        spaced.reserveCapacity(bytes.count)
        bytes.withUnsafeBufferPointer { input in
            var index = 0
            var inRun = false
            while index < input.count {
                let byte = input[index]
                var length = 0
                if byte == 0x20 || byte == 0x09 {
                    length = 1
                } else if byte == 0xC2, index + 1 < input.count, input[index + 1] == 0xA0 {
                    length = 2
                } else if index + 2 < input.count, (byte == 0xE2 && input[index + 1] == 0x80 && (input[index + 2] == 0x8B || input[index + 2] == 0x8C))
                            || (byte == 0xEF && input[index + 1] == 0xBB && input[index + 2] == 0xBF) {
                    length = 3
                }
                if length > 0 {
                    if !inRun { spaced.append(0x20) }
                    inRun = true
                    index += length
                } else {
                    spaced.append(byte)
                    inRun = false
                    index += 1
                }
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(spaced.count)
        spaced.withUnsafeBufferPointer { input in
            var index = 0
            while index < input.count {
                let length = whiteSpace(input, index)
                guard length > 0 else {
                    out.append(input[index])
                    index += 1
                    continue
                }
                // The whole run of white space starting here.
                var end = index
                var hasBreak = false
                while end < input.count {
                    let step = whiteSpace(input, end)
                    if step == 0 { break }
                    if input[end] == 0x0A { hasBreak = true }
                    end += step
                }
                if hasBreak {
                    out.append(0x0A)
                } else {
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: input[index..<end]))
                }
                index = end
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Removing tags, fast

    /// Does what the `blocks`, `breaks` and `tags` patterns above do, in that order, on the bytes instead of with
    /// regular expressions: the HTML of a newsletter is hundreds of kilobytes and this runs for every stored message.
    /// Returns nil for the rare input it cannot be sure to treat exactly as the patterns would (a character outside
    /// ASCII right where a tag name is being read); the caller then uses the patterns.
    static func withoutTags(_ html: String, limit: Int) -> String? {
        var bytes: [UInt8]
        if html.utf8.count <= limit {
            bytes = Array(html.utf8)
        } else if let end = html.index(html.startIndex, offsetBy: limit, limitedBy: html.endIndex) {
            bytes = Array(html[..<end].utf8)
        } else {
            bytes = Array(html.utf8)
        }
        // Once no closing tag of a kind is left, no later opening tag of that kind can match either.
        var unclosed = Set<Int>()
        guard let noBlocks = replacing(bytes, with: UInt8(ascii: " "), match: { input, at in
            for (kind, name) in blockNames.enumerated() {
                guard let afterName = try tagName(input, at + 1, name) else { continue }
                guard !unclosed.contains(kind), let close = indexOf(UInt8(ascii: ">"), in: input, from: afterName) else { return nil }
                // The shortest stretch up to the first matching closing tag.
                var search = close + 1
                while let open = indexOf(UInt8(ascii: "<"), in: input, from: search) {
                    if open + 1 < input.count, input[open + 1] == UInt8(ascii: "/"), let end = try letters(input, open + 2, name),
                       end < input.count, input[end] == UInt8(ascii: ">") {
                        return end + 1
                    }
                    search = open + 1
                }
                unclosed.insert(kind)
                return nil
            }
            return nil
        }) else { return nil }
        bytes = noBlocks
        guard let noBreaks = replacing(bytes, with: UInt8(ascii: "\n"), match: { input, at in
            for name in breakNames {
                guard var afterName = try letters(input, at + 1, name) else { continue }
                if name.count == 2, name[1] == UInt8(ascii: "h") {
                    // A closing heading: one digit from 1 to 6 follows.
                    guard afterName < input.count, input[afterName] >= UInt8(ascii: "1"), input[afterName] <= UInt8(ascii: "6") else { continue }
                    afterName += 1
                }
                guard try wordEnds(input, afterName) else { continue }
                guard let close = indexOf(UInt8(ascii: ">"), in: input, from: afterName) else { return nil }
                return close + 1
            }
            return nil
        }) else { return nil }
        bytes = noBreaks
        guard let noTags = replacing(bytes, with: UInt8(ascii: " "), match: { input, at in
            // At least one character between the brackets.
            guard at + 1 < input.count, input[at + 1] != UInt8(ascii: ">"), let close = indexOf(UInt8(ascii: ">"), in: input, from: at + 2) else { return nil }
            return close + 1
        }) else { return nil }
        return String(decoding: noTags, as: UTF8.self)
    }

    private static let blockNames = ["style", "script", "head", "title"].map { Array($0.utf8) }
    private static let breakNames = ["br", "/p", "/div", "/tr", "/li", "/h"].map { Array($0.utf8) }

    /// Thrown when the bytes cannot be judged without knowing Unicode's rules for letters and case.
    private struct NotPlain: Error {}

    private static func indexOf(_ byte: UInt8, in input: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start < input.count, let found = memchr(input.baseAddress! + start, Int32(byte), input.count - start) else { return nil }
        return input.baseAddress!.distance(to: found.assumingMemoryBound(to: UInt8.self))
    }

    /// The index after `name` if it stands at `start`, whatever its case.
    private static func letters(_ input: UnsafeBufferPointer<UInt8>, _ start: Int, _ name: [UInt8]) throws -> Int? {
        for (offset, wanted) in name.enumerated() {
            guard start + offset < input.count else { return nil }
            let byte = input[start + offset]
            if byte >= 0x80 { throw NotPlain() }
            let lowered = byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
            if lowered != wanted { return nil }
        }
        return start + name.count
    }

    /// Whether a word ends at `index`: the next character is not a letter, a digit or an underscore.
    private static func wordEnds(_ input: UnsafeBufferPointer<UInt8>, _ index: Int) throws -> Bool {
        guard index < input.count else { return true }
        let byte = input[index]
        if byte >= 0x80 { throw NotPlain() }
        let isWord = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_")
        return !isWord
    }

    private static func tagName(_ input: UnsafeBufferPointer<UInt8>, _ start: Int, _ name: [UInt8]) throws -> Int? {
        guard let end = try letters(input, start, name), try wordEnds(input, end) else { return nil }
        return end
    }

    /// Copies `bytes`, replacing every stretch that `match` recognises at a "<" with one byte. `match` returns the
    /// index after the stretch, or nil when nothing starts at that "<". Returns nil if `match` gave up.
    private static func replacing(_ bytes: [UInt8], with replacement: UInt8,
                                  match: (UnsafeBufferPointer<UInt8>, Int) throws -> Int?) -> [UInt8]? {
        bytes.withUnsafeBufferPointer { input -> [UInt8]? in
            var out: [UInt8] = []
            out.reserveCapacity(input.count)
            var copied = 0
            var cursor = 0
            do {
                while let open = indexOf(UInt8(ascii: "<"), in: input, from: cursor) {
                    if let end = try match(input, open) {
                        out.append(contentsOf: UnsafeBufferPointer(rebasing: input[copied..<open]))
                        out.append(replacement)
                        copied = end
                        cursor = end
                    } else {
                        cursor = open + 1
                    }
                }
            } catch {
                return nil
            }
            if copied == 0 { return bytes }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: input[copied..<input.count]))
            return out
        }
    }

    /// Replaces `&name;`, `&#123;` and `&#x1f;` with the characters they stand for. Anything it does not know stays as written.
    public static func decodeEntities(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        bytes.withUnsafeBufferPointer { input in
            let count = input.count
            func isHex(_ byte: UInt8) -> Bool {
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
            }
            func isLetter(_ byte: UInt8) -> Bool {
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            }
            var copied = 0
            var cursor = 0
            while let amp = indexOf(UInt8(ascii: "&"), in: input, from: cursor) {
                cursor = amp + 1
                var replacement: String?
                var end = amp + 1
                if end < count, input[end] == UInt8(ascii: "#") {
                    // A number: hexadecimal after a small x, decimal otherwise.
                    var digits = end + 1
                    var radix = 10
                    if digits < count, input[digits] == UInt8(ascii: "x") {
                        digits += 1
                        radix = 16
                    }
                    end = digits
                    while end < count, isHex(input[end]) { end += 1 }
                    guard end > digits, end < count, input[end] == UInt8(ascii: ";") else { continue }
                    if let value = UInt32(String(decoding: UnsafeBufferPointer(rebasing: input[digits..<end]), as: UTF8.self), radix: radix), let scalar = Unicode.Scalar(value) {
                        replacement = String(scalar)
                    }
                } else {
                    while end < count, isLetter(input[end]) { end += 1 }
                    guard end > amp + 1, end < count, input[end] == UInt8(ascii: ";") else { continue }
                    replacement = named[String(decoding: UnsafeBufferPointer(rebasing: input[(amp + 1)..<end]), as: UTF8.self).lowercased()]
                }
                cursor = end + 1
                guard let replacement else { continue }
                out.append(contentsOf: UnsafeBufferPointer(rebasing: input[copied..<amp]))
                out.append(contentsOf: replacement.utf8)
                copied = end + 1
            }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: input[copied..<count]))
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{034F}\u{00AD}\u{061C}\u{180E}")

    /// Removes the invisible padding senders stuff into previews and squeezes runs of whitespace.
    public static func tidy(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if invisible.contains(scalar) { continue }
            if scalar.properties.isWhitespace || scalar == "\u{00A0}" || scalar == "\u{2007}" || scalar == "\u{202F}" {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        return String(scalars).trimmed
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let link = try! NSRegularExpression(pattern: "(https?://[^\\s<>\"']+[^\\s<>\"'.,;:!?)\\]])")

    /// Turns typed plain text into simple HTML with clickable links.
    public static func fromPlain(_ text: String) -> String {
        let escaped = escape(text)
        let linked = link.stringByReplacingMatches(in: escaped, range: NSRange(escaped.startIndex..., in: escaped), withTemplate: "<a href=\"$1\">$1</a>")
        return linked.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>\n")
    }
}

// MARK: - Reading a Gmail payload

struct ParsedPayload {
    var headers: [String: String] = [:]
    var html: String?
    var text: String?
    var attachments: [Attachment] = []
    /// Small pictures Gmail hands over inside the message itself (no separate download), by Content-ID.
    var embedded: [String: String] = [:]

    /// The HTML with those pictures written straight in, so they show without any further request.
    var htmlWithEmbeddedImages: String? {
        guard var html, !embedded.isEmpty else { return html }
        for (contentId, dataURL) in embedded {
            html = html.replacingOccurrences(of: "cid:" + contentId, with: dataURL)
        }
        return html
    }
}

enum PayloadParser {
    static func parse(_ root: GPart?) -> ParsedPayload {
        var result = ParsedPayload()
        guard let root else { return result }
        for header in root.headers ?? [] {
            let key = header.name.lowercased()
            if result.headers[key] == nil { result.headers[key] = header.value }
        }
        walk(root, into: &result)
        return result
    }

    private static func headerValue(_ part: GPart, _ name: String) -> String? {
        part.headers?.first { $0.name.lowercased() == name }?.value
    }

    private static func walk(_ part: GPart, into result: inout ParsedPayload) {
        let mime = (part.mimeType ?? "").lowercased()
        if let children = part.parts, !children.isEmpty {
            for child in children { walk(child, into: &result) }
            return
        }
        let disposition = (headerValue(part, "content-disposition") ?? "").lowercased()
        let filename = part.filename ?? ""
        let contentId = headerValue(part, "content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        if let attachmentId = part.body?.attachmentId, !attachmentId.isEmpty {
            let inline = disposition.hasPrefix("inline") || (contentId != nil && !disposition.hasPrefix("attachment") && mime.hasPrefix("image/"))
            result.attachments.append(Attachment(
                filename: filename.isEmpty ? "attachment" : MIMEWords.decode(filename),
                mimeType: mime, size: part.body?.size ?? 0, attachmentId: attachmentId,
                contentId: contentId, isInline: inline && contentId != nil))
            return
        }
        guard !disposition.hasPrefix("attachment"), let encoded = part.body?.data, let data = Data(base64URL: encoded) else { return }
        if mime.hasPrefix("image/"), let contentId, data.count < 400_000 {
            result.embedded[contentId] = "data:\(mime);base64,\(data.base64EncodedString())"
            return
        }
        let charset = Charset.parameter("charset", in: headerValue(part, "content-type") ?? "")
        if mime == "text/html" {
            let html = Charset.decode(data, charset: charset)
            result.html = (result.html ?? "") + html
        } else if mime == "text/plain" {
            let text = Charset.decode(data, charset: charset)
            result.text = (result.text ?? "") + text
        }
    }
}

// MARK: - Writing a message to send

public struct OutgoingMessage: Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var text: String
    public var html: String
    public var inReplyTo: String
    public var references: String
    /// Set by us so a send whose answer was lost can be looked up instead of sent twice.
    public var messageId: String
    public var attachments: [(filename: String, mimeType: String, data: Data)]

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [], subject: String,
                text: String, html: String, inReplyTo: String = "", references: String = "", messageId: String = "",
                attachments: [(filename: String, mimeType: String, data: Data)] = []) {
        self.messageId = messageId
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }

    private static func wrapped(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    private static func addressHeader(_ list: [EmailAddress]) -> String {
        list.map { address in
            let email = clean(address.email).replacingOccurrences(of: " ", with: "")
            return address.name.isEmpty ? email : "\(quotedName(address.name)) <\(email)>"
        }.joined(separator: ", ")
    }

    /// Line breaks and other control characters must never reach a header: a display name could otherwise add
    /// headers of its own (a hidden Bcc, for one).
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : $0 }))
    }

    private static func quotedName(_ raw: String) -> String {
        let name = clean(raw)
        if !name.unicodeScalars.allSatisfy({ $0.isASCII }) { return MIMEWords.encode(name) }
        return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Breaks a long header over several lines at spaces. Mail servers reject lines over 998 characters and
    /// prefer them under 78.
    static func fold(_ line: String) -> String {
        guard line.count > 78 else { return line }
        var lines: [String] = []
        var current = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + 1 + word.count > 76 {
                lines.append(current)
                current = String(word)
            } else {
                current = current.isEmpty ? String(word) : current + " " + word
            }
        }
        lines.append(current)
        return lines.joined(separator: "\r\n ")
    }

    /// The full RFC 5322 message, ready to be base64url-encoded for the Gmail API.
    public func rfc822() -> Data {
        var lines: [String] = []
        lines.append("From: \(Self.addressHeader([from]))")
        if !to.isEmpty { lines.append("To: \(Self.addressHeader(to))") }
        if !cc.isEmpty { lines.append("Cc: \(Self.addressHeader(cc))") }
        if !bcc.isEmpty { lines.append("Bcc: \(Self.addressHeader(bcc))") }
        lines.append("Subject: \(MIMEWords.encode(Self.clean(subject)))")
        if !messageId.isEmpty { lines.append("Message-ID: \(Self.clean(messageId))") }
        if !inReplyTo.isEmpty { lines.append("In-Reply-To: \(Self.clean(inReplyTo))") }
        if !references.isEmpty { lines.append("References: \(Self.clean(references))") }
        lines = lines.map(Self.fold)
        lines.append("MIME-Version: 1.0")

        let altBoundary = "blitz-alt-\(UUID().uuidString)"
        var alternative = ""
        alternative += "--\(altBoundary)\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        alternative += Self.wrapped(Data(text.utf8)) + "\r\n"
        alternative += "--\(altBoundary)\r\nContent-Type: text/html; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        alternative += Self.wrapped(Data(html.utf8)) + "\r\n"
        alternative += "--\(altBoundary)--\r\n"

        var body = ""
        if attachments.isEmpty {
            lines.append("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
            body = alternative
        } else {
            let mixedBoundary = "blitz-mixed-\(UUID().uuidString)"
            lines.append("Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"")
            body += "--\(mixedBoundary)\r\nContent-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
            body += alternative
            for attachment in attachments {
                let name = MIMEWords.encode(attachment.filename.replacingOccurrences(of: "\"", with: "'"))
                body += "--\(mixedBoundary)\r\nContent-Type: \(attachment.mimeType); name=\"\(name)\"\r\n"
                body += "Content-Disposition: attachment; filename=\"\(name)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                body += Self.wrapped(attachment.data) + "\r\n"
            }
            body += "--\(mixedBoundary)--\r\n"
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }
}
