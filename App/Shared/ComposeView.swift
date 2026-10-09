import BlitzCore
import SwiftUI
import UniformTypeIdentifiers

/// The compose view when a message is being written, nothing otherwise. A view of its own so that typing, which
/// changes the message on every key, rebuilds only this and not the whole window behind it.
struct ComposeLayer: View {
    let model: AppModel
    /// Room left above it: the Mac's title bar. None on the phone.
    var top: CGFloat = 28

    var body: some View {
        if model.compose != nil {
            ComposeView(model: model).padding(.top, top)
        }
    }
}

struct ComposeView: View {
    @Bindable var model: AppModel
    @FocusState private var focus: Field?
    @State private var showCopies = false
    @State private var suggestionIndex = 0
    @State private var pickingFile = false

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
                Rectangle().fill(Theme.line).frame(height: 1)
                TextEditor(text: draft.body)
                    .font(.system(size: Theme.pt(15)))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .padding(.top, 10)
                    .padding(.leading, -5)
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
            .padding(.horizontal, 18)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .onAppear {
            guard let current = model.compose else { return }
            showCopies = !current.cc.isEmpty || !current.bcc.isEmpty
            focus = current.to.isEmpty ? .to : (current.subject.isEmpty ? .subject : .body)
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let copy = Self.keepCopy(of: url), !draft.wrappedValue.attachmentPaths.contains(copy) {
                    draft.wrappedValue.attachmentPaths.append(copy)
                }
            }
        }
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
