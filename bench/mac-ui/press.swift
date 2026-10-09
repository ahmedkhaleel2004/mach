import CoreGraphics
import Foundation
// press <pid> <keycode>[:cmd] ...   real key presses delivered to one process only
let pid = pid_t(CommandLine.arguments[1])!
let src = CGEventSource(stateID: .hidSystemState)
for arg in CommandLine.arguments.dropFirst(2) {
    let parts = arg.split(separator: ":")
    let code = CGKeyCode(parts[0])!
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        if parts.count > 1 { e.flags = .maskCommand }
        e.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: 0.7)
}
