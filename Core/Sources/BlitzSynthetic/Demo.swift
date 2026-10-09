import BlitzCore
import Foundation

extension SyntheticMailbox {
    public static let demoAccount = "alex@northwind.dev"

    /// A small, tidy, made-up inbox for screenshots. Every person, company and message in it is invented.
    public static func demo(into store: Store) throws {
        let account = demoAccount
        let me = "Alex Rivera <\(account)>"
        try store.saveAccount(Account(id: account, name: "Alex Rivera", sortOrder: 0))
        let labels = ["INBOX", "SENT", "DRAFT", "STARRED", "UNREAD", "TRASH", "SPAM", "IMPORTANT", "CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS",
                      "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"].map { MailLabel(accountId: account, id: $0, name: $0, type: "system") }
        try store.syntheticReplaceLabels(labels, account: account)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let minute: Int64 = 60_000
        var messages: [Message] = []
        var serial = 0

        /// One conversation: `(sender, body)` pairs, oldest first. `ago` is how long ago the last one arrived, in minutes.
        func thread(_ subject: String, ago: Int64, unread: Bool = false, starred: Bool = false, files: [Attachment] = [], _ parts: [(String, String)]) {
            serial += 1
            let threadId = String(format: "tdemo%06d", serial)
            for (index, part) in parts.enumerated() {
                let last = index == parts.count - 1
                let mine = part.0 == me
                var marks = mine ? ["SENT"] : ["INBOX", "CATEGORY_PERSONAL"]
                if last, unread, !mine { marks.append("UNREAD") }
                if last, starred { marks.append("STARRED") }
                let paragraphs = part.1.components(separatedBy: "\n\n").map { "<div>\($0.replacingOccurrences(of: "\n", with: "<br>"))</div>" }.joined(separator: "<div><br></div>")
                let id = String(format: "mdemo%06d%02d", serial, index)
                messages.append(Message.synthetic(
                    accountId: account, id: id, threadId: threadId, internalDate: now - ago * minute - Int64(parts.count - 1 - index) * 47 * minute,
                    sender: part.0, toList: mine ? parts.first { $0.0 != me }?.0 ?? "" : me, ccList: "", bccList: "", replyTo: "",
                    subject: index == 0 ? subject : "Re: " + subject, snippet: String(part.1.replacingOccurrences(of: "\n", with: " ").prefix(160)),
                    labelIds: marks, messageIdHeader: "<\(id)@demo.invalid>", refs: "",
                    bodyHTML: "<div dir=\"ltr\">\(paragraphs)</div>", bodyText: nil, attachments: last ? files : []))
            }
        }

        let maya = "Maya Okafor <maya@lumen.studio>"
        let jonas = "Jonas Weber <jonas@fernway.io>"
        let priya = "Priya Nair <priya@northwind.dev>"
        let theo = "Theo Lindqvist <theo@kiteworks.co>"
        let sam = "Sam Castellanos <sam@harborlabs.dev>"
        let ines = "Inès Moreau <ines@atelier-moreau.fr>"
        let dana = "Dana Whitfield <dana@whitfield.law>"
        let orbit = "Orbit <billing@orbit.cloud>"
        let relay = "Relay Air <trips@relayair.com>"
        let pine = "Pinecrest Bank <alerts@pinecrest.bank>"
        let loop = "Loop Weekly <hello@loopweekly.com>"
        let forge = "Forge <notifications@forge.dev>"

        thread("Launch checklist, final pass", ago: 4, unread: true, [
            (maya, "Alex, here is where we are:\n\n1. Pricing page is live behind the flag.\n2. The onboarding video is cut to 48 seconds.\n3. Press notes go out at 9:00 Thursday.\n\nThe only open item is the changelog. Can you take a look before lunch?"),
            (me, "Looks great. Two small things on pricing: the annual toggle should default to on, and the footnote still says beta.\n\nI will write the changelog now."),
            (maya, "Both fixed. Annual is the default and the footnote is gone.\n\nSend me the changelog when it is ready and we are done."),
        ])
        thread("Contract for the spring cohort", ago: 26, unread: true, files: [
            Attachment(filename: "Spring cohort agreement.pdf", mimeType: "application/pdf", size: 184_320, attachmentId: "demo-pdf", contentId: "", isInline: false),
        ], [
            (dana, "Hi Alex,\n\nAttached is the agreement with the two changes we discussed: payment within 30 days, and the option to renew at the same rate.\n\nIf it reads right to you, sign and send it back and I will countersign today."),
        ])
        thread("Dinner on Friday?", ago: 58, starred: true, [
            (ines, "We found a table at Cedar for 8:15. Theo is in, Priya is a maybe.\n\nAre you coming?"),
            (me, "Yes. I will bring the wine I owe you."),
        ])
        thread("Your flight to Lisbon is confirmed", ago: 95, [
            (relay, "Booking reference R7KQ2M\n\nToronto (YYZ) to Lisbon (LIS)\nThursday 14 May, 21:40, seat 14A\n\nOnline check-in opens 24 hours before departure."),
        ])
        thread("Benchmarks from last night", ago: 140, unread: true, [
            (jonas, "Ran the suite on the new build. Cold start is down from 610 ms to 190 ms, and the list no longer drops a frame on the old phones.\n\nI wrote up what changed. The short version: we stopped decoding pictures on the main thread."),
            (priya, "That matches what I see. Scrolling the 50,000 message mailbox is smooth now.\n\nNice work."),
        ])
        thread("Invoice 2048 is ready", ago: 205, [
            (orbit, "Your invoice for April is ready.\n\nAmount due: $42.00\nDue date: 1 May\n\nNothing to do if you pay by card: we will charge it on the due date."),
        ])
        thread("Notes from the design review", ago: 330, [
            (theo, "Three things came out of it:\n\nThe empty state needs one sentence, not three.\nThe swipe should tick the moment it takes.\nNothing should animate unless a finger is moving it.\n\nI will send the updated screens tomorrow."),
            (me, "Agree on all three. The third one is the whole product."),
            (theo, "Then let us write it on the wall."),
        ])
        thread("Welcome to the team", ago: 420, [
            (priya, "Sam starts Monday. I have set up the laptop and the accounts.\n\nCan you take the first week of pairing? I will take the second."),
            (me, "Happy to. I will block the mornings."),
        ])
        thread("A new sign-in to your account", ago: 560, [
            (pine, "We noticed a new sign-in to your Pinecrest account from a Mac in Toronto.\n\nIf this was you, there is nothing to do."),
        ])
        thread("Pull request #312 was merged", ago: 700, [
            (forge, "Sam Castellanos merged #312 into main.\n\nMake the thread view render before the first frame\n\n12 files changed, 148 additions, 96 deletions."),
        ])
        thread("Question about the API limits", ago: 1500, [
            (sam, "Is the limit per user or per project? The docs say both in different places.\n\nI am seeing 429s at about 2,000 units a minute."),
            (me, "Per user, and lower than the docs say. Pace at 30 a second and keep a reserve for anything the person is waiting on."),
            (sam, "That fixed it. Thank you."),
        ])
        thread("This week: the fastest apps we tried", ago: 1700, [
            (loop, "Five apps that feel instant, and what they have in common: they do the work before you ask, and they never make you watch it happen."),
        ])
        thread("Photos from Saturday", ago: 2900, [
            (ines, "Finally sorted them. The one of you falling off the paddleboard is the best picture I have ever taken."),
        ])
        thread("Re-ordering the roadmap", ago: 4400, [
            (maya, "I moved search above labels. Everyone asks for search first, and it is the smaller job."),
            (me, "Good call."),
        ])
        thread("Receipt from Orbit", ago: 6000, [
            (orbit, "Thanks for your payment of $42.00 for March."),
        ])
        thread("Reading list", ago: 8800, [
            (jonas, "Two papers on scheduling and one on why people perceive 100 ms as instant. The third is the one to read."),
        ])
        try store.syntheticSaveMessages(account: account, messages: messages)
        try store.pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO full_thread(accountId, threadId) SELECT accountId, id FROM thread WHERE accountId = ?", arguments: [account])
        }
    }
}
