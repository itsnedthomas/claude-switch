// Test hooks for the running app. `toggle` opens/closes the panel; `click x,y`
// sends a click at x,y from the panel's top-left. Results go to events.log.
import Foundation
let args = CommandLine.arguments
let dnc = DistributedNotificationCenter.default()
if args.count > 2, args[1] == "tab" {
    dnc.postNotificationName(.init("com.claudeswitch.app.tab"), object: args[2], deliverImmediately: true)
} else if args.count > 2, args[1] == "click" {
    dnc.postNotificationName(.init("com.claudeswitch.app.click"), object: args[2], deliverImmediately: true)
} else {
    dnc.postNotificationName(.init("com.claudeswitch.app.toggle"), object: nil, deliverImmediately: true)
}
