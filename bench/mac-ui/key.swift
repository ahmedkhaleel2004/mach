import Foundation
let a = CommandLine.arguments
DistributedNotificationCenter.default().postNotificationName(.init(a[1]), object: a[2], userInfo: nil, deliverImmediately: true)
Thread.sleep(forTimeInterval: 0.1)
