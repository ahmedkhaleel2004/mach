#if DEBUG || BENCH
import BlitzCore
import SwiftUI
import UIKit

/// Where a row's cost goes, and what other ways of building the list would cost. Compiled out of the app people use.
///
/// Each "variant" is a list of the same conversations built a different way: the real row, the real row with one
/// piece left out, one piece by itself, or the real row inside another kind of list. Every variant is put in a
/// window of its own over the app, flung through a few hundred rows, and thrown away; the variants take turns, so
/// they are measured in the same minute by the same process. `BLITZ_LIST_LAB` picks variants (default: all).
@MainActor
enum ListLab {
    static let height: CGFloat = 78 + 1.0 / 3

    static let variants: [(name: String, list: (AppModel, [MailThread]) -> AnyView)] = [
        ("empty", { _, rows in lazy(rows) { _ in Color.clear.frame(height: height) } }),
        ("sender", { _, rows in lazy(rows) { thread in
            Text(thread.participants.joined(separator: ", ")).font(.system(size: 16)).foregroundStyle(Theme.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
        } }),
        ("threeTexts", { _, rows in lazy(rows) { thread in
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.participants.joined(separator: ", ")).font(.system(size: 16)).foregroundStyle(Theme.text).lineLimit(1)
                Text(thread.subject).font(.system(size: 15)).foregroundStyle(Theme.dim).lineLimit(1)
                Text(thread.snippet).font(.system(size: 14)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
        } }),
        ("initials", { _, rows in lazy(rows) { thread in
            HStack {
                ZStack {
                    Circle().fill(Color(light: AvatarStore.colorHex(for: thread.avatarEmail), dark: AvatarStore.colorHex(for: thread.avatarEmail)))
                    Text(AvatarStore.initials(thread.avatarName)).font(.system(size: 46 * 0.38, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                Spacer()
            }
            .frame(height: height)
        } }),
        ("avatar", { _, rows in lazy(rows) { thread in
            HStack {
                AvatarView(name: thread.avatarName, email: thread.avatarEmail, size: 46)
                Spacer()
            }
            .frame(height: height)
        } }),
        ("compact", { model, rows in lazy(rows) { thread in
            CompactRow(thread: thread, isSelected: false, showSnooze: false, tag: model.tag(for: thread.accountId))
        } }),
        ("compactDressed", { model, rows in lazy(rows) { thread in
            CompactRow(thread: thread, isSelected: false, showSnooze: false, tag: model.tag(for: thread.accountId))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 14) }
        } }),
        // The real row's wrapping, put on one piece at a time: each step's cost over the one before is that piece's.
        ("step1Stack", { model, rows in lazy(rows) { thread in
            ZStack {
                CompactRow(thread: thread, isSelected: false, showSnooze: false, tag: model.tag(for: thread.accountId))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background)
                    .offset(x: 0)
                    .opacity(1)
                    .scaleEffect(1)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 14) }
        } }),
        ("step2Clip", { model, rows in lazy(rows) { thread in
            ZStack {
                CompactRow(thread: thread, isSelected: false, showSnooze: false, tag: model.tag(for: thread.accountId))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background)
                    .offset(x: 0)
                    .opacity(1)
                    .scaleEffect(1)
            }
            .frame(height: nil, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 14) }
        } }),
        ("step3Tap", { model, rows in lazy(rows) { thread in
            ZStack {
                CompactRow(thread: thread, isSelected: false, showSnooze: false, tag: model.tag(for: thread.accountId))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background)
                    .offset(x: 0)
                    .opacity(1)
                    .scaleEffect(1)
            }
            .frame(height: nil, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 14) }
            .contentShape(Rectangle())
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .onTapGesture {}
        } }),
        ("step4Geometry", { model, rows in lazy(rows) { thread in
            ZStack {
                CompactRow(thread: thread, isSelected: false, showSnooze: false, tag: model.tag(for: thread.accountId))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background)
                    .offset(x: 0)
                    .opacity(1)
                    .scaleEffect(1)
            }
            .frame(height: nil, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 14) }
            .contentShape(Rectangle())
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .onTapGesture {}
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("rows")) } action: { _ in }
            .onDisappear {}
        } }),
        ("swipe", { model, rows in lazy(rows) { thread in SwipeRow(model: model, thread: thread, swipe: RowSwipe.shared) } }),
        ("swipeInList", { model, rows in
            AnyView(List {
                ForEach(rows) { thread in
                    SwipeRow(model: model, thread: thread, swipe: RowSwipe.shared)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1))
        }),
        ("swipeInCollection", { model, rows in AnyView(LabCollection(rows: rows) { thread in SwipeRow(model: model, thread: thread, swipe: RowSwipe.shared) }.ignoresSafeArea(edges: .bottom)) }),
    ]

    private static func lazy<Row: View>(_ rows: [MailThread], @ViewBuilder row: @escaping (MailThread) -> Row) -> AnyView {
        AnyView(ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { thread in row(thread) }
            }
            .coordinateSpace(.named("rows"))
            .padding(.bottom, 90)
        })
    }

    static func run() async {
        guard let model = ListBench.shared, let scene = ListBench.window?.windowScene else { return }
        let environment = ProcessInfo.processInfo.environment
        let wanted = (environment["BLITZ_LIST_LAB"] ?? "").split(separator: ",").map(String.init)
        let chosen = variants.filter { wanted.isEmpty || wanted.contains($0.name) }
        let rounds = Int(environment["BLITZ_LIST_ROUNDS"].flatMap(Double.init) ?? 3)
        let rows = Array(model.rows.filter { !$0.id.hasPrefix("draft:") }.prefix(600))
        let count = min(400, Double(rows.count) - 20)
        guard count > 50 else { return }
        for round in 0 ..< rounds {
            for variant in chosen {
                let window = UIWindow(windowScene: scene)
                let host = UIHostingController(rootView: variant.list(model, rows).background(Theme.background).transaction { $0.animation = nil })
                window.rootViewController = host
                window.windowLevel = .normal + 1
                window.isHidden = false
                await ListBench.frames(12)
                guard let list = ListBench.scroll(in: window) else {
                    Bench.record("lab.error", ms: 0, ["variant": variant.name])
                    window.isHidden = true
                    continue
                }
                let rowHeight = max(1, (list.contentSize.height - 90) / CGFloat(rows.count))
                for pass in ["down1", "up1", "down2"] {
                    var fields = await ListBench.fling(list, by: pass.hasPrefix("down") ? 120 : -120, rows: count, rowHeight: rowHeight)
                    fields["round"] = round
                    fields["rowHeight"] = Double(rowHeight)
                    let visible = max(1, Double(list.bounds.height / rowHeight))
                    fields["layersPerRowOnScreen"] = (Double(ListBench.layers(under: list.layer)) / visible * 10).rounded() / 10
                    fields["viewsPerRowOnScreen"] = (Double(ListBench.views(under: list)) / visible * 10).rounded() / 10
                    Bench.record("lab.\(variant.name).\(pass)", ms: fields["cpuPerRow"] as? Double ?? 0, fields)
                    await ListBench.frames(4)
                }
                window.isHidden = true
                window.rootViewController = nil
                await ListBench.frames(6)
            }
        }
    }
}

/// The same SwiftUI rows inside a UIKit collection view, which reuses cells instead of making rows afresh.
struct LabCollection<Row: View>: UIViewRepresentable {
    let rows: [MailThread]
    @ViewBuilder let row: (MailThread) -> Row

    func makeCoordinator() -> Coordinator { Coordinator(rows: rows, row: row) }

    func makeUIView(context: Context) -> UICollectionView {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        view.backgroundColor = .clear
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
        view.dataSource = context.coordinator
        view.contentInset.bottom = 90
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {}

    final class Coordinator: NSObject, UICollectionViewDataSource {
        let rows: [MailThread]
        let row: (MailThread) -> Row

        init(rows: [MailThread], row: @escaping (MailThread) -> Row) {
            self.rows = rows
            self.row = row
        }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

        func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "row", for: path)
            let thread = rows[path.item]
            cell.contentConfiguration = UIHostingConfiguration { row(thread) }.margins(.all, 0)
            return cell
        }
    }
}
#endif
