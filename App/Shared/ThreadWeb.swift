import MachCore
import CryptoKit
import QuickLookThumbnailing
import SwiftUI
import WebKit

/// Where the conversation on the page ends, for the reply written under it. Only the reply's own view watches this.
@MainActor
@Observable
final class ReplyPlace {
    /// How far down the page the last message ends, in points. Nil until the page has said.
    var end: CGFloat?
    /// The width of the page's scroll bar, on a Mac set to always show one.
    var gutter: CGFloat = 0
}

/// The single web view that shows whichever thread is open.
///
/// It is created once at launch and kept warm, so opening a thread is one script call instead of a page load.
@MainActor
final class ThreadWeb: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    enum Event {
        case link(URL)
        case file(messageId: String, index: Int)
        case sendDraft(messageId: String)
        case editDraft(messageId: String)
        case discardDraft(messageId: String)
        case face(messageId: String)
    }

    let webView: WKWebView
    var onEvent: ((Event) -> Void)?
    /// The page was thrown away and loaded again; whoever shows a thread should draw it again.
    var onReload: (() -> Void)?
    private var reloading = false
    #if os(iOS)
    /// A rightward drag across the conversation: how far it has gone, and when it ends, how fast it was moving.
    var onBackDrag: ((_ distance: CGFloat, _ endVelocity: CGFloat?) -> Void)?
    private var backPan: BackPan?
    /// Keeps the screen at its top rate while the conversation scrolls.
    private var moving: NSKeyValueObservation?
    #endif
    private var ready = false
    private var pendingScript: String?
    private var loaded = false
    /// True when the page has been handed everything asked of it so far (nothing is waiting for it to load).
    var caughtUp: Bool { ready && pendingScript == nil && waiting == nil }
    /// True from handing the page a conversation until it has drawn it.
    private var drawing = false
    /// The newest conversation asked for while the page was busy with another.
    private var waiting: String?
    #if DEBUG || BENCH
    private let created = Bench.now()
    #endif

    init(service: MailService) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(InlineImageHandler(service: service), forURLScheme: "mach-cid")
        configuration.setURLSchemeHandler(AvatarHandler(), forURLScheme: "mach-avatar")
        configuration.setURLSchemeHandler(AttachmentPreviewHandler(service: service), forURLScheme: "mach-att")
        configuration.suppressesIncrementalRendering = false
        #if os(iOS)
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = true
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "mach")
        webView.navigationDelegate = self
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        #else
        webView.isOpaque = false
        webView.backgroundColor = Theme.platformBackground
        webView.scrollView.backgroundColor = Theme.platformBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.keyboardDismissMode = .onDrag
        moving = FullRate.follow(webView.scrollView)
        let pan = BackPan { [weak self] distance, velocity in self?.onBackDrag?(distance, velocity) }
        webView.addGestureRecognizer(pan.recognizer)
        backPan = pan
        #endif
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        loadPage()
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    #if DEBUG
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { NSLog("thread view failed: %@", String(describing: error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { NSLog("thread view failed early: %@", String(describing: error)) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { NSLog("thread view loaded, ready: %d", ready ? 1 : 0) }
    #endif

    /// Loads the page that shows conversations.
    ///
    /// With `MACH_OFFLINE=1` the web view is first forbidden every request to the network, so mail opened by a test
    /// or a benchmark cannot fetch its remote pictures and tracking pixels. Only the app's own `mach-cid` and
    /// `mach-avatar` addresses still load. If that rule cannot be put in place the page is not loaded at all.
    private func loadPage() {
        guard let url = Bundle.main.url(forResource: "thread", withExtension: "html"), var html = try? String(contentsOf: url, encoding: .utf8) else { return }
        html = html.replacingOccurrences(of: "__NONCE__", with: UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        guard Bootstrap.offline, !networkBlocked else {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mach-offline", encodedContentRuleList: rules) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self, let list else { return }
                self.webView.configuration.userContentController.add(list)
                self.networkBlocked = true
                self.webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }
    private var networkBlocked = false

    let replyPlace = ReplyPlace()
    /// The room the page is keeping clear below its last message, in points. Nil when no reply is being written.
    private var reserved: CGFloat?

    /// Keeps room clear at the foot of the conversation for the reply being written there (the editor is drawn
    /// over it), or gives it back with nil. The page answers with where its last message ends.
    func reserveReply(_ height: CGFloat?) {
        guard height != reserved else { return }
        if height == nil || reserved == nil { replyPlace.end = nil }
        reserved = height
        act("window.mach.reply(\(Double(height ?? 0) / webView.pageZoom))")
    }

    private func run(_ script: String) {
        guard ready else {
            pendingScript = script
            return
        }
        webView.evaluateJavaScript(script) { _, error in
            #if DEBUG
            if let error { NSLog("thread view script failed: %@", String(describing: error)) }
            #endif
        }
    }

    func render(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        #if os(iOS)
        // A page still gliding from a flick (archive pressed mid-scroll) carries on gliding over the next
        // conversation, and undoes the page's own move to its top. Setting the place it is at stops the glide.
        if payload["keepScroll"] as? Bool != true {
            webView.scrollView.setContentOffset(webView.scrollView.contentOffset, animated: false)
        }
        #endif
        #if DEBUG || BENCH
        ThreadBench.lap("json")
        #endif
        // U+2028 and U+2029 are legal in JSON but end a line in JavaScript source. Hardly any mail has one, and looking
        // for their bytes (E2 80 A8 and E2 80 A9) is far quicker than rewriting a megabyte of text that has none.
        let separators = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var index = 0
            while index + 2 < bytes.count {
                if bytes[index] == 0xE2, bytes[index + 1] == 0x80, bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 { return true }
                index += 1
            }
            return false
        }
        let safe = separators ? json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029") : json
        var script = "window.mach.render(\(safe))"
        #if DEBUG || BENCH
        ThreadBench.lap("escape")
        // A measured render carries an id, and the page reports its timings back under it.
        if let id = ThreadBench.renderId(bytes: data.count) { script = "window.mach.render(\(safe), \(id))" }
        defer { ThreadBench.lap("eval") }
        #endif
        guard ready else {
            pendingScript = script
            return
        }
        // While the page is still drawing one conversation, only the newest one asked for is kept: with j held down
        // the ones in between would be drawn for nobody.
        if drawing {
            waiting = script
        } else {
            draw(script)
        }
    }

    private func draw(_ script: String) {
        drawing = true
        webView.evaluateJavaScript(script) { [weak self] _, error in
            #if DEBUG
            if let error { NSLog("thread view script failed: %@", String(describing: error)) }
            #endif
            guard let self else { return }
            self.drawing = false
            if let next = self.waiting {
                self.waiting = nil
                self.draw(next)
            }
        }
    }

    func clear() {
        waiting = nil
        run("window.mach.clear()")
    }

    /// Draws a vector logo into an ordinary square picture, using the page that is already loaded.
    @MainActor
    func drawLogo(_ svg: Data) async -> Data? {
        // Anything started before the page has loaded is thrown away when it does.
        for _ in 0..<100 where !ready { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard ready else { return nil }
        let script = """
        return await new Promise(function (done) {
          var image = new Image();
          image.onload = function () {
            var canvas = document.createElement("canvas");
            canvas.width = 256; canvas.height = 256;
            var context = canvas.getContext("2d");
            context.fillStyle = "#fff"; context.fillRect(0, 0, 256, 256);
            var w = image.naturalWidth || 256, h = image.naturalHeight || 256, k = Math.min(256 / w, 256 / h) * (w === h ? 1 : 0.84);
            try { context.drawImage(image, (256 - w * k) / 2, (256 - h * k) / 2, w * k, h * k); done(canvas.toDataURL("image/png")); } catch (error) { done(""); }
          };
          image.onerror = function () { done(""); };
          image.src = "data:image/svg+xml;base64," + svg;
          setTimeout(function () { done(""); }, 4000);
        });
        """
        guard let result = try? await webView.callAsyncJavaScript(script, arguments: ["svg": svg.base64EncodedString()], contentWorld: .page) as? String,
              let comma = result.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(result[result.index(after: comma)...]))
    }

    /// Enlarges or shrinks everything in the conversation, text and pictures alike.
    func setZoom(_ scale: Double) {
        webView.pageZoom = scale
    }

    func scroll(pages: Double) { act("window.mach.scroll(\(pages))") }

    func expandAll() { act("window.mach.expandAll()") }

    /// Something done to the conversation on the page. If that conversation is still waiting its turn, this waits with it.
    private func act(_ script: String) {
        guard ready else { return }
        if waiting != nil {
            waiting? += ";" + script
        } else {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // WebKit always delivers a page's messages on the main thread, which is where this whole class lives.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let url = (body["url"] as? String).flatMap(URL.init(string:))
        let messageId = body["message"] as? String
        let index = body["index"] as? Int
        #if DEBUG || BENCH
        if type == "bench" { ThreadBench.page(body, at: Bench.now()) }
        #endif
        #if DEBUG
        if type == "ready" || type == "error" { NSLog("thread view says: %@", String(describing: body)) }
        #endif
        switch type {
        case "ready":
            ready = true
            #if DEBUG || BENCH
            Bench.once("thread_web_ready")
            Bench.record("thread_web_warmup", ms: Bench.now() - created)
            #endif
            if reloading {
                reloading = false
                pendingScript = nil
                onReload?()
                // The new page knows nothing of the room it was keeping for a reply.
                if let reserved { act("window.mach.reply(\(Double(reserved) / webView.pageZoom))") }
            } else if let script = pendingScript {
                pendingScript = nil
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        case "end":
            if reserved != nil, let y = body["y"] as? Double, let width = body["width"] as? Double {
                let end = CGFloat(y * webView.pageZoom), gutter = max(0, webView.bounds.width - CGFloat(width * webView.pageZoom)).rounded()
                if replyPlace.end != end { replyPlace.end = end }
                if replyPlace.gutter != gutter { replyPlace.gutter = gutter }
            }
        case "link":
            if let url, ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") { onEvent?(.link(url)) }
        case "file":
            if let messageId, let index { onEvent?(.file(messageId: messageId, index: index)) }
        case "face":
            if let messageId { onEvent?(.face(messageId: messageId)) }
        case "draft-send":
            if let messageId { onEvent?(.sendDraft(messageId: messageId)) }
        case "draft-edit":
            if let messageId { onEvent?(.editDraft(messageId: messageId)) }
        case "draft-discard":
            if let messageId { onEvent?(.discardDraft(messageId: messageId)) }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Only our own page ever loads here. Anything an email tries to navigate to opens outside instead.
        if !loaded, navigationAction.navigationType == .other {
            loaded = true
            return .allow
        }
        if navigationAction.targetFrame?.isMainFrame == false, navigationAction.navigationType == .other {
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
            onEvent?(.link(url))
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The system reclaimed the page. Load it again so the next thread still opens.
        ready = false
        loaded = false
        reloading = true
        drawing = false
        waiting = nil
        loadPage()
    }
}

/// Serves images that are embedded in an email (`cid:` references) from the message's attachments.
final class InlineImageHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let service: MailService
    private let lock = NSLock()
    private var active = Set<ObjectIdentifier>()

    init(service: MailService) {
        self.service = service
    }

    static func url(messageId: String, contentId: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return "mach-cid://m\(messageId)/\(contentId.addingPercentEncoding(withAllowedCharacters: allowed) ?? contentId)"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        #if DEBUG || BENCH
        MainActor.assumeIsolated { ThreadBench.count("cid_requests") }
        #endif
        let key = ObjectIdentifier(urlSchemeTask)
        lock.withLock { _ = active.insert(key) }
        guard let url = urlSchemeTask.request.url, let host = url.host, host.count > 1 else {
            finish(urlSchemeTask, key: key, data: nil, mime: "")
            return
        }
        let messageId = String(host.dropFirst())
        let contentId = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
        let service = self.service
        Task.detached(priority: .userInitiated) {
            let (data, mime) = await Self.load(service: service, messageId: messageId, contentId: contentId)
            await MainActor.run { self.finish(urlSchemeTask, key: key, data: data, mime: mime) }
        }
    }

    private static func load(service: MailService, messageId: String, contentId: String) async -> (Data?, String) {
        for account in (try? service.store.accounts()) ?? [] {
            guard let message = try? service.store.message(account: account.id, id: messageId),
                  let attachment = message.attachments.first(where: { $0.contentId == contentId }) else { continue }
            let data = try? await AttachmentCache.data(service: service, account: account.id, messageId: messageId, attachment: attachment)
            return (data, attachment.mimeType)
        }
        return (nil, "application/octet-stream")
    }

    private func finish(_ task: any WKURLSchemeTask, key: ObjectIdentifier, data: Data?, mime: String) {
        // WebKit raises an exception if a task is answered after it was stopped.
        guard lock.withLock({ active.remove(key) != nil }), let url = task.request.url else { return }
        guard let data else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.withLock { _ = active.remove(ObjectIdentifier(urlSchemeTask)) }
    }
}

/// Serves sender pictures to the thread view from the same cache the lists use.
final class AvatarHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var active = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        #if DEBUG || BENCH
        MainActor.assumeIsolated { ThreadBench.count("avatar_requests") }
        #endif
        let key = ObjectIdentifier(urlSchemeTask)
        lock.withLock { _ = active.insert(key) }
        let email = urlSchemeTask.request.url.map { String($0.path.dropFirst()) }?.removingPercentEncoding ?? ""
        Task.detached(priority: .userInitiated) {
            let data = AvatarStore.enabled ? await AvatarStore.shared.data(for: email) : nil
            await MainActor.run {
                guard self.lock.withLock({ self.active.remove(key) != nil }), let url = urlSchemeTask.request.url else { return }
                guard let data else {
                    urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
                    return
                }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.withLock { _ = active.remove(ObjectIdentifier(urlSchemeTask)) }
    }
}

/// Serves a small picture of an attachment (the image itself, the first page of a PDF, a document's icon)
/// so files can be seen in the conversation before they are opened.
final class AttachmentPreviewHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let service: MailService
    private let lock = NSLock()
    private var active = Set<ObjectIdentifier>()

    init(service: MailService) {
        self.service = service
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        lock.withLock { _ = active.insert(key) }
        let url = urlSchemeTask.request.url
        let messageId = String((url?.host ?? "").dropFirst())
        let index = Int(url?.lastPathComponent ?? "") ?? -1
        let service = self.service
        Task.detached(priority: .userInitiated) {
            let data = await Self.preview(service: service, messageId: messageId, index: index)
            await MainActor.run {
                guard self.lock.withLock({ self.active.remove(key) != nil }), let url else { return }
                guard let data else {
                    urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
                    return
                }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.withLock { _ = active.remove(ObjectIdentifier(urlSchemeTask)) }
    }

    private static func preview(service: MailService, messageId: String, index: Int) async -> Data? {
        for account in (try? service.store.accounts()) ?? [] {
            guard let message = try? service.store.message(account: account.id, id: messageId) else { continue }
            let files = message.attachments.filter { !$0.isInline }
            guard files.indices.contains(index),
                  let file = try? await AttachmentCache.file(service: service, account: account.id, messageId: messageId, attachment: files[index]) else { return nil }
            let cached = file.deletingLastPathComponent().appendingPathComponent(".preview.png")
            if let data = try? Data(contentsOf: cached) { return data }
            let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 520, height: 360), scale: 2, representationTypes: .thumbnail)
            guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
            #if os(macOS)
            let data = NSBitmapImageRep(cgImage: thumbnail.cgImage).representation(using: .png, properties: [:])
            #else
            let data = thumbnail.uiImage.pngData()
            #endif
            if let data { try? data.write(to: cached, options: .atomic) }
            return data
        }
        return nil
    }
}

/// Attachments are downloaded once and kept in the caches folder.
enum AttachmentCache {
    static let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func folder(messageId: String, attachment: Attachment) -> URL {
        let digest = SHA256.hash(data: Data((messageId + attachment.attachmentId.prefix(64) + attachment.filename).utf8))
        return directory.appendingPathComponent(digest.prefix(12).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    /// The file on disk, downloading it first if needed. It keeps its real name so other apps show it properly.
    static func file(service: MailService, account: String, messageId: String, attachment: Attachment) async throws -> URL {
        let folder = folder(messageId: messageId, attachment: attachment)
        let safeName = attachment.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let data = try await service.attachmentData(account: account, messageId: messageId, attachment: attachment)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    static func data(service: MailService, account: String, messageId: String, attachment: Attachment) async throws -> Data {
        try Data(contentsOf: try await file(service: service, account: account, messageId: messageId, attachment: attachment))
    }

    #if DEBUG || BENCH
    /// A benchmark puts its made-up attachments straight here: nothing can be downloaded offline.
    static func seed(messageId: String, attachment: Attachment, data: Data) {
        let folder = folder(messageId: messageId, attachment: attachment)
        let safeName = attachment.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName), options: .atomic)
    }
    #endif
}

/// Puts the shared web view on screen.
struct ThreadWebView {
    let web: ThreadWeb
}

#if os(macOS)
extension ThreadWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { web.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension ThreadWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { web.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

#if os(iOS)
/// Recognises a left-to-right drag anywhere on the conversation without getting in the way of scrolling.
final class BackPan: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UIPanGestureRecognizer()
    private let report: (CGFloat, CGFloat?) -> Void

    init(report: @escaping (CGFloat, CGFloat?) -> Void) {
        self.report = report
        super.init()
        recognizer.addTarget(self, action: #selector(moved))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
    }

    @objc private func moved() {
        let distance = max(0, recognizer.translation(in: recognizer.view).x)
        switch recognizer.state {
        case .changed: report(distance, nil)
        case .ended: report(distance, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed: report(0, 0)
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = recognizer.velocity(in: recognizer.view)
        // Clearly sideways, not a diagonal scroll.
        return velocity.x > 60 && velocity.x > abs(velocity.y) * 1.5
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
