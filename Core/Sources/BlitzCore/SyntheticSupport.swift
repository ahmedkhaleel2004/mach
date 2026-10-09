import Foundation

// The few doors the made-up-mailbox generator needs. The generator itself lives in the BlitzSynthetic module, which
// only the benchmark tool links, so it is not inside the app people use. These are visible inside this package only.

extension Message {
    package static func synthetic(accountId: String, id: String, threadId: String, internalDate: Int64, sender: String, toList: String, ccList: String,
                                  bccList: String, replyTo: String, subject: String, snippet: String, labelIds: [String], messageIdHeader: String,
                                  refs: String, bodyHTML: String?, bodyText: String?, attachments: [Attachment]) -> Message {
        Message(accountId: accountId, id: id, threadId: threadId, internalDate: internalDate, sender: sender, toList: toList, ccList: ccList,
                bccList: bccList, replyTo: replyTo, subject: subject, snippet: snippet, labelIds: labelIds, messageIdHeader: messageIdHeader,
                refs: refs, bodyHTML: bodyHTML, bodyText: bodyText, attachments: attachments)
    }
}

extension Store {
    package func syntheticReplaceLabels(_ labels: [MailLabel], account: String) throws { try replaceLabels(labels, account: account) }
    package func syntheticSaveMessages(account: String, messages: [Message]) throws { try saveMessages(account: account, messages: messages) }
}
