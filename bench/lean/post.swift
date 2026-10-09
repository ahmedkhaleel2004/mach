// Sends one test command to a benchmark copy of the Mac app: `post <channel> <command>`.
import Foundation
let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1].hasPrefix("com.ahmedkhaleel.machbench.") else {
    print("usage: post com.ahmedkhaleel.machbench.<name> <command>   (never the real app's channel)")
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(.init(arguments[1]), object: arguments[2], userInfo: nil, deliverImmediately: true)
// Give the notification server a moment to take it before this process goes away.
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
