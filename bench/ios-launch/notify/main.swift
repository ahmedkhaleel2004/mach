// A harness for the notification extension (`App/NotifyExtension/NotificationService.swift`), compiled together with
// it into a small simulator program by `bench/ios-launch/bench.py notify`. It hands the extension a made-up push the
// way the system would and times how long the banner is held: from `didReceive` to the content handler being called.
//
//   notify-bench good <rounds>     the sender's picture is served at once by a listener inside this program
//   notify-bench hang <rounds>     the picture's server accepts the connection and never answers (a bad network)
//   notify-bench none <rounds>     the push names no picture and lookups are off: only the extension's own work
//
// Nothing leaves the machine: the only address used is 127.0.0.1, and BLITZ_OFFLINE=1 switches the Gravatar and
// site-icon lookups off.
import Foundation
import Network
import UIKit
import UserNotifications

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "good"
let rounds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 5 : 5
let port: UInt16 = 18474

/// A picture big enough for the extension to accept (more than 200 bytes, at least 32 points wide).
let picture: Data = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
    for index in 0 ..< 64 {
        UIColor(hue: CGFloat(index) / 64, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        context.fill(CGRect(x: index, y: 0, width: 1, height: 64))
    }
}

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
parameters.allowLocalEndpointReuse = true
let listener = try NWListener(using: parameters)
var held: [NWConnection] = []
listener.newConnectionHandler = { connection in
    connection.start(queue: .main)
    held.append(connection)
    guard mode == "good" else { return }          // "hang": the request is taken and never answered
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
        var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(picture.count)\r\nConnection: close\r\n\r\n".utf8)
        reply.append(picture)
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }
}
listener.start(queue: .main)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e6 }

func round(_ index: Int, completion: @escaping () -> Void) {
    let email = "sender\(index)-\(UUID().uuidString.prefix(6))@example.invalid"
    let content = UNMutableNotificationContent()
    content.title = "A Sender"
    content.subtitle = "A made-up subject"
    content.body = "The first line of a made-up message."
    var info: [String: Any] = ["senderEmail": email, "senderName": "A Sender", "thread": "t\(index)", "account": "me@example.invalid"]
    if mode != "none" { info["senderPhoto"] = "http://127.0.0.1:\(port)/photo/\(index)" }
    content.userInfo = info
    let request = UNNotificationRequest(identifier: "bench-\(index)", content: content, trigger: nil)
    let service = NotificationService()
    let start = now()
    let startCPU = cpu()
    var answered = false
    service.didReceive(request) { _ in
        let took = now() - start
        DispatchQueue.main.async {
            guard !answered else { return }
            answered = true
            let known = AvatarStore.shared.known(email)
            let line: [String: Any] = ["metric": "notify." + mode, "ms": (took * 10).rounded() / 10, "cpu": ((cpu() - startCPU) * 10).rounded() / 10,
                                       "picture": (known ?? nil) != nil, "first": index == 0]
            print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
            _ = service
            completion()
        }
    }
}

func run(_ index: Int) {
    guard index < rounds else { exit(0) }
    round(index) { run(index + 1) }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { run(0) }
// The system gives an extension about 30 seconds; a round that takes longer than that would have been cut off.
DispatchQueue.main.asyncAfter(deadline: .now() + 35 * Double(rounds)) { exit(3) }
dispatchMain()
