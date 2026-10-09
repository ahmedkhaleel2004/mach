import MachCore
import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Builds a large made-up mailbox for benchmarks, the same one every time for the same seed.
/// Nothing in it comes from real mail.
///
/// A module of its own, used only by the benchmark tool, so none of it is inside the app people use.
public enum SyntheticMailbox {
    /// A small, fast, repeatable random number generator (SplitMix64).
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }
        mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
        /// Small numbers far more often than large ones, the way word and sender frequencies are.
        mutating func skewed(_ bound: Int) -> Int {
            let a = Double(int(1_000_000)) / 1_000_000
            return min(bound - 1, Int(Double(bound) * a * a * a))
        }
    }

    private static let syllables = ["ka", "lo", "mi", "ren", "sta", "vi", "to", "ne", "sha", "bru", "del", "fo", "gan", "hi", "jo", "qua",
                                    "pe", "ras", "tum", "ul", "wex", "yor", "zen", "cla", "dri", "emb", "fli", "gro", "han", "ins"]

    private static func vocabulary(_ random: inout Random, count: Int) -> [String] {
        var words = Set<String>()
        while words.count < count {
            var word = ""
            for _ in 0..<(1 + random.int(3)) { word += syllables[random.int(syllables.count)] }
            words.insert(word)
        }
        return words.sorted()
    }

    private static func sentence(_ random: inout Random, _ words: [String], count: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(count)
        for _ in 0..<count { parts.append(words[random.skewed(words.count)]) }
        return parts.joined(separator: " ")
    }

    /// A newsletter the size real ones are: a style sheet, nested tables, inline styles, remote-looking images.
    private static func newsletter(_ random: inout Random, _ words: [String], kilobytes: Int) -> String {
        var html = "<html><head><style>body{margin:0;background:#f4f4f7}.w{width:600px}.c{font-family:Helvetica,Arial,sans-serif;font-size:14px;line-height:21px;color:#333}"
        for index in 0..<40 { html += ".s\(index){padding:\(index % 9)px;color:#\(String(format: "%06x", random.int(0xFFFFFF)))}" }
        html += "</style></head><body><table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" bgcolor=\"#f4f4f7\"><tr><td align=\"center\"><table class=\"w\" width=\"600\" cellpadding=\"0\" cellspacing=\"0\" bgcolor=\"#ffffff\">"
        while html.utf8.count < kilobytes * 1024 {
            html += "<tr><td class=\"c s\(random.int(40))\" style=\"padding:16px 24px;border-bottom:1px solid #eeeeee\">"
            html += "<table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr><td width=\"120\" valign=\"top\"><img src=\"https://images.bench.invalid/\(random.int(100000)).png\" width=\"120\" height=\"80\" alt=\"\" style=\"display:block;border:0\"></td>"
            html += "<td valign=\"top\" style=\"padding-left:16px\"><h2 style=\"margin:0 0 8px;font-size:18px;line-height:24px;color:#111111\">\(sentence(&random, words, count: 6))</h2>"
            html += "<p style=\"margin:0 0 12px\">\(sentence(&random, words, count: 60))</p>"
            html += "<a href=\"https://bench.invalid/\(random.int(100000))\" style=\"display:inline-block;padding:8px 16px;background:#5b5bd6;color:#ffffff;text-decoration:none;border-radius:4px\">\(sentence(&random, words, count: 2))</a></td></tr></table></td></tr>"
        }
        return html + "</table></td></tr></table></body></html>"
    }

    private static func personal(_ random: inout Random, _ words: [String], quoted: String?) -> String {
        var html = "<div dir=\"ltr\">"
        for _ in 0..<(1 + random.int(4)) { html += "<div>\(sentence(&random, words, count: 8 + random.int(60)))</div><div><br></div>" }
        html += "</div>"
        if let quoted {
            html += "<br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On an earlier day someone wrote:<br></div><blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\">\(quoted)</blockquote></div>"
        }
        return html
    }

    public static let accounts = ["one@bench.invalid", "two@bench.invalid"]

    /// Fills `store` with about `messages` messages split over two accounts. Returns how many it wrote.
    ///
    /// The mix: about 55% bulk mail (single-message newsletters of 20 to 150 KB), the rest conversations between
    /// people of 1 to 60 messages with quoted replies, and a few very long ones of 200. The newest tenth of the mail
    /// are in the inbox; some are unread, starred, sent or carry one of 12 user labels.
    @discardableResult
    public static func generate(into store: Store, messages target: Int = 50_000, seed: UInt64 = 1) throws -> Int {
        var random = Random(state: seed)
        let words = vocabulary(&random, count: 6000)
        let people: [String] = (0..<800).map { index in
            "\(words[index].capitalized) \(words[index + 900].capitalized) <\(words[index]).\(words[index + 900])@\(words[2000 + index % 60]).invalid>"
        }
        let senders: [String] = (0..<300).map { index in
            "\(words[3000 + index].capitalized) News <news@\(words[3000 + index]).invalid>"
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var written = 0
        var serial = 0
        for (order, account) in accounts.enumerated() {
            try store.saveAccount(Account(id: account, name: "Bench \(order + 1)", sortOrder: order))
            var labels = ["INBOX", "SENT", "DRAFT", "STARRED", "UNREAD", "TRASH", "SPAM", "IMPORTANT", "CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS",
                          "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"].map { MailLabel(accountId: account, id: $0, name: $0, type: "system") }
            for index in 0..<12 { labels.append(MailLabel(accountId: account, id: "Label_\(index + 1)", name: words[4000 + index].capitalized, type: "user")) }
            try store.syntheticReplaceLabels(labels, account: account)
            let share = order == 0 ? target * 3 / 5 : target - target * 3 / 5
            var made = 0
            // Newest first: `age` grows as the mailbox goes back in time, roughly ten minutes a message.
            var age: Int64 = 0
            var batch: [Message] = []
            var threadNumber = 0
            while made < share {
                threadNumber += 1
                let threadId = String(format: "t%02d%08x", order, threadNumber)
                let bulk = random.chance(55)
                let length = bulk ? 1 : (random.chance(1) ? 200 : (random.chance(60) ? 1 : 2 + random.skewed(59)))
                let inInbox = made < share / 10
                let unread = inInbox && random.chance(30)
                let starred = random.chance(2)
                let userLabel = random.chance(8) ? "Label_\(1 + random.int(12))" : nil
                let category = bulk ? ["CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"][random.int(4)] : "CATEGORY_PERSONAL"
                let subject = sentence(&random, words, count: 3 + random.int(7)).capitalized
                let other = bulk ? senders[random.skewed(senders.count)] : people[random.skewed(people.count)]
                var quoted: String?
                var references = ""
                let start = age + Int64(length) * 600_000
                for position in 0..<min(length, share - made) {
                    serial += 1
                    let fromMe = !bulk && position % 2 == 1
                    var messageLabels = fromMe ? ["SENT"] : [category]
                    if inInbox, !fromMe { messageLabels.append("INBOX") }
                    if unread, !fromMe, position == length - 1 { messageLabels.append("UNREAD") }
                    if starred, position == 0 { messageLabels.append("STARRED") }
                    if let userLabel { messageLabels.append(userLabel) }
                    let html = bulk ? newsletter(&random, words, kilobytes: 20 + random.skewed(130)) : personal(&random, words, quoted: quoted)
                    if !bulk { quoted = String(html.prefix(6000)) }
                    let header = "<m\(serial)@bench.invalid>"
                    var attachments: [Attachment] = []
                    if random.chance(6) {
                        attachments.append(Attachment(filename: "\(words[random.int(words.count)]).pdf", mimeType: "application/pdf", size: 20_000 + random.int(900_000),
                                                      attachmentId: "a\(serial)", contentId: nil, isInline: false))
                    }
                    batch.append(Message.synthetic(
                        accountId: account, id: String(format: "m%02d%08x", order, serial), threadId: threadId,
                        internalDate: now - start + Int64(position) * 600_000,
                        sender: fromMe ? "Bench \(order + 1) <\(account)>" : other, toList: fromMe ? other : "Bench \(order + 1) <\(account)>",
                        ccList: !bulk && random.chance(15) ? people[random.int(people.count)] : "", bccList: "", replyTo: "",
                        subject: position == 0 ? subject : "Re: " + subject, snippet: sentence(&random, words, count: 22),
                        labelIds: messageLabels, messageIdHeader: header, refs: references, bodyHTML: html, bodyText: nil, attachments: attachments))
                    references = references.isEmpty ? header : references + " " + header
                    made += 1
                }
                age = start
                if batch.count >= 400 {
                    try store.syntheticSaveMessages(account: account, messages: batch)
                    written += batch.count
                    batch.removeAll(keepingCapacity: true)
                }
            }
            try store.syntheticSaveMessages(account: account, messages: batch)
            written += batch.count
            // Every conversation here is whole, so nothing asks to be downloaded.
            try store.pool.write { db in
                try db.execute(sql: "INSERT OR IGNORE INTO full_thread(accountId, threadId) SELECT accountId, id FROM thread WHERE accountId = ?", arguments: [account])
            }
        }
        return written
    }

    // MARK: Mail with real pictures

    /// The conversations `addPictureMail` writes, in the first account: shape name and thread id.
    public static let pictureThreads = [("pics-data", "tpicdata0001"), ("pics-cid", "tpiccid00001"), ("pics-thread", "tpicthread01")]

    /// Adds three conversations whose pictures are real JPEGs (1200 by 800), so scrolling, decoding and the app's own
    /// picture addresses can be measured without the network. Never part of `generate`: a benchmark adds them to its
    /// own working copy.
    ///
    /// - `pics-data`: one desktop-width newsletter with 12 pictures written into the HTML itself (`data:`).
    /// - `pics-cid`: the same newsletter with its pictures as inline attachments (`cid:`).
    /// - `pics-thread`: 40 messages between people, each with two inline pictures.
    ///
    /// The attachments' bytes go to `folder/<message id>/<file name>`; the benchmark app copies them into its
    /// attachment cache, because nothing can be downloaded offline.
    public static func addPictureMail(into store: Store, pictures folder: URL) throws {
        var random = Random(state: 77)
        let words = vocabulary(&random, count: 600)
        let account = accounts[0]
        let me = "Bench 1 <\(account)>"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let jpegs = (0..<12).map { picture(seed: $0) }
        var messages: [Message] = []

        func save(_ data: Data, messageId: String, name: String) throws {
            let directory = folder.appendingPathComponent(messageId, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }
        /// A 600-wide table newsletter: a full-width picture, then text, twelve times. Every other picture carries no
        /// width or height, as much real mail does, so the page moves when it arrives.
        func newsletter(_ source: (Int) -> String) -> String {
            var html = "<html><head><style>body{margin:0;background:#f4f4f7}.w{width:600px}.c{font-family:Helvetica,Arial,sans-serif;font-size:14px;line-height:21px;color:#333}</style></head>"
            html += "<body><table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" bgcolor=\"#f4f4f7\"><tr><td align=\"center\"><table class=\"w\" width=\"600\" cellpadding=\"0\" cellspacing=\"0\" bgcolor=\"#ffffff\">"
            for index in 0..<12 {
                let sized = index % 2 == 0 ? " width=\"600\" height=\"400\"" : " width=\"600\""
                html += "<tr><td><img src=\"\(source(index))\"\(sized) alt=\"\" style=\"display:block;border:0\"></td></tr>"
                html += "<tr><td class=\"c\" style=\"padding:16px 24px\"><h2 style=\"margin:0 0 8px;font-size:18px;line-height:24px;color:#111111\">\(sentence(&random, words, count: 6))</h2>"
                html += "<p style=\"margin:0 0 12px\">\(sentence(&random, words, count: 90))</p></td></tr>"
            }
            return html + "</table></td></tr></table></body></html>"
        }
        func message(_ id: String, thread: String, position: Int, sender: String, to: String, subject: String, html: String, attachments: [Attachment]) -> Message {
            Message.synthetic(
                accountId: account, id: id, threadId: thread, internalDate: now - 3_600_000 + Int64(position) * 60_000, sender: sender, toList: to,
                ccList: "", bccList: "", replyTo: "", subject: subject, snippet: sentence(&random, words, count: 22),
                labelIds: sender == me ? ["SENT"] : ["CATEGORY_PERSONAL"], messageIdHeader: "<\(id)@bench.invalid>", refs: "", bodyHTML: html, bodyText: nil, attachments: attachments)
        }
        func inline(_ messageId: String, _ index: Int, _ data: Data) throws -> Attachment {
            let name = "picture\(index).jpg"
            try save(data, messageId: messageId, name: name)
            return Attachment(filename: name, mimeType: "image/jpeg", size: data.count, attachmentId: "pic-\(messageId)-\(index)", contentId: "pic\(index)@bench.invalid", isInline: true)
        }

        let news = "Pictures News <news@pictures.invalid>"
        messages.append(message("mpicdata0001", thread: "tpicdata0001", position: 0, sender: news, to: me, subject: "Twelve pictures in the mail itself",
                                html: newsletter { "data:image/jpeg;base64," + jpegs[$0].base64EncodedString() }, attachments: []))
        let cidFiles = try jpegs.enumerated().map { try inline("mpiccid00001", $0.offset, $0.element) }
        messages.append(message("mpiccid00001", thread: "tpiccid00001", position: 0, sender: news, to: me, subject: "Twelve attached pictures",
                                html: newsletter { "cid:pic\($0)@bench.invalid" }, attachments: cidFiles))
        let friend = "Pat Picture <pat@pictures.invalid>"
        for position in 0..<40 {
            let id = String(format: "mpicthr%05d", position)
            let files = try (0..<2).map { try inline(id, $0, jpegs[(position * 2 + $0) % jpegs.count]) }
            var html = "<div dir=\"ltr\"><div>\(sentence(&random, words, count: 40))</div>"
            for index in 0..<2 { html += "<div><img src=\"cid:pic\(index)@bench.invalid\" width=\"480\"></div><div>\(sentence(&random, words, count: 20))</div>" }
            html += "</div>"
            let fromMe = position % 2 == 1
            messages.append(message(id, thread: "tpicthread01", position: position, sender: fromMe ? me : friend, to: fromMe ? friend : me,
                                    subject: position == 0 ? "Forty messages with pictures" : "Re: Forty messages with pictures", html: html, attachments: files))
        }
        try store.syntheticSaveMessages(account: account, messages: messages)
        try store.pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO full_thread(accountId, threadId) SELECT accountId, id FROM thread WHERE accountId = ? AND id LIKE 'tpic%'", arguments: [account])
        }
    }

    /// A made-up photograph: soft coloured shapes, 1200 by 800, as a JPEG of 40 to 90 KB. The same for the same seed.
    private static func picture(seed: Int) -> Data {
        #if canImport(ImageIO)
        let width = 1200, height = 800
        var random = Random(state: UInt64(1000 + seed))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        func colour() -> CGColor { CGColor(red: Double(random.int(256)) / 255, green: Double(random.int(256)) / 255, blue: Double(random.int(256)) / 255, alpha: 0.75) }
        context.setFillColor(colour())
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<160 {
            context.setFillColor(colour())
            let size = Double(20 + random.int(260))
            context.fillEllipse(in: CGRect(x: Double(random.int(width)) - size / 2, y: Double(random.int(height)) - size / 2, width: size, height: size * (0.5 + Double(random.int(100)) / 100)))
        }
        let data = NSMutableData()
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
        #else
        return Data()
        #endif
    }
}
