#if DEBUG || BENCH
import AppKit
import BlitzCore
import SwiftUI

/// Test-only commands for the `lean` benchmarks (memory, idle, compose). Compiled out of the app people use.
///
/// They arrive over the same channel as test key presses, prefixed `lean:`. Each one drives the app the way a
/// person would, waits for the screen to settle between steps, and writes its timings to `bench.jsonl`.
@MainActor
enum LeanBench {
    /// Runs `work` once the main thread has nothing left to do: every view that needed rebuilding has been rebuilt.
    static func whenSettled(_ work: @escaping @MainActor () -> Void) {
        // One trip through the queue first, so a view update that was itself queued has been picked up.
        DispatchQueue.main.async {
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
                MainActor.assumeIsolated { work() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    static func launched() {
        Bench.once("launch.did_finish")
        whenSettled { Bench.once("launch.settled") }
    }

    private static func after(_ milliseconds: Int, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { MainActor.assumeIsolated { work() } }
    }

    /// Does `step` `count` times, each after the screen settled from the one before, pausing `pause` ms in between,
    /// and records the median and slowest-decile time from a step to the screen settling.
    private static func repeating(_ metric: String, count: Int, pause: Int = 0, extra: [String: Any] = [:], step: @escaping @MainActor (Int) -> Void, done: @escaping @MainActor () -> Void = {}) {
        var samples: [Double] = []
        let bodies = BodyCount.counts
        let begun = Bench.now()
        func next(_ index: Int) {
            guard index < count else {
                samples.sort()
                var fields = extra
                fields["n"] = count
                fields["p90_ms"] = samples.isEmpty ? 0 : (samples[min(samples.count - 1, samples.count * 9 / 10)] * 1000).rounded() / 1000
                fields["total_ms"] = (Bench.now() - begun).rounded()
                for (name, grown) in BodyCount.since(bodies) { fields["bodies_" + name] = (Double(grown) / Double(max(count, 1)) * 100).rounded() / 100 }
                Bench.record(metric, ms: samples.isEmpty ? 0 : samples[samples.count / 2], fields)
                done()
                return
            }
            let start = Bench.now()
            step(index)
            whenSettled {
                samples.append(Bench.now() - start)
                if pause > 0 { after(pause) { next(index + 1) } } else { next(index + 1) }
            }
        }
        next(0)
    }

    /// Returns true when the command was one of ours.
    static func handle(_ command: String, model: AppModel) -> Bool {
        guard command.hasPrefix("lean:") else { return false }
        let parts = command.dropFirst(5).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        let count = Int(argument) ?? 1
        switch name {
        case "mark":
            // A line in the results file a script can wait for.
            let window = NSApp.windows.first { $0.frame.width > 700 }
            Bench.record("mark." + argument, ms: Bench.sinceProcessStart(), ["rows": model.rows.count, "frame": window.map { NSStringFromRect($0.frame) } ?? "", "restorable": window?.isRestorable ?? false])
        case "frame":
            // `x,y,width,height`: moves and resizes the mail window, as dragging it would.
            let numbers = argument.split(separator: ",").compactMap { Double($0) }
            if numbers.count == 4 { NSApp.windows.first { $0.frame.width > 700 }?.setFrame(NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), display: true) }
        case "quit":
            NSApp.terminate(nil)
        case "j":
            repeating("lean.key_j", count: count) { _ in _ = model.handle(AppModel.Key(characters: "j")) }
        case "open":
            // Opens the conversation under the cursor, gives it a moment, closes it and moves down one.
            var step = 0
            repeating("lean.open_close", count: count * 2, pause: 120) { _ in
                if step % 2 == 0 {
                    model.openCursor()
                } else {
                    model.closeThread()
                    model.moveCursor(by: 1)
                }
                step += 1
            }
        case "lists":
            let lists = model.allLists
            repeating("lean.switch_list", count: count, pause: 60) { index in model.go(lists[(index + 1) % lists.count]) } done: { model.go(model.home) }
        case "compose":
            // `c` to the compose view being on screen, then closed again, `count` times.
            var open = false
            repeating("compose.open", count: count * 2, pause: 30) { _ in
                if open { model.closeCompose(discard: true) } else { model.startCompose() }
                open.toggle()
            }
        case "reply":
            var open = false
            var bytes = 0
            repeating("compose.reply_open", count: count * 2, pause: 30) { _ in
                if open { model.closeCompose(discard: true) } else { model.startReply(all: false) }
                bytes = max(bytes, model.compose?.quotedHTML.utf8.count ?? 0)
                open.toggle()
            } done: {
                Bench.record("compose.reply_quoted_bytes", ms: 0, ["bytes": bytes])
            }
        case "replystart":
            // Only the call itself (reading the conversation, building the quote), without the screen.
            var samples: [Double] = []
            for _ in 0..<max(count, 1) {
                let start = Bench.now()
                model.startReply(all: false)
                samples.append(Bench.now() - start)
                model.closeCompose(discard: true)
            }
            samples.sort()
            Bench.record("compose.reply_start_call", ms: samples[samples.count / 2], ["n": samples.count, "p90_ms": samples[min(samples.count - 1, samples.count * 9 / 10)]])
        case "type":
            // One character at a time into the body of the message being written, the way the text box does it.
            repeating("compose.type_char", count: count, extra: ["quoted_bytes": model.compose?.quotedHTML.utf8.count ?? 0, "rows_behind": model.rows.count]) { index in
                guard var draft = model.compose else { return }
                draft.body += index % 6 == 5 ? " " : "x"
                model.compose = draft
                model.composeChanged()
            }
        case "to":
            // The same for the To line, plus the address lookup the suggestions list does on every character.
            let text = argument.isEmpty ? "ada" : argument
            var typed = ""
            let characters = Array(text)
            repeating("compose.type_to", count: characters.count) { index in
                guard var draft = model.compose else { return }
                typed.append(characters[index])
                draft.to = typed
                model.compose = draft
                model.composeChanged()
                _ = model.contacts(matching: typed)
            }
        case "contacts":
            // The address lookup alone, on the main thread, for every prefix of the text, `20` times over.
            let text = argument.isEmpty ? "ada" : argument
            var samples: [Double] = []
            var found = 0
            for _ in 0..<20 {
                for end in 1...text.count {
                    let start = Bench.now()
                    found = max(found, model.contacts(matching: String(text.prefix(end))).count)
                    samples.append(Bench.now() - start)
                }
            }
            samples.sort()
            Bench.record("compose.contacts_lookup", ms: samples[samples.count / 2], ["n": samples.count, "p90_ms": samples[min(samples.count - 1, samples.count * 9 / 10)], "max_ms": samples.last ?? 0, "found": found])
        case "save":
            // What the save a moment after typing stops costs the main thread.
            guard let draft = model.compose else { break }
            var samples: [Double] = []
            for _ in 0..<max(count, 1) {
                let start = Bench.now()
                model.saveComposeNowForBench()
                samples.append(Bench.now() - start)
            }
            samples.sort()
            Bench.record("compose.save_on_main", ms: samples[samples.count / 2], ["n": samples.count, "p90_ms": samples[min(samples.count - 1, samples.count * 9 / 10)], "quoted_bytes": draft.quotedHTML.utf8.count, "body_bytes": draft.body.utf8.count])
        case "savebusy":
            // The same save while something else (a sync, say) holds the database for writing for 200 ms.
            guard model.compose != nil else { break }
            let store = model.service.store
            var samples: [Double] = []
            func round(_ left: Int) {
                guard left > 0 else {
                    samples.sort()
                    Bench.record("compose.save_while_db_busy", ms: samples[samples.count / 2], ["n": samples.count, "max_ms": samples.last ?? 0])
                    return
                }
                DispatchQueue.global().async { try? store.pool.write { _ in Thread.sleep(forTimeInterval: 0.2) } }
                after(50) {
                    let start = Bench.now()
                    model.saveComposeNowForBench()
                    samples.append(Bench.now() - start)
                    after(400) { round(left - 1) }
                }
            }
            round(max(count, 1))
        case "send":
            // ⌘Enter to the compose view gone. Offline, so the message only ever reaches the scratch outbox.
            guard model.compose != nil else { break }
            if model.compose?.to.isEmpty == true { model.compose?.to = "nobody@example.invalid" }
            let start = Bench.now()
            _ = model.handleWhileTyping(AppModel.Key(characters: "", command: true, special: .enter))
            let call = Bench.now() - start
            whenSettled { Bench.record("compose.send", ms: Bench.now() - start, ["call_ms": call, "gone": model.compose == nil]) }
        case "goto":
            // `account|thread`: opens that conversation, wherever it is.
            let pieces = argument.split(separator: "|").map(String.init)
            if pieces.count == 2 { model.open(account: pieces[0], threadId: pieces[1]) }
        case "cursor":
            // Puts the cursor on a conversation in the list without opening it.
            model.closeThread()
            model.setCursor(argument)
            Bench.record("lean.cursor", ms: 0, ["found": model.cursorIndex != nil])
        case "close":
            model.closeThread()
        case "discard":
            model.closeCompose(discard: true)
        case "bodies":
            Bench.record("lean.bodies", ms: 0, BodyCount.counts.reduce(into: [:]) { $0[$1.key] = $1.value })
        default:
            Bench.record("lean.unknown", ms: 0, ["command": name])
        }
        return true
    }
}
#endif
