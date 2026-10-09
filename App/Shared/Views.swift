import BlitzCore
import SwiftUI

// MARK: - Rows

/// One line per conversation, for wide windows.
struct WideRow: View {
    let thread: MailThread
    let isCursor: Bool
    let isSelected: Bool
    let showSnooze: Bool
    var tag = ""
    /// The day the row was made for (see `AppModel.today`): its date reads differently once the day is over.
    var today = 0
    /// A reply to this conversation has been started and not sent.
    var hasDraft = false
    @AppStorage(AvatarStore.settingKey) private var avatars = true
    /// One number sizes the whole row: text, picture, spacing and height. Set by the slider in settings.
    @AppStorage(Theme.scaleKey) private var scale = Theme.defaultScale
    @State private var hovered = false

    var body: some View {
        let k = CGFloat(scale)
        #if DEBUG || BENCH
        let _ = BodyCount.bump("WideRow")
        #endif
        HStack(spacing: 0) {
            ZStack {
                if isSelected {
                    Image(systemName: "checkmark.square.fill").font(.system(size: Theme.pt(12) * k)).foregroundStyle(Theme.accent)
                } else if thread.unread {
                    Circle().fill(Theme.accent).frame(width: 7 * k, height: 7 * k)
                }
            }
            .frame(width: 34)
            if avatars {
                AvatarView(name: thread.avatarName, email: thread.avatarEmail, size: 26 * k).padding(.trailing, 12 * k)
            }
            (Text(thread.participants.joined(separator: ", ") + (thread.messageCount > 1 ? "  \(thread.messageCount)" : ""))
                .foregroundColor(thread.unread ? Theme.text : Theme.dim)
             + Text(hasDraft ? "  Draft" : "").foregroundColor(Theme.draft))
                .font(.system(size: 13 * k, weight: thread.unread ? .semibold : .regular))
                .lineLimit(1)
                .frame(width: 200 * k, alignment: .leading)
            (Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                .font(.system(size: Theme.pt(13) * k, weight: thread.unread ? .semibold : .regular))
                .foregroundColor(thread.unread ? Theme.text : Theme.dim)
             + Text("   " + thread.snippet).font(.system(size: Theme.pt(13) * k)).foregroundColor(Theme.faint))
                .lineLimit(1)
                .padding(.leading, 14 * k)
            Spacer(minLength: 12)
            if thread.starred {
                Image(systemName: "star.fill").font(.system(size: Theme.pt(10) * k)).foregroundStyle(Theme.accent).padding(.trailing, 8)
            }
            if thread.hasAttachments {
                Image(systemName: "paperclip").font(.system(size: Theme.pt(11) * k)).foregroundStyle(Theme.faint).padding(.trailing, 8)
            }
            if !tag.isEmpty {
                Text(tag).font(.system(size: Theme.pt(11) * k)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.trailing, 4)
            }
            Text(showSnooze ? Dates.snooze(Date(timeIntervalSince1970: Double(thread.snoozedUntil ?? thread.lastDate) / 1000)) : Dates.short(thread.date))
                .font(.system(size: Theme.pt(12) * k))
                .foregroundStyle(Theme.faint)
                .frame(minWidth: 64 * k, alignment: .trailing)
                .padding(.trailing, 20)
        }
        .frame(height: 38 * k)
        .background(isCursor ? Theme.selection : (hovered ? Theme.card : Color.clear))
        .onHover { hovered = $0 }
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .overlay(alignment: .leading) {
            if isCursor { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
    }
}

/// A row is drawn again only when what it shows has changed, not whenever the list around it is looked at again.
extension WideRow: Equatable {
    nonisolated static func == (a: WideRow, b: WideRow) -> Bool {
        a.isCursor == b.isCursor && a.isSelected == b.isSelected && a.showSnooze == b.showSnooze && a.tag == b.tag && a.today == b.today && a.thread == b.thread
    }
}

/// Three lines per conversation, for phones.
struct CompactRow: View, Equatable {
    let thread: MailThread
    let isSelected: Bool
    let showSnooze: Bool
    var tag = ""
    /// Bumped when the day changes, so that a date reading "a time today" is written again.
    var day = 0
    /// Whether senders' pictures are shown. Handed in by the list, which reads the setting once for every row:
    /// a row that read settings itself could never be told apart from the row it was a moment ago, and so was
    /// drawn again every time anything near it changed.
    var avatars = true
    /// A reply to this conversation has been started and not sent.
    var hasDraft = false
    /// How an unread conversation is marked. 1: a dot on the picture. 2: bold text and a coloured time, no dot.
    /// 3: a dot beside the time. 4: a coloured bar on the row's left edge. 0: the old dot in a gutter.
    var style = 1

    private var dot: some View { Circle().fill(Theme.accent).frame(width: 9, height: 9) }

    /// The row is drawn again only when one of these changes.
    nonisolated static func == (a: CompactRow, b: CompactRow) -> Bool {
        a.thread == b.thread && a.isSelected == b.isSelected && a.showSnooze == b.showSnooze && a.tag == b.tag && a.day == b.day
            && a.avatars == b.avatars && a.style == b.style && a.hasDraft == b.hasDraft
    }

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("CompactRow")
        #endif
        HStack(alignment: .top, spacing: 12) {
            if style == 0 || !avatars {
                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: Theme.pt(15))).foregroundStyle(Theme.accent)
                    } else if thread.unread {
                        dot
                    }
                }
                .frame(width: 12, height: Theme.pt(avatars ? 46 : 20))
                .padding(.trailing, -4)
            }
            if avatars {
                AvatarView(name: thread.avatarName, email: thread.avatarEmail, size: Theme.pt(46))
                    .equatable()
                    .overlay(alignment: .topLeading) {
                        if style == 1, thread.unread, !isSelected {
                            Circle().fill(Theme.accent).frame(width: 13, height: 13)
                                .overlay(Circle().stroke(Theme.background, lineWidth: 2.5))
                                .offset(x: -2, y: -2)
                        }
                    }
                    .overlay {
                        if isSelected, style != 0 {
                            Circle().fill(Theme.accent)
                            Image(systemName: "checkmark").font(.system(size: Theme.pt(18), weight: .bold)).foregroundStyle(Theme.background)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(thread.participants.joined(separator: ", "))
                        .font(.system(size: Theme.pt(16), weight: thread.unread ? (style == 2 ? .bold : .semibold) : .regular))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)").font(.system(size: Theme.pt(13))).foregroundStyle(Theme.faint)
                    }
                    if hasDraft {
                        Text("Draft").font(.system(size: Theme.pt(14), weight: .medium)).foregroundStyle(Theme.draft).fixedSize()
                    }
                    Spacer(minLength: 6)
                    if thread.starred { Image(systemName: "star.fill").font(.system(size: Theme.pt(10))).foregroundStyle(Theme.accent) }
                    if thread.hasAttachments { Image(systemName: "paperclip").font(.system(size: Theme.pt(11))).foregroundStyle(Theme.faint) }
                    if style == 3, thread.unread { dot }
                    Text(showSnooze ? Dates.snooze(Date(timeIntervalSince1970: Double(thread.snoozedUntil ?? thread.lastDate) / 1000)) : Dates.short(thread.date))
                        .font(.system(size: Theme.pt(13), weight: style == 2 && thread.unread ? .semibold : .regular))
                        .foregroundStyle(style == 2 && thread.unread ? Theme.accent : Theme.faint)
                }
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: Theme.pt(15), weight: thread.unread ? (style == 2 ? .semibold : .medium) : .regular))
                    .foregroundStyle(thread.unread ? Theme.text : Theme.dim)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(thread.snippet)
                        .font(.system(size: Theme.pt(14)))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !tag.isEmpty {
                        Text(tag).font(.system(size: Theme.pt(11))).foregroundStyle(Theme.faint)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, style == 0 || !avatars ? 8 : 16)
        .padding(.trailing, 14)
        .overlay(alignment: .leading) {
            if style == 4, thread.unread { RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 4).padding(.vertical, 8) }
        }
        .contentShape(Rectangle())
    }
}

struct EmptyListView: View {
    let model: AppModel

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("EmptyListView")
        #endif
        VStack(spacing: 6) {
            if model.searchActive {
                Text(model.searchText.isEmpty ? "Type to search all mail" : "No matches").foregroundStyle(Theme.faint)
            } else if model.account?.historyId == nil {
                Text("Downloading your mail…").foregroundStyle(Theme.faint)
            } else if model.list.isInbox {
                Text("Inbox Zero").font(.system(size: Theme.pt(22), weight: .semibold)).foregroundStyle(Theme.text)
                Text("Nothing left to do here.").foregroundStyle(Theme.faint)
            } else {
                Text("Nothing in \(model.list.title)").foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Switching lists

/// The way from one list to another (Inbox, Starred, Sent and so on). Three designs to choose between, picked by
/// the "switcherStyle" setting: 1 a dropdown under the title, 2 a drawer from the left with the accounts in it,
/// 3 a sheet of large tiles.
struct ListSwitcher: View {
    let model: AppModel
    @AppStorage("switcherStyle") private var style = 1

    private func choose(_ target: MailList) { model.go(target) }

    private func row(_ target: MailList, index: Int, large: Bool = false) -> some View {
        let selected = model.list == target
        return HStack(spacing: 12) {
            Image(systemName: selected ? target.icon + ".fill" : target.icon)
                .font(.system(size: large ? 17 : 14))
                .foregroundStyle(selected ? Theme.accent : Theme.dim)
                .frame(width: 24)
            Text(target.title).font(.system(size: large ? 17 : 14, weight: selected ? .semibold : .regular)).foregroundStyle(Theme.text)
            Spacer()
            if !model.compact, index < 9 {
                Text("\(index + 1)").font(.system(size: Theme.pt(11), design: .monospaced)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: large ? 48 : (model.compact ? 44 : 32))
        .background(selected ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { choose(target) }
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.allLists.enumerated()), id: \.element.id) { index, target in row(target, index: index) }
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(style == 1 ? 0.18 : 0.4).ignoresSafeArea().onTapGesture { model.overlay = nil }
            switch style {
            case 2: drawer
            case 3: sheet
            default: dropdown
            }
        }
    }

    /// 1: a small list that drops from the title.
    private var dropdown: some View {
        VStack {
            HStack {
                rows.padding(6)
                    .frame(width: model.compact ? 250 : 230)
                    .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, model.compact ? 52 : 26)
        .padding(.top, model.compact ? 52 : 66)
    }

    /// 2: a panel from the left edge holding the accounts and the lists together.
    private var drawer: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ACCOUNTS").font(.system(size: Theme.pt(11), weight: .semibold)).foregroundStyle(Theme.faint).padding(.horizontal, 14).padding(.top, model.compact ? 8 : 40).padding(.bottom, 4)
                if model.accounts.count > 1 { accountRow("All Inboxes", id: "") }
                ForEach(model.accounts) { account in accountRow(account.id, id: account.id) }
                Text("MAIL").font(.system(size: Theme.pt(11), weight: .semibold)).foregroundStyle(Theme.faint).padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 4)
                rows
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "gearshape").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.dim).frame(width: 24)
                    Text("Settings").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: Theme.pt(44))
                .contentShape(Rectangle())
                .onTapGesture { model.overlay = .accounts }
            }
            .padding(8)
            .frame(width: model.compact ? 300 : 270)
            .frame(maxHeight: .infinity)
            .background(Theme.overlay)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            Spacer(minLength: 0)
        }
    }

    private func accountRow(_ title: String, id: String) -> some View {
        let selected = model.accountId == id
        return HStack(spacing: 12) {
            Group {
                if id.isEmpty {
                    Image(systemName: "person.2.fill").font(.system(size: Theme.pt(11))).foregroundStyle(Theme.background)
                        .frame(width: 24, height: 24).background(Theme.accent, in: Circle())
                } else {
                    AvatarView(name: "", email: id, size: 24)
                }
            }
            Text(title).font(.system(size: Theme.pt(14), weight: selected ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            if let count = id.isEmpty ? nil : model.unread[id], count > 0 {
                Text("\(count)").font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: model.compact ? 44 : 34)
        .background(selected ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.switchAccount(id) }
    }

    /// 3: large tiles, in a sheet at the bottom of a phone or the middle of a window.
    private var sheet: some View {
        VStack {
            Spacer()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: model.compact ? 3 : 4), spacing: 10) {
                ForEach(Array(model.allLists.enumerated()), id: \.element.id) { index, target in
                    let selected = model.list == target
                    VStack(spacing: 8) {
                        Image(systemName: selected ? target.icon + ".fill" : target.icon).font(.system(size: Theme.pt(22))).foregroundStyle(selected ? Theme.accent : Theme.dim)
                        Text(target.title).font(.system(size: Theme.pt(13), weight: selected ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.pt(84))
                    .background(selected ? Theme.selection : Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                    .onTapGesture { choose(target) }
                }
            }
            .padding(14)
            .frame(maxWidth: 560)
            .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.line))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
            .padding(.horizontal, 10)
            .padding(.bottom, model.compact ? 8 : 0)
            if !model.compact { Spacer() }
        }
    }
}

/// The current list's name. Tapping it opens the switcher.
struct ListTitle: View {
    let model: AppModel
    @AppStorage("switcherStyle") private var style = 1
    @State private var hovered = false

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("ListTitle")
        #endif
        HStack(spacing: 6) {
            if style == 2, !model.compact {
                Image(systemName: "sidebar.left").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.dim)
            }
            Text(model.list.title).font(.system(size: model.compact ? 20 : 16, weight: .bold)).foregroundStyle(Theme.text)
            Image(systemName: "chevron.down").font(.system(size: model.compact ? 12 : 10, weight: .bold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 8)
        .frame(height: model.compact ? 40 : 30)
        .background(hovered ? Theme.chip : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .onTapGesture { model.overlay = .lists }
    }
}

/// The less common things to do with the open conversation. Shown at once, with none of the system menu's animation.
struct MoreView: View {
    let model: AppModel

    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: Theme.pt(15))).foregroundStyle(Theme.dim).frame(width: 22)
            Text(title).font(.system(size: Theme.pt(16))).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.pt(48))
        .contentShape(Rectangle())
        .onTapGesture {
            model.overlay = nil
            action()
        }
    }

    var body: some View {
        OverlayCard(width: 360) {
            VStack(spacing: 0) {
                row(model.openThread?.unread == true ? "Mark Read" : "Mark Unread", "envelope.badge") { model.toggleRead() }
                row("Move to Inbox", "tray.and.arrow.down") { model.moveToInbox() }
                row("Mark as Spam", "exclamationmark.octagon") { model.markSpam() }
                row("Forward", "arrowshape.turn.up.right") { model.startForward() }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Sliding conversation

/// Holds the open conversation and moves it with a back swipe.
///
/// Only this small view watches the swipe distance. If the screen around it did, the whole list would be rebuilt
/// on every frame of the swipe, and the slide would stutter instead of running at the display's full rate.
struct ThreadSlide<Content: View>: View {
    let model: AppModel
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("ThreadSlide")
        let _ = ThreadBench.count("ThreadSlide")
        #endif
        content
            // Always in the window and never hidden, only parked past the right edge: a web view that is hidden
            // stops painting, and then a conversation would not appear the moment it is opened.
            .offset(x: model.openThread == nil ? width + 20 : model.backDrag)
            // Only letting go of a back swipe animates. Opening, and closing with a key or the arrow, are instant.
            .transaction { transaction in
                transaction.animation = model.sliding ? .easeOut(duration: AppModel.slide) : nil
                transaction.disablesAnimations = !model.sliding
            }
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast
    let undoHint: String

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("ToastView")
        #endif
        HStack(spacing: 12) {
            Text(toast.text).font(.system(size: Theme.pt(13))).foregroundStyle(Theme.text).lineLimit(2)
            if let undo = toast.undo {
                Button(action: undo) {
                    Text(undoHint).font(.system(size: Theme.pt(13), weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

// MARK: - Overlays

/// One person's picture up close, with their name and address.
struct ProfileView: View {
    let model: AppModel
    @State private var large: Image?
    @State private var copied = false
    @State private var full: URL?

    /// Opens the whole, uncropped picture in the system's viewer, where it can be pinched and zoomed.
    private func enlarge(_ email: String, name: String) {
        if let full {
            model.previewFile = full
            return
        }
        Task {
            var data = await AvatarStore.shared.sharp(for: email, side: 1600)
            if data == nil { data = await AvatarStore.shared.data(for: email) }
            guard let data else { return }
            let kind = data.starts(with: [0x89, 0x50]) ? "png" : "jpg"
            let safe = (name.isEmpty ? email : name).filter { $0.isLetter || $0.isNumber || $0 == " " }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pictures", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent((safe.isEmpty ? "Picture" : safe) + "." + kind)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
            full = file
            model.previewFile = file
        }
    }

    var body: some View {
        let person = model.profile
        let email = person?.email ?? ""
        OverlayCard(width: 320) {
            VStack(spacing: 6) {
                ZStack {
                    AvatarView(name: person?.name ?? "", email: email, size: 200)
                    if let large {
                        large.resizable().interpolation(.high).scaledToFill().background(Color.white)
                            .frame(width: 200, height: 200).clipShape(Circle())
                    }
                }
                .padding(.top, 26)
                .padding(.bottom, 12)
                .contentShape(Circle())
                .onTapGesture { enlarge(email, name: person?.name ?? "") }
                if let name = person?.name, !name.isEmpty {
                    Text(name).font(.system(size: Theme.pt(18), weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.center)
                }
                Text(copied ? "Copied" : email).font(.system(size: Theme.pt(14))).foregroundStyle(copied ? Theme.accent : Theme.dim).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(email, forType: .string)
                        #else
                        UIPasteboard.general.string = email
                        #endif
                        copied = true
                    }
                Text("Tap the picture to enlarge it, the address to copy it").font(.system(size: Theme.pt(11))).foregroundStyle(Theme.faint).padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
        }
        .task(id: email) {
            full = nil
            large = nil
            guard AvatarStore.enabled, let data = await AvatarStore.shared.sharp(for: email) else { return }
            #if os(macOS)
            large = NSImage(data: data).map { Image(nsImage: $0) }
            #else
            large = UIImage(data: data).map { Image(uiImage: $0) }
            #endif
        }
    }
}

struct OverlayCard<Content: View>: View {
    var width: CGFloat = 520
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: width)
            .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
            .padding(.horizontal, 16)
    }
}

struct PaletteView: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        OverlayCard {
            VStack(spacing: 0) {
                TextField("Type a command", text: $model.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.pt(17)))
                    .focused($focused)
                    .padding(14)
                    .onSubmit { model.runPaletteSelection() }
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    #endif
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.paletteCommands.enumerated()), id: \.element.id) { index, command in
                                HStack {
                                    Text(command.title).font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(command.keys).font(.system(size: Theme.pt(12), design: .monospaced)).foregroundStyle(Theme.faint)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: Theme.pt(34))
                                .background(index == model.paletteIndex ? Theme.selection : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { model.run(command) }
                                .id(command.id)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 340)
                    .onChange(of: model.paletteIndex) { _, index in
                        let commands = model.paletteCommands
                        if commands.indices.contains(index) { proxy.scrollTo(commands[index].id) }
                    }
                }
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.paletteQuery) { _, _ in model.paletteIndex = 0 }
    }
}

struct SnoozeView: View {
    let model: AppModel

    var body: some View {
        OverlayCard(width: 360) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Snooze until").font(.system(size: Theme.pt(12), weight: .semibold)).foregroundStyle(Theme.faint).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                ForEach(Array(SnoozeOption.standard().enumerated()), id: \.element.id) { index, option in
                    HStack {
                        Text("\(index + 1)").font(.system(size: Theme.pt(12), design: .monospaced)).foregroundStyle(Theme.faint).frame(width: 18, alignment: .leading)
                        Text(option.title).font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text)
                        Spacer()
                        Text(Dates.snooze(option.date)).font(.system(size: Theme.pt(13))).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Theme.pt(38))
                    .contentShape(Rectangle())
                    .onTapGesture { model.snooze(until: option.date) }
                }
                Spacer().frame(height: 8)
            }
        }
    }
}

struct HelpView: View {
    private let rows: [(String, String)] = [
        ("J / K", "Next / previous"), ("O or Enter", "Open"), ("U or Esc", "Back to the list"), ("Two-finger swipe right", "Back to the list"),
        ("E", "Archive (Mark Done)"), ("B", "Snooze"), ("S", "Star"), ("⇧I / ⇧U", "Mark read / unread"), ("#", "Trash"), ("!", "Spam"),
        ("R / A / F", "Reply / reply all / forward"), ("C", "Compose"), ("⌘ Enter", "Send"),
        ("/", "Search"), ("⌘ K", "Command bar"), ("Z", "Undo"), ("X", "Select"), ("⌘ A", "Select all"),
        ("1 to 9", "Go to a list, in the order along the top"), ("G then I S T D A", "Go to Inbox, Starred, Sent, Drafts, All Mail"), ("⌃ 1 2 3", "Switch account"),
        ("Space / N / P", "Scroll the conversation"), ("O", "Expand all messages"),
    ]

    var body: some View {
        OverlayCard(width: 460) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Keyboard shortcuts").font(.system(size: Theme.pt(15), weight: .semibold)).foregroundStyle(Theme.text).padding(14)
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.1).font(.system(size: Theme.pt(13))).foregroundStyle(Theme.dim)
                        Spacer()
                        Text(row.0).font(.system(size: Theme.pt(12), design: .monospaced)).foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Theme.pt(24))
                }
                Spacer().frame(height: 12)
            }
        }
    }
}

struct AccountsView: View {
    let model: AppModel
    @AppStorage(AvatarStore.settingKey) private var avatars = true
    @AppStorage(MailList.splitKey) private var split = false
    @AppStorage(Theme.scaleKey) private var scale = Theme.defaultScale
    @AppStorage(SwipeAction.leftKey) private var swipeLeft = SwipeAction.defaultLeft
    @AppStorage(SwipeAction.rightKey) private var swipeRight = SwipeAction.defaultRight

    private func swipeRow(_ title: String, value: Binding<SwipeAction>) -> some View {
        HStack {
            Text(title).font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text)
            Spacer()
            Image(systemName: value.wrappedValue.icon).font(.system(size: Theme.pt(12))).foregroundStyle(Theme.accent)
            Text(value.wrappedValue.title).font(.system(size: Theme.pt(13), weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.pt(44))
        .contentShape(Rectangle())
        .onTapGesture { value.wrappedValue = value.wrappedValue.next }
    }

    var body: some View {
        OverlayCard(width: 420) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Accounts and settings").font(.system(size: Theme.pt(15), weight: .semibold)).foregroundStyle(Theme.text).padding(14)
                if model.accounts.count > 1 {
                    HStack {
                        Text("All Inboxes").font(.system(size: Theme.pt(14), weight: model.isAll ? .semibold : .regular)).foregroundStyle(Theme.text)
                        Spacer()
                        Text("⌃0").font(.system(size: Theme.pt(11), design: .monospaced)).foregroundStyle(Theme.faint).opacity(model.compact ? 0 : 1)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Theme.pt(44))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.overlay = nil
                        model.switchAccount("")
                    }
                }
                ForEach(model.accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.id).font(.system(size: Theme.pt(14), weight: account.id == model.accountId ? .semibold : .regular)).foregroundStyle(Theme.text)
                            if let count = model.unread[account.id], count > 0 {
                                Text("\(count) unread").font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
                            }
                        }
                        Spacer()
                        Button("Sign out") { model.signOut(account.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: Theme.pt(12)))
                            .foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Theme.pt(44))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.overlay = nil
                        model.switchAccount(account.id)
                    }
                }
                Button(action: { model.signIn() }) {
                    Text(model.signingIn ? "Waiting for Google…" : "Add a Gmail account")
                        .font(.system(size: Theme.pt(14), weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Profile pictures").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text)
                        Text("People's pictures and company logos, in lists, conversations and notifications.")
                            .font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    Text(avatars ? "On" : "Off").font(.system(size: Theme.pt(13), weight: .semibold)).foregroundStyle(avatars ? Theme.accent : Theme.faint)
                }
                .padding(14)
                .contentShape(Rectangle())
                .onTapGesture { model.setAvatars(!avatars) }
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Split inbox").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text)
                        Text("Off: one inbox with everything. On: people in Inbox; promotions, updates and the like in Other.")
                            .font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    Text(split ? "On" : "Off").font(.system(size: Theme.pt(13), weight: .semibold)).foregroundStyle(split ? Theme.accent : Theme.faint)
                }
                .padding(14)
                .contentShape(Rectangle())
                .onTapGesture { model.setSplit(!split) }
                if !model.compact {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Size").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(Int((scale * 100).rounded()))%").font(.system(size: Theme.pt(13), weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        Slider(value: $scale, in: 0.85...1.7)
                            .onChange(of: scale) { _, _ in model.scaleChanged() }
                        Text("Makes the list rows and the open email bigger or smaller.").font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
                    }
                    .padding(14)
                }
                if model.compact {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Text size").font(.system(size: Theme.pt(14))).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(Int((TextSize.shared.value * 100).rounded()))%").font(.system(size: Theme.pt(13), weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        Slider(value: Binding(get: { TextSize.shared.value }, set: { TextSize.shared.value = ($0 * 20).rounded() / 20 }), in: 0.9...1.5)
                            .onChange(of: TextSize.shared.value) { _, _ in model.scaleChanged() }
                        Text("Makes all the text in the app and the open email bigger or smaller.").font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
                    }
                    .padding(14)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    swipeRow("Swipe left", value: $swipeLeft)
                    swipeRow("Swipe right", value: $swipeRight)
                    Text("Tap to change. A swipe acts at once, with no second tap.")
                        .font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
        }
    }
}

struct OverlayLayer: View {
    @Bindable var model: AppModel

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("OverlayLayer")
        #endif
        if model.overlay == .lists {
            ListSwitcher(model: model)
        } else if let overlay = model.overlay {
            ZStack(alignment: .top) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { model.overlay = nil }
                Group {
                    switch overlay {
                    case .palette: PaletteView(model: model)
                    case .snooze: SnoozeView(model: model)
                    case .help: HelpView()
                    case .accounts: AccountsView(model: model)
                    case .more: MoreView(model: model)
                    case .profile: ProfileView(model: model)
                    case .lists: EmptyView()
                    }
                }
                .padding(.top, 90)
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let model: AppModel
    let hasClient: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Mach").font(.system(size: Theme.pt(34), weight: .bold)).foregroundStyle(Theme.text)
            Text("Fast, free, open-source mail for Gmail.").font(.system(size: Theme.pt(15))).foregroundStyle(Theme.dim)
            if hasClient {
                Button(action: { model.signIn() }) {
                    Text(model.signingIn ? "Waiting for Google…" : "Sign in with Google")
                        .font(.system(size: Theme.pt(15), weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            } else {
                Text("This build has no Google sign-in key. Add OAuthClient.json as the README describes, then build again.")
                    .font(.system(size: Theme.pt(13)))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
