import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ViewerAppDelegate()
app.delegate = delegate
app.run()
