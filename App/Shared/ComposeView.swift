import MachCore
import SwiftUI
import UniformTypeIdentifiers

/// The compose view when a message is being written, nothing otherwise. A view of its own so that typing, which
/// changes the message on every key, rebuilds only this and not the whole window behind it.
struct ComposeLayer: View {
    let model: AppModel
    /// Room left above it: the Mac's title bar. None on the phone.
    var top: CGFloat = 28

    var body: some View {
        // A reply to the open conversation is written in the conversation (`InlineReplyLayer`), not here.
        if model.compose != nil, !model.inlineReply {
            ComposeView(model: model).padding(.top, top)
        }
    }
}

/// The reply being written in the open conversation, drawn over the foot of the page as its next message. It sits
/// right under the last message, or along the bottom when the conversation is longer than the window, and the page
/// keeps that much room clear so every message can still be scrolled into view above it.
struct InlineReplyLayer: View {
    let model: AppModel

    var body: some View {
        if model.inlineReply {
            GeometryReader { geometry in
                InlineReplyPlace(model: model, room: geometry.size.height)
            }
        }
    }
}

/// Puts the reply where the conversation ends. A view of its own that reads nothing of the message itself, so a
/// letter typed rebuilds the editor inside it and not this.
private struct InlineReplyPlace: View {
    let model: AppModel
    /// The height there is for the conversation and the reply together: on the phone, down to the keyboard.
    let room: CGFloat
    @State private var height: CGFloat = 0

    var body: some View {
        let end = model.web.replyPlace.end
        ComposeView(model: model, inline: true, room: room)
            // Kept clear of the page's scroll bar, when it shows one, so the reply lines up with the messages.
            .padding(.trailing, model.web.replyPlace.gutter)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { value in
                height = value
                reserve()
            }
            .offset(y: max(0, min(end ?? .infinity, room - height)))
            // Not shown for the instant before the page has said where its last message ends: it would jump.
            .opacity(end == nil ? 0 : 1)
            .onChange(of: room) { _, _ in reserve() }
            .onDisappear { model.web.reserveReply(nil) }
    }

    /// The page keeps clear everything from the top of a reply docked at the bottom down to its own foot, which
    /// on the phone is under the keyboard.
    private func reserve() {
        guard height > 0 else { return }
        model.web.reserveReply(max(height, model.web.webView.bounds.height - (room - height)))
    }
}

struct ComposeView: View {
    @Bindable var model: AppModel
    /// Written in the open conversation, as its next message, instead of on a screen of its own.
    var inline = false
    /// The height the conversation and the reply have between them, when written in the conversation.
    var room: CGFloat = 0
    @FocusState private var focus: Field?
    @State private var showCopies = false
    /// In the conversation the recipients are one line, like a sent message's, until it is clicked.
    @State private var showDetails = false
    @State private var suggestionIndex = 0
    @State private var pickingFile = false
    #if os(macOS)
    @AppStorage(Theme.scaleKey) private var scale = Theme.defaultScale
    #endif

    enum Field: Hashable { case to, cc, bcc, subject, body }

    private var draft: Binding<Draft> {
        Binding(
            get: { model.compose ?? Draft(accountId: model.accountId) },
            set: { value in
                // A late edit must not bring back a message that was just sent or closed.
                guard model.compose != nil else { return }
                model.compose = value
                model.composeChanged()
            })
    }

    private var title: String {
        guard let current = model.compose else { return "" }
        if current.threadId != nil { return "Reply" }
        return current.quotedHTML.isEmpty ? "New Message" : "Forward"
    }

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("ComposeView")
        #endif
        Group {
            if inline { inlineBody } else { fullBody }
        }
        .onAppear {
            guard let current = model.compose else { return }
            showCopies = !current.cc.isEmpty || !current.bcc.isEmpty
            showDetails = current.to.isEmpty
            let want: Field = current.to.isEmpty ? .to : (current.subject.isEmpty ? .subject : .body)
            // A turn later: asked for while this view is still being put on screen, the Mac hands the keyboard to
            // the conversation behind it, or to nothing, and every key typed is lost.
            DispatchQueue.main.async { focus = want }
        }
        // R or A pressed again, or Reply touched, with the reply already open: back to writing.
        .onChange(of: model.replyFocusRequest) { _, _ in
            DispatchQueue.main.async { focus = .body }
        }
        #if DEBUG || BENCH
        .onChange(of: model.replyDetailsRequest) { _, _ in showDetails.toggle() }
        #endif
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let copy = Self.keepCopy(of: url), !draft.wrappedValue.attachmentPaths.contains(copy) {
                    draft.wrappedValue.attachmentPaths.append(copy)
                }
            }
        }
    }

    private var fullBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: { model.closeCompose() }) {
                    Image(systemName: "chevron.left").font(.system(size: Theme.pt(15), weight: .semibold)).foregroundStyle(Theme.dim)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(title).font(.system(size: Theme.pt(15), weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button(action: { pickingFile = true }) {
                    Image(systemName: "paperclip").font(.system(size: Theme.pt(15))).foregroundStyle(Theme.dim).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(action: { model.closeCompose(discard: true) }) {
                    Image(systemName: "trash").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.dim).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                sendButton
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.pt(48))

            VStack(spacing: 0) {
                if model.accounts.count > 1, let current = model.compose {
                    HStack(spacing: 10) {
                        Text("From").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.faint).frame(width: 56, alignment: .leading)
                        Text(current.accountId).font(.system(size: Theme.pt(15))).foregroundStyle(Theme.text)
                        Spacer()
                        if current.threadId == nil {
                            Text("Change").font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
                        }
                    }
                    .frame(height: Theme.pt(40))
                    .contentShape(Rectangle())
                    .onTapGesture { model.cycleComposeAccount() }
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                recipientRow("To", text: draft.to, field: .to, trailing: showCopies ? nil : "Cc Bcc")
                if showCopies {
                    recipientRow("Cc", text: draft.cc, field: .cc, trailing: nil)
                    recipientRow("Bcc", text: draft.bcc, field: .bcc, trailing: nil)
                }
                subjectRow
                Rectangle().fill(Theme.line).frame(height: 1)
                TextEditor(text: draft.body)
                    .font(.system(size: Theme.pt(15)))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .padding(.top, 10)
                    .padding(.leading, -5)
                attachmentChips
                quoteNote
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }

    private var sendButton: some View {
        Button(action: { model.sendCompose() }) {
            Text(model.compact ? "Send" : "Send  ⌘↵")
                .font(.system(size: Theme.pt(13), weight: .semibold))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var subjectRow: some View {
        HStack(spacing: 10) {
            Text("Subject").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.faint).frame(width: 56, alignment: .leading)
            TextField("", text: draft.subject)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.pt(15)))
                .foregroundStyle(Theme.text)
                .focused($focus, equals: .subject)
                .onSubmit { focus = .body }
        }
        .frame(height: Theme.pt(40))
    }

    @ViewBuilder
    private var attachmentChips: some View {
        if let current = model.compose, !current.attachmentPaths.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(current.attachmentPaths, id: \.self) { path in
                        HStack(spacing: 6) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: Theme.pt(12))).foregroundStyle(Theme.text).lineLimit(1)
                            Button(action: { draft.wrappedValue.attachmentPaths.removeAll { $0 == path } }) {
                                Image(systemName: "xmark").font(.system(size: Theme.pt(9), weight: .bold)).foregroundStyle(Theme.faint)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var quoteNote: some View {
        if let current = model.compose, !current.quotedHTML.isEmpty {
            HStack {
                Text("···").font(.system(size: Theme.pt(13), weight: .bold)).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 8).background(Theme.chip, in: Capsule())
                Text(current.threadId != nil ? "The earlier message is quoted below yours" : "The forwarded message is included")
                    .font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
                Spacer()
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: In the conversation

    /// A size taken from the conversation's page (`thread.html`), in points: the page is enlarged by the Mac's
    /// display size setting, or by the phone's text size, and the reply written in it has to match.
    private func u(_ size: CGFloat) -> CGFloat {
        #if os(macOS)
        size * scale
        #else
        Theme.pt(size)
        #endif
    }

    /// Laid out the way the page lays out an open message (`.msg` in `thread.html`): the line above, the face, the
    /// name, the "to" line, then the text, so what is typed is seen as it will sit in the conversation once sent.
    private var inlineBody: some View {
        let current = model.compose
        let me = current?.accountId ?? ""
        let faced = AvatarStore.enabled
        // On the phone the page starts a message's text at the edge, under the face.
        let indent: CGFloat = faced && !model.compact ? u(50) : 0
        let people = (EmailAddress.parseList(current?.to ?? "") + EmailAddress.parseList(current?.cc ?? "") + EmailAddress.parseList(current?.bcc ?? "")).map(\.displayName)
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .top, spacing: u(10)) {
                if faced {
                    ReplyFace(name: model.accounts.first { $0.id == me }?.name ?? "", email: me, size: u(40))
                }
                VStack(alignment: .leading, spacing: u(3)) {
                    HStack(spacing: u(8)) {
                        Text("Me").font(.system(size: u(14), weight: .semibold)).foregroundStyle(Theme.text)
                        Text("DRAFT").font(.system(size: u(11), weight: .semibold)).kerning(0.4).foregroundStyle(Theme.accent)
                    }
                    Text((people.isEmpty ? "add recipients" : "to " + people.joined(separator: ", ")) + (showDetails ? " ▴" : " ▾"))
                        .font(.system(size: u(12))).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                        .contentShape(Rectangle())
                        .onTapGesture { showDetails.toggle() }
                }
                .padding(.top, u(3))
                Spacer(minLength: 4)
                HStack(spacing: model.compact ? 0 : 4) {
                    inlineButton("chevron.down", size: 13, help: "Keep as a draft (Esc)") { model.closeCompose() }
                    inlineButton("paperclip", size: 15, help: "Attach files") { pickingFile = true }
                    inlineButton("trash", size: 14, help: "Discard") { model.closeCompose(discard: true) }
                    sendButton.padding(.leading, 6)
                }
                // On a narrow phone it is the "to" line that gives way, not these.
                .fixedSize()
                .frame(height: u(40))
            }
            .padding(.top, u(12))
            if showDetails {
                VStack(spacing: 0) {
                    recipientRow("To", text: draft.to, field: .to, trailing: showCopies ? nil : "Cc Bcc")
                    if showCopies {
                        recipientRow("Cc", text: draft.cc, field: .cc, trailing: nil)
                        recipientRow("Bcc", text: draft.bcc, field: .bcc, trailing: nil)
                    }
                    subjectRow
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                .padding(.leading, indent)
                .padding(.top, u(4))
            }
            inlineEditor
                .padding(.leading, indent)
                .padding(.top, u(12))
            Group {
                attachmentChips
                quoteNote
            }
            .padding(.leading, indent)
        }
        .padding(.horizontal, u(model.compact ? 14 : 28))
        .padding(.bottom, u(8))
        .frame(maxWidth: model.compact ? .infinity : u(860))
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    /// The text of the reply, as tall as what has been written. `TextEditor` takes all the room it is offered, so
    /// an unseen copy of the text is what has the height, and the editor is laid over it.
    private var inlineEditor: some View {
        // The page's size for the text of a message, on the Mac and the phone alike.
        let size = u(14)
        let text = model.compose?.body ?? ""
        #if os(macOS)
        let inset: CGFloat = 0
        #else
        // The phone's editor keeps this much above and below its text.
        let inset: CGFloat = 8
        #endif
        // A last line with nothing on it yet still counts as a line.
        return AtMost(height: max(u(72), room * 0.45)) {
            Text(text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
                .font(.system(size: size))
                .lineSpacing(size * 0.3)
                .padding(.horizontal, 5)
                .padding(.vertical, inset)
                .frame(maxWidth: .infinity, minHeight: u(72), alignment: .topLeading)
        }
            .hidden()
            .overlay {
                TextEditor(text: draft.body)
                    .font(.system(size: size))
                    .lineSpacing(size * 0.3)
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focus, equals: .body)
            }
            .padding(.horizontal, -5)
            .padding(.vertical, -inset)
    }

    private func inlineButton(_ icon: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: Theme.pt(size))).foregroundStyle(Theme.dim)
                .frame(width: model.compact ? 36 : 30, height: model.compact ? 40 : 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private static func keepCopy(of url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return AppModel.outgoingCopy(of: url)
    }

    private func lastToken(_ text: String) -> String {
        String(text.split(separator: ",", omittingEmptySubsequences: false).last ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func suggestions(for text: String) -> [Contact] {
        let token = lastToken(text)
        guard token.count >= 1, !token.contains("<") else { return [] }
        return model.contacts(matching: token).filter { $0.email != token.lowercased() }
    }

    private func accept(_ contact: Contact, into text: Binding<String>) {
        var parts = text.wrappedValue.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(contact.address.formatted)
        text.wrappedValue = parts.joined(separator: ", ") + ", "
        suggestionIndex = 0
    }

    @ViewBuilder
    private func recipientRow(_ label: String, text: Binding<String>, field: Field, trailing: String?) -> some View {
        let matches = focus == field ? suggestions(for: text.wrappedValue) : []
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: Theme.pt(14))).foregroundStyle(Theme.faint).frame(width: 56, alignment: .leading)
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.pt(15)))
                    .foregroundStyle(Theme.text)
                    .focused($focus, equals: field)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onKeyPress(.tab) {
                        guard matches.indices.contains(suggestionIndex) else { return .ignored }
                        accept(matches[suggestionIndex], into: text)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !matches.isEmpty else { return .ignored }
                        suggestionIndex = min(suggestionIndex + 1, matches.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !matches.isEmpty else { return .ignored }
                        suggestionIndex = max(suggestionIndex - 1, 0)
                        return .handled
                    }
                    .onSubmit {
                        if matches.indices.contains(suggestionIndex) {
                            accept(matches[suggestionIndex], into: text)
                            focus = field
                        } else {
                            focus = field == .to && !showCopies ? .subject : (field == .to ? .cc : (field == .cc ? .bcc : .subject))
                        }
                    }
                    .onChange(of: text.wrappedValue) { _, _ in suggestionIndex = 0 }
                if let trailing {
                    Button(trailing) { showCopies = true }
                        .buttonStyle(.plain)
                        .font(.system(size: Theme.pt(12)))
                        .foregroundStyle(Theme.faint)
                }
            }
            .frame(height: Theme.pt(40))
            ForEach(Array(matches.prefix(6).enumerated()), id: \.element.email) { index, contact in
                HStack(spacing: 8) {
                    Text(contact.name.isEmpty ? contact.email : contact.name).font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text).lineLimit(1)
                    if !contact.name.isEmpty { Text(contact.email).font(.system(size: Theme.pt(13))).foregroundStyle(Theme.faint).lineLimit(1) }
                    Spacer()
                }
                .padding(.leading, 66)
                .frame(height: Theme.pt(32))
                .background(index == suggestionIndex ? Theme.selection : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    accept(contact, into: text)
                    focus = field
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// As tall as what is in it, up to a limit: a long reply then scrolls inside itself and leaves some of the
/// conversation showing above it.
private struct AtMost: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The account's own picture beside a reply being written, the size the page draws a sender's face. Read whole
/// from the picture store: the list's small decoded copies would be soft at this size on the Mac.
private struct ReplyFace: View {
    let name: String
    let email: String
    let size: CGFloat
    @State private var image: Image?

    var body: some View {
        ZStack {
            Circle().fill(Color(light: AvatarStore.colorHex(for: email), dark: AvatarStore.colorHex(for: email)))
            Text(AvatarStore.initials(name.isEmpty ? email : name))
                .font(.system(size: size * 0.375, weight: .semibold))
                .foregroundStyle(.white)
            if let image {
                image.resizable().interpolation(.high).scaledToFill().background(Color.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: email) {
            guard AvatarStore.enabled, let data = await AvatarStore.shared.data(for: email) else { return }
            #if os(macOS)
            image = NSImage(data: data).map { Image(nsImage: $0) }
            #else
            image = UIImage(data: data).map { Image(uiImage: $0) }
            #endif
        }
    }
}
