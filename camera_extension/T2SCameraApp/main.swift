import Cocoa

// Explicit bootstrap rather than @main on the delegate: @main's entry-point
// synthesis for a plain AppKit delegate (no storyboard) did not reliably call
// applicationDidFinishLaunching here -- the process started and stayed alive
// with no window and no error.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
