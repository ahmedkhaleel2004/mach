// Sends one command to a benchmark app on its test hook: swift bench/thread-open/send.swift <channel> <command>
import Foundation
let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1].hasPrefix("com.ahmedkhaleel.machbench.") else {
    print("usage: send.swift com.ahmedkhaleel.machbench.<channel> <command>")
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(.init(arguments[1]), object: arguments[2], userInfo: nil, deliverImmediately: true)
